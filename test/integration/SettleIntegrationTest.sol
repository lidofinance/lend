// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTestWithController.sol";

import {ILidoLend} from "../../src/interfaces/ILidoLend.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";

contract SettleIntegrationTest is BaseTestWithController {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    // Kept in memory to avoid stack-too-deep under the no-via-ir profile (cf. upstream LiquidateTestParams).
    struct Vars {
        uint256 avail;
        uint256 debtCanceled;
        uint256 sliceShares;
        uint256 tSA;
        uint256 tSS;
        uint256 tBA;
        uint256 tBS;
        uint256 collateralSeized;
        uint256 borrowSharesToBurn;
        uint256 lenderShares;
        uint256 borrowSharesBefore;
        uint256 morphoCollatBefore;
        uint256 morphoLoanBefore;
        uint256 retSeized;
        uint256 retCanceled;
    }

    function _lido() internal view returns (ILidoLend) {
        return ILidoLend(address(morpho));
    }

    /// @dev Settle tests run at a non-1:1 price so the loan->collateral conversion is actually exercised instead
    ///      of collapsing to identity. Tests needing a specific price override it; `_openMarketWithAccruedInterest`
    ///      resets to 1:1 to isolate share rounding.
    function setUp() public override {
        super.setUp();
        oracle.setPrice(137 * ORACLE_PRICE_SCALE / 100); // collateral worth 1.37x the loan token
    }

    /// @dev Collateral seized for cancelling `debtAssets` of loan value at the current price (matches the core's
    ///      mulDivDown). Keeps seizure assertions price-correct instead of assuming a 1:1 rate.
    function _seizedFor(uint256 debtAssets) internal view returns (uint256) {
        return debtAssets.mulDivDown(ORACLE_PRICE_SCALE, oracle.price());
    }

    /// @dev Bounds `seed` to a healthy price (collateral worth 1x..10x the loan) and applies it, so a test runs
    ///      across a range of rates instead of one hardcoded value. The range keeps the positions these tests open
    ///      healthy and their seizures within the borrower's collateral.
    function _setFuzzedPrice(uint256 seed) internal {
        oracle.setPrice(bound(seed, ORACLE_PRICE_SCALE, 10 * ORACLE_PRICE_SCALE));
    }

    function _openPosition(uint256 supplied, uint256 collateral, uint256 borrowed) internal {
        _supply(supplied);
        collateralToken.setBalance(BORROWER, collateral);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(marketParams, collateral, BORROWER, hex"");
        morpho.borrow(marketParams, borrowed, 0, BORROWER, BORROWER);
        vm.stopPrank();
    }

    /// @dev Fresh controlled, settle-enabled market with accrued interest: supply == borrow == 40e18 (zero free
    ///      liquidity), ample collateral, then warped `elapsedSeed` (<= 365 days) and accrued so interest has
    ///      moved the share:asset ratio off the flat 1:VIRTUAL_SHARES — the regime where settle's share conversions
    ///      round. Resets price to 1:1 so the collateral leg is exact and only share rounding is in play. Pass an
    ///      `lltv` distinct from the setUp market so the id is fresh.
    function _openMarketWithAccruedInterest(uint256 lltv, uint256 elapsedSeed)
        internal
        returns (MarketParams memory mp, Id mid)
    {
        mp = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: lltv
        });
        mid = mp.id();
        ControllerMock controller = new ControllerMock(mid);
        vm.prank(OWNER);
        _lido().createMarket(mp, address(controller), true);

        oracle.setPrice(ORACLE_PRICE_SCALE); // 1:1: isolate share rounding from the price leg

        loanToken.setBalance(address(this), 40e18);
        morpho.supply(mp, 40e18, 0, address(this), hex"");
        collateralToken.setBalance(BORROWER, 1000e18);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(mp, 1000e18, BORROWER, hex"");
        morpho.borrow(mp, 40e18, 0, BORROWER, BORROWER);
        vm.stopPrank();

        vm.warp(block.timestamp + bound(elapsedSeed, 1, 365 days));
        morpho.accrueInterest(mp);
        assertGt(
            morpho.totalSupplyAssets(mid), morpho.totalSupplyShares(mid) / SharesMathLib.VIRTUAL_SHARES, "no accrued interest"
        );
    }

    function testSettleMarketNotCreated(MarketParams memory mp) public {
        vm.assume(neq(mp, marketParams));
        vm.expectRevert(bytes(ErrorsLib.MARKET_NOT_CREATED));
        _lido().settle(mp, 0, 1, address(this), BORROWER, RECEIVER);
    }

    function testSettleDisabled() public {
        // The default BaseTest market (non-zero IRM, no controller) was created without settlement.
        MarketParams memory base = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: DEFAULT_TEST_LLTV
        });
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_DISABLED));
        _lido().settle(base, 0, 1, address(this), BORROWER, RECEIVER);
    }

    function testSettleInconsistentInput() public {
        // Neither amount zero.
        vm.expectRevert(bytes(ErrorsLib.INCONSISTENT_INPUT));
        _lido().settle(marketParams, 1, 1, address(this), BORROWER, RECEIVER);
        // Both amounts zero.
        vm.expectRevert(bytes(ErrorsLib.INCONSISTENT_INPUT));
        _lido().settle(marketParams, 0, 0, address(this), BORROWER, RECEIVER);
    }

    function testSettleZeroReceiver() public {
        vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
        _lido().settle(marketParams, 0, 1, address(this), BORROWER, address(0));
    }

    function testSettleUnauthorized() public {
        vm.prank(RECEIVER); // not authorized for onBehalf == BORROWER
        vm.expectRevert(bytes(ErrorsLib.UNAUTHORIZED));
        _lido().settle(marketParams, 0, 1, BORROWER, BORROWER, RECEIVER);
    }

    function testSettleIneligibleBorrower() public {
        _openPosition(100e18, 200e18, 100e18);
        uint256 supplyShares = morpho.supplyShares(id, address(this)) / 2;
        // Target ONBEHALF, who never borrowed → no debt.
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_NO_DEBT));
        _lido().settle(marketParams, 0, supplyShares, address(this), ONBEHALF, RECEIVER);
    }

    function testSettleLiquidityGateBoundary(uint256 priceSeed) public {
        _setFuzzedPrice(priceSeed);
        _openPosition(100e18, 100e18, 70e18);
        uint256 avail = morpho.totalSupplyAssets(id) - morpho.totalBorrowAssets(id);
        assertEq(avail, 30e18, "avail");
        // Single supplier: settleable supply = own supply (100) − free liquidity (30) = the borrowed 70.
        uint256 settleable = 100e18 - avail;
        assertEq(settleable, 70e18, "settleable");

        // debtCanceled == settleable + 1 exceeds the cap → the gate blocks (it fires before the debt and
        // collateral caps).
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_LIQUIDITY_AVAILABLE));
        _lido()
            .settle(marketParams, 0, (settleable + 1) * SharesMathLib.VIRTUAL_SHARES, address(this), BORROWER, RECEIVER);

        // debtCanceled == settleable clears the gate and executes.
        uint256 sharesBefore = morpho.supplyShares(id, address(this));
        uint256 slice = settleable * SharesMathLib.VIRTUAL_SHARES;
        (uint256 seized,) = _lido().settle(marketParams, 0, slice, address(this), BORROWER, RECEIVER);
        assertEq(seized, _seizedFor(settleable), "seized the cancelled debt's worth of collateral");
        assertEq(morpho.supplyShares(id, address(this)), sharesBefore - slice, "lender shares reduced by the slice");
    }

    function testSettleByAssetsInput(uint256 priceSeed) public {
        _setFuzzedPrice(priceSeed);
        _openPosition(100e18, 100e18, 70e18); // avail = 30e18
        uint256 settleAssets = 40e18; // > avail, within the borrower's 70e18 debt

        (uint256 seized, uint256 canceled) =
            _lido().settle(marketParams, settleAssets, 0, address(this), BORROWER, RECEIVER);

        // The supplyAssets input is honored as debtCanceled exactly; the seizure is its worth at the price.
        assertEq(canceled, settleAssets, "debtCanceled equals the supplyAssets input");
        assertEq(seized, _seizedFor(settleAssets), "seized the cancelled debt's worth of collateral");
    }

    // Each cap now has its own error, so the revert string alone pins which check fired.

    function testSettleOverCapZeroCollateral() public {
        _openPosition(100e18, 200e18, 100e18);
        oracle.setPrice(MAX_COLLATERAL_PRICE);
        // debtCanceled == 1 → collateralSeized = 1 * SCALE / 1e40 rounds to 0.
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_SLICE_TOO_SMALL));
        _lido().settle(marketParams, 0, 1 * SharesMathLib.VIRTUAL_SHARES, address(this), BORROWER, RECEIVER);
    }

    function testSettleOverCapCollateral() public {
        _openPosition(100e18, 100e18, 70e18);
        oracle.setPrice(ORACLE_PRICE_SCALE / 2); // collateral now worth 50e18
        // debtCanceled 60e18 → collateralSeized 120e18 > 100e18 collateral.
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_COLLATERAL));
        _lido().settle(marketParams, 0, 60e18 * SharesMathLib.VIRTUAL_SHARES, address(this), BORROWER, RECEIVER);
    }

    function testSettleOverCapBorrowShares() public {
        _openPosition(100e18, 100e18, 70e18);
        // A second borrower draws more so free liquidity shrinks and the lender's settleable supply
        // (own supply − free liquidity) rises above BORROWER's 70e18 debt — letting the debt cap fire
        // instead of the liquidity gate. After: total borrow 95, free liquidity 5, settleable 95.
        collateralToken.setBalance(ONBEHALF, 100e18);
        vm.startPrank(ONBEHALF);
        morpho.supplyCollateral(marketParams, 100e18, ONBEHALF, hex"");
        morpho.borrow(marketParams, 25e18, 0, ONBEHALF, ONBEHALF);
        vm.stopPrank();

        // debtCanceled 80e18 clears the gate (<= 95) but burns more than BORROWER's 70e18 debt.
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_DEBT));
        _lido().settle(marketParams, 0, 80e18 * SharesMathLib.VIRTUAL_SHARES, address(this), BORROWER, RECEIVER);
    }

    function testSettleCannotCancelMoreThanOwned() public {
        // A large supplier provides most liquidity; the lender (address(this)) holds only a small slice.
        loanToken.setBalance(SUPPLIER, 100e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 100e18, 0, SUPPLIER, hex"");
        _openPosition(10e18, 200e18, 100e18);

        // The lender's whole 10e18 supply sits within free liquidity, so its settleable supply is 0: the
        // gate rejects any cut against it cleanly (no underflow), before the share subtraction.
        uint256 lenderShares = morpho.supplyShares(id, address(this));
        uint256 tooMany = lenderShares + 1e18 * SharesMathLib.VIRTUAL_SHARES;
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_LIQUIDITY_AVAILABLE));
        _lido().settle(marketParams, 0, tooMany, address(this), BORROWER, RECEIVER);
    }

    function testSettleAuthorizedViaApproval() public {
        _openPosition(100e18, 100e18, 70e18);
        morpho.setAuthorization(RECEIVER, true);

        uint256 sharesBefore = morpho.supplyShares(id, address(this));
        uint256 supplyShares = sharesBefore / 2;

        vm.prank(RECEIVER);
        _lido().settle(marketParams, 0, supplyShares, address(this), BORROWER, RECEIVER);

        assertEq(morpho.supplyShares(id, address(this)), sharesBefore - supplyShares, "lender shares reduced");
    }

    function testSettleAuthorizedViaSig() public {
        uint256 privateKey = 0xA11CE;
        address authorizer = vm.addr(privateKey);

        // `authorizer` is the supplier whose position is settled; BORROWER provides the debt to settle against.
        loanToken.setBalance(address(this), 100e18);
        morpho.supply(marketParams, 100e18, 0, authorizer, hex"");
        collateralToken.setBalance(BORROWER, 100e18);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(marketParams, 100e18, BORROWER, hex"");
        morpho.borrow(marketParams, 70e18, 0, BORROWER, BORROWER);
        vm.stopPrank();

        // Authorize address(this) to act for `authorizer` via an EIP-712 signature.
        Authorization memory authorization = Authorization({
            authorizer: authorizer,
            authorized: address(this),
            isAuthorized: true,
            nonce: 0,
            deadline: block.timestamp
        });
        Signature memory sig;
        (sig.v, sig.r, sig.s) = vm.sign(privateKey, SigUtils.getTypedDataHash(morpho.DOMAIN_SEPARATOR(), authorization));
        morpho.setAuthorizationWithSig(authorization, sig);

        // address(this) settles for `authorizer` — only the signature-based authorization permits this.
        uint256 sharesBefore = morpho.supplyShares(id, authorizer);
        _lido().settle(marketParams, 0, sharesBefore / 2, authorizer, BORROWER, RECEIVER);

        assertEq(morpho.nonce(authorizer), 1, "signature consumed");
        assertEq(morpho.supplyShares(id, authorizer), sharesBefore - sharesBefore / 2, "settled via sig authorization");
    }

    function testSettleBorrowerExitsWhole(uint256 supplied, uint256 sliceSeed, uint256 priceSeed) public {
        supplied = bound(supplied, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT / 2);
        uint256 collateral = 2 * supplied;
        _setFuzzedPrice(priceSeed);
        _openPosition(supplied, collateral, supplied); // supply == borrow → free liquidity 0

        uint256 lenderShares = morpho.supplyShares(id, address(this));
        uint256 slice = bound(sliceSeed, lenderShares / 4, (lenderShares * 3) / 4);
        (uint256 seized, uint256 canceled) = _lido().settle(marketParams, 0, slice, address(this), BORROWER, RECEIVER);
        assertEq(seized, _seizedFor(canceled), "seized the cancelled debt's worth");
        assertEq(morpho.collateral(id, BORROWER), collateral - seized, "borrower collateral debited by the seizure");

        // The borrower clears the residual debt and pulls out the remaining collateral.
        vm.startPrank(BORROWER);
        loanToken.setBalance(BORROWER, supplied);
        morpho.repay(marketParams, 0, morpho.borrowShares(id, BORROWER), BORROWER, hex"");
        morpho.withdrawCollateral(marketParams, morpho.collateral(id, BORROWER), BORROWER, BORROWER);
        vm.stopPrank();

        // Whole: recovered the unseized collateral, no residual debt, no stuck collateral.
        assertEq(collateralToken.balanceOf(BORROWER), collateral - seized, "borrower recovered the rest");
        assertEq(morpho.borrowShares(id, BORROWER), 0, "no residual debt");
        assertEq(morpho.collateral(id, BORROWER), 0, "no stuck collateral");
    }

    function testSettleFullDrainLeavesMarketUsable(uint256 supplied, uint256 priceSeed) public {
        supplied = bound(supplied, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT / 2);
        uint256 collateral = 2 * supplied;
        _setFuzzedPrice(priceSeed);
        _openPosition(supplied, collateral, supplied); // sole lender, supply == borrow → free liquidity 0

        uint256 allShares = morpho.supplyShares(id, address(this));
        (uint256 seized,) = _lido().settle(marketParams, 0, allShares, address(this), BORROWER, RECEIVER);

        // Canceling the entire stake zeroes the market exactly: at a single first supply, totalShares ==
        // assets * VIRTUAL_SHARES, so the cancellation leaves no rounding remainder.
        assertEq(seized, _seizedFor(supplied), "seized the whole supply's worth");
        assertEq(morpho.totalSupplyShares(id), 0, "supply shares zeroed");
        assertEq(morpho.totalSupplyAssets(id), 0, "supply assets zeroed");
        assertEq(morpho.totalBorrowShares(id), 0, "borrow shares zeroed");
        assertEq(morpho.totalBorrowAssets(id), 0, "borrow assets zeroed");
        assertEq(morpho.collateral(id, BORROWER), collateral - seized, "borrower keeps the unseized collateral");

        // Not bricked: a fresh deposit into the zeroed market round-trips exactly.
        uint256 fresh = MIN_TEST_AMOUNT;
        loanToken.setBalance(address(this), fresh);
        morpho.supply(marketParams, fresh, 0, address(this), hex"");
        morpho.withdraw(marketParams, 0, morpho.supplyShares(id, address(this)), address(this), address(this));
        assertEq(loanToken.balanceOf(address(this)), fresh, "fresh deposit round-trips exactly");
    }

    function testSettleSelfPosition(uint256 supplied, uint256 sliceSeed, uint256 priceSeed) public {
        supplied = bound(supplied, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT / 2);
        uint256 collateral = 2 * supplied;
        _setFuzzedPrice(priceSeed);
        _supply(supplied); // address(this) lends
        collateralToken.setBalance(address(this), collateral);
        morpho.supplyCollateral(marketParams, collateral, address(this), hex"");
        morpho.borrow(marketParams, supplied, 0, address(this), address(this)); // and borrows → free liquidity 0

        uint256 supplyBefore = morpho.supplyShares(id, address(this));
        uint256 borrowBefore = morpho.borrowShares(id, address(this));
        uint256 tBABefore = morpho.totalBorrowAssets(id);
        uint256 tBSBefore = morpho.totalBorrowShares(id);

        // onBehalf == borrower == address(this).
        uint256 slice = bound(sliceSeed, supplyBefore / 4, (supplyBefore * 3) / 4);
        (uint256 seized, uint256 canceled) =
            _lido().settle(marketParams, 0, slice, address(this), address(this), RECEIVER);
        assertEq(seized, _seizedFor(canceled), "seized the cancelled debt's worth");

        uint256 burn = canceled.toSharesUp(tBABefore, tBSBefore);
        assertEq(morpho.supplyShares(id, address(this)), supplyBefore - slice, "self: supply shares burned");
        assertEq(morpho.borrowShares(id, address(this)), borrowBefore - burn, "self: debt shares burned");
        assertEq(morpho.collateral(id, address(this)), collateral - seized, "self: collateral seized");
        assertEq(collateralToken.balanceOf(RECEIVER), seized, "receiver got the seized collateral");
    }

    function testSettleControllerCanBlock() public {
        _openPosition(100e18, 100e18, 70e18);
        controller.setRevertOn(ILidoLendMarketController.HookEvent.Settle, true);
        uint256 supplyShares = morpho.supplyShares(id, address(this)) / 2;

        uint256 supplyBefore = morpho.supplyShares(id, address(this));
        uint256 borrowBefore = morpho.borrowShares(id, BORROWER);
        uint256 collatBefore = morpho.collateral(id, BORROWER);
        uint256 receiverBefore = collateralToken.balanceOf(RECEIVER);

        vm.expectRevert(bytes("controller: blocked"));
        _lido().settle(marketParams, 0, supplyShares, address(this), BORROWER, RECEIVER);

        // The hook fires before any state write, so a veto must leave every touched slot untouched.
        assertEq(morpho.supplyShares(id, address(this)), supplyBefore, "supply shares unchanged");
        assertEq(morpho.borrowShares(id, BORROWER), borrowBefore, "borrow shares unchanged");
        assertEq(morpho.collateral(id, BORROWER), collatBefore, "collateral unchanged");
        assertEq(collateralToken.balanceOf(RECEIVER), receiverBefore, "receiver balance unchanged");
    }

    function testSettleHookPayload() public {
        _openPosition(100e18, 100e18, 70e18);
        uint256 supplyShares = morpho.supplyShares(id, address(this)) / 2;
        uint256 expectedCanceled =
            supplyShares.toAssetsDown(morpho.totalSupplyAssets(id), morpho.totalSupplyShares(id));
        uint256 expectedSeized = _seizedFor(expectedCanceled);
        uint256 expectedCanceledShares =
            expectedCanceled.toSharesUp(morpho.totalBorrowAssets(id), morpho.totalBorrowShares(id));

        _lido().settle(marketParams, 0, supplyShares, address(this), BORROWER, RECEIVER);

        assertEq(uint8(controller.lastEvent()), uint8(ILidoLendMarketController.HookEvent.Settle), "hook event");
        assertEq(Id.unwrap(controller.lastId()), Id.unwrap(id), "hook market id");

        ILidoLendMarketController.SettleHookData memory d =
            abi.decode(controller.lastData(), (ILidoLendMarketController.SettleHookData));
        assertEq(d.caller, address(this), "caller");
        assertEq(d.onBehalf, address(this), "onBehalf");
        assertEq(d.borrower, BORROWER, "borrower");
        assertEq(d.receiver, RECEIVER, "receiver");
        assertEq(d.supplySharesBurned, supplyShares, "supplySharesBurned");
        assertEq(d.borrowAssetsCanceled, expectedCanceled, "borrowAssetsCanceled");
        assertEq(d.borrowSharesCanceled, expectedCanceledShares, "borrowSharesCanceled");
        assertEq(d.seizedAssets, expectedSeized, "seizedAssets");
    }

    function testSettleEmitsEvent() public {
        _openPosition(100e18, 100e18, 70e18);
        uint256 supplyShares = morpho.supplyShares(id, address(this)) / 2;
        uint256 expectedCanceled =
            supplyShares.toAssetsDown(morpho.totalSupplyAssets(id), morpho.totalSupplyShares(id));
        uint256 expectedSeized = _seizedFor(expectedCanceled);
        uint256 expectedCanceledShares =
            expectedCanceled.toSharesUp(morpho.totalBorrowAssets(id), morpho.totalBorrowShares(id));

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.Settle(
            id, address(this), address(this), BORROWER, supplyShares, expectedCanceled, expectedCanceledShares, expectedSeized
        );
        _lido().settle(marketParams, 0, supplyShares, address(this), BORROWER, RECEIVER);
    }

    function testSettleSuccessFuzz(
        uint256 collateral,
        uint256 borrowed,
        uint256 price,
        uint256 extraSeed,
        uint256 sliceSeed
    ) public {
        (collateral, borrowed, price) = _boundHealthyPosition(collateral, borrowed, price);
        oracle.setPrice(price);

        Vars memory v;
        // Fuzz both regimes: free liquidity = avail ∈ [0, borrowed-1] < borrowed (cancel window non-empty).
        v.avail = bound(extraSeed, 0, borrowed - 1);
        _openPosition(borrowed + v.avail, collateral, borrowed);
        assertEq(morpho.totalSupplyAssets(id) - morpho.totalBorrowAssets(id), v.avail, "free liquidity == extra");

        // debtCanceled ∈ (avail, borrowed]: clears the gate, within the borrower's debt and (healthy) collateral.
        v.debtCanceled = bound(sliceSeed, v.avail + 1, borrowed);
        v.sliceShares = v.debtCanceled * SharesMathLib.VIRTUAL_SHARES;

        v.tSA = morpho.totalSupplyAssets(id);
        v.tSS = morpho.totalSupplyShares(id);
        v.tBA = morpho.totalBorrowAssets(id);
        v.tBS = morpho.totalBorrowShares(id);

        assertEq(v.sliceShares.toAssetsDown(v.tSA, v.tSS), v.debtCanceled, "slice maps to debtCanceled");

        v.collateralSeized = _seizedFor(v.debtCanceled);
        v.borrowSharesToBurn = v.debtCanceled.toSharesUp(v.tBA, v.tBS);
        vm.assume(v.collateralSeized > 0); // discards only a tiny slice at extreme price

        v.morphoCollatBefore = collateralToken.balanceOf(address(morpho));
        v.morphoLoanBefore = loanToken.balanceOf(address(morpho));
        v.lenderShares = morpho.supplyShares(id, address(this));
        v.borrowSharesBefore = morpho.borrowShares(id, BORROWER);

        (v.retSeized, v.retCanceled) = _lido().settle(marketParams, 0, v.sliceShares, address(this), BORROWER, RECEIVER);

        // Exact arithmetic (pins rounding direction).
        assertEq(v.retCanceled, v.debtCanceled, "return debtCanceled");
        assertEq(v.retSeized, v.collateralSeized, "return collateralSeized");
        assertEq(morpho.supplyShares(id, address(this)), v.lenderShares - v.sliceShares, "lender shares");
        assertEq(morpho.totalSupplyShares(id), v.tSS - v.sliceShares, "total supply shares");
        assertEq(morpho.totalSupplyAssets(id), v.tSA - v.debtCanceled, "total supply assets");
        assertEq(morpho.borrowShares(id, BORROWER), v.borrowSharesBefore - v.borrowSharesToBurn, "borrow shares");
        assertEq(morpho.totalBorrowShares(id), v.tBS - v.borrowSharesToBurn, "total borrow shares");
        assertEq(morpho.totalBorrowAssets(id), v.tBA - v.debtCanceled, "total borrow assets");

        // Formula-independent invariants.
        assertEq(morpho.totalSupplyAssets(id) - morpho.totalBorrowAssets(id), v.avail, "free liquidity preserved");
        assertEq(collateralToken.balanceOf(RECEIVER), v.collateralSeized, "receiver got the collateral");
        assertEq(
            collateralToken.balanceOf(address(morpho)), v.morphoCollatBefore - v.collateralSeized, "morpho collateral"
        );
        assertEq(loanToken.balanceOf(address(morpho)), v.morphoLoanBefore, "no loan tokens move");
    }

    // With a non-enforcing controller, settlement leaves bad debt unrealized — preventing this is the
    // controller's responsibility; the core has no in-core backstop (unlike `liquidate`).
    function testSettleBadDebtNotRealizedFuzz(
        uint256 collateral,
        uint256 borrowed,
        uint256 priceSeed,
        uint256 sliceSeed
    ) public {
        (collateral, borrowed,) = _boundHealthyPosition(collateral, borrowed, ORACLE_PRICE_SCALE);
        _openPosition(borrowed, collateral, borrowed); // free liquidity 0, sole supplier/borrower

        // Drop into the underwater range: collateralValue < debt ⟺ price < borrowed*SCALE/collateral.
        uint256 underwaterCap = borrowed.mulDivDown(ORACLE_PRICE_SCALE, collateral);
        vm.assume(underwaterCap > MIN_COLLATERAL_PRICE);
        uint256 newPrice = bound(priceSeed, MIN_COLLATERAL_PRICE, underwaterCap - 1);
        oracle.setPrice(newPrice);

        uint256 collateralValue = collateral.mulDivDown(newPrice, ORACLE_PRICE_SCALE);
        vm.assume(collateralValue > 1);
        // Cancel within the collateral value (so collateralSeized <= collateral) and below the debt → residual.
        uint256 debtCanceled = bound(sliceSeed, 1, collateralValue);
        uint256 collateralSeized = _seizedFor(debtCanceled);
        vm.assume(collateralSeized > 0 && collateralSeized <= collateral);
        uint256 sliceShares = debtCanceled * SharesMathLib.VIRTUAL_SHARES;

        uint256 tSA = morpho.totalSupplyAssets(id);

        _lido().settle(marketParams, 0, sliceShares, address(this), BORROWER, RECEIVER);

        // The loss is NOT socialized: total supply fell only by the canceled amount, though this slice came out
        // of an underwater position. `liquidate` would have written `totalSupplyAssets` down here; settlement does not.
        assertEq(morpho.totalSupplyAssets(id), tSA - debtCanceled, "no bad-debt write-down");
        assertGt(morpho.borrowShares(id, BORROWER), 0, "residual debt remains");
        // We do NOT assert the residual stays under-collateralized: collateralSeized rounds down, so at small
        // amounts the rounding slack can heal it to solvent. The hazard is the missing write-down, not the residual.
    }

    // settle must realize pending interest itself (it calls _accrueInterest before computing the cut). The helper
    // leaves the market freshly accrued, so warp again to make interest pending, then confirm settle moves
    // lastUpdate to now — only _accrueInterest does that.
    function testSettleAccruesInterest() public {
        (MarketParams memory mp, Id mid) = _openMarketWithAccruedInterest(0.75 ether, 30 days);

        uint256 staleUpdate = morpho.lastUpdate(mid);
        vm.warp(block.timestamp + 30 days);
        assertEq(morpho.lastUpdate(mid), staleUpdate, "precondition: interest pending, unrealized");

        _lido().settle(mp, 1e18, 0, address(this), BORROWER, RECEIVER);

        assertEq(morpho.lastUpdate(mid), block.timestamp, "settle realized pending interest");
    }

    // Settle by SHARES: pins the borrow-side rounding. The burned debt shares, valued back to assets, must equal
    // the cancelled debt exactly; an under-burn (the pool-draining direction) would value back to debtCanceled - 1.
    function testSettleShareRoundingWithInterestFuzz(uint256 elapsed, uint256 sliceSeed) public {
        (MarketParams memory mp, Id mid) = _openMarketWithAccruedInterest(0.5 ether, elapsed);

        Vars memory v;
        v.tSA = morpho.totalSupplyAssets(mid);
        v.tSS = morpho.totalSupplyShares(mid);
        v.tBA = morpho.totalBorrowAssets(mid);
        v.tBS = morpho.totalBorrowShares(mid);
        v.lenderShares = morpho.supplyShares(mid, address(this));
        v.sliceShares = bound(sliceSeed, 1, v.lenderShares);
        vm.assume(v.sliceShares.toAssetsDown(v.tSA, v.tSS) > 0); // skip zero-debt slices (would revert)

        v.borrowSharesBefore = morpho.borrowShares(mid, BORROWER);
        (v.retSeized, v.retCanceled) = _lido().settle(mp, 0, v.sliceShares, address(this), BORROWER, RECEIVER);
        uint256 borrowBurned = v.borrowSharesBefore - morpho.borrowShares(mid, BORROWER);

        assertEq(morpho.supplyShares(mid, address(this)), v.lenderShares - v.sliceShares, "supply burned == input");
        assertEq(borrowBurned.toAssetsDown(v.tBA, v.tBS), v.retCanceled, "burned debt valued back == cancelled debt");
        assertEq(v.retSeized, v.retCanceled, "seized == cancelled at 1:1");

        assertEq(morpho.totalSupplyShares(mid), v.tSS - v.sliceShares, "total supply shares");
        assertEq(morpho.totalSupplyAssets(mid), v.tSA - v.retCanceled, "total supply assets");
        assertEq(morpho.totalBorrowShares(mid), v.tBS - borrowBurned, "total borrow shares");
        assertEq(morpho.totalBorrowAssets(mid), v.tBA - v.retCanceled, "total borrow assets");
        assertEq(collateralToken.balanceOf(RECEIVER), v.retSeized, "receiver collateral");
    }

    // Settle by ASSETS: pins the supply-side rounding. The burned supply shares, valued back to assets, must equal
    // the cancelled debt exactly; an under-burn would value back to debtCanceled - 1.
    function testSettleByAssetsShareRoundingWithInterestFuzz(uint256 elapsed, uint256 assetsSeed) public {
        (MarketParams memory mp, Id mid) = _openMarketWithAccruedInterest(0.625 ether, elapsed);

        Vars memory v;
        v.tSA = morpho.totalSupplyAssets(mid);
        v.tSS = morpho.totalSupplyShares(mid);
        v.lenderShares = morpho.supplyShares(mid, address(this));
        v.debtCanceled = bound(assetsSeed, 1, v.lenderShares.toAssetsDown(v.tSA, v.tSS));
        vm.assume(v.debtCanceled.toSharesUp(v.tSA, v.tSS) <= v.lenderShares); // skip top edge needing > held shares

        (, v.retCanceled) = _lido().settle(mp, v.debtCanceled, 0, address(this), BORROWER, RECEIVER);
        uint256 supplyBurned = v.lenderShares - morpho.supplyShares(mid, address(this));

        assertEq(v.retCanceled, v.debtCanceled, "assets input == cancelled debt");
        assertEq(supplyBurned.toAssetsDown(v.tSA, v.tSS), v.debtCanceled, "burned supply valued back == cancelled debt");
        assertEq(morpho.totalSupplyShares(mid), v.tSS - supplyBurned, "total supply shares");
        assertEq(morpho.totalSupplyAssets(mid), v.tSA - v.debtCanceled, "total supply assets");
    }
}
