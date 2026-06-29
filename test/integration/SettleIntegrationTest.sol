// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTestWithController.sol";

import {ILidoLend} from "../../src/interfaces/ILidoLend.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";

/// @dev Tests that verify access control, authorization, hook/event behavior, and position-lifecycle
///      flows for `settle`. Arithmetic correctness and rounding live in SettleMathTest.
contract SettleIntegrationTest is BaseTestWithController {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    function _lido() internal view returns (ILidoLend) {
        return ILidoLend(address(morpho));
    }

    /// @dev Settle tests run at a non-1:1 price so the loan->collateral conversion is actually exercised instead
    ///      of collapsing to identity. Tests needing a specific price override it.
    function setUp() public override {
        super.setUp();
        oracle.setPrice(137 * ORACLE_PRICE_SCALE / 100); // collateral worth 1.37x the loan token
    }

    /// @dev Collateral seized for cancelling `debtAssets` of loan value at the current price (matches the core's
    ///      mulDivDown). Keeps seizure assertions price-correct instead of assuming a 1:1 rate.
    function _seizedFor(uint256 debtAssets) internal view returns (uint256) {
        return debtAssets.mulDivDown(ORACLE_PRICE_SCALE, oracle.price());
    }

    /// @dev Bounds `seed` to a healthy price (collateral worth 1x..10x the loan) and applies it.
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

    /* ACCESS CONTROL */

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

    // The lender's whole supply sits within free liquidity so its settleable supply is 0; the gate
    // rejects any cut against it cleanly (no underflow), before the share subtraction.
    function testSettleCannotCancelMoreThanOwned() public {
        loanToken.setBalance(SUPPLIER, 100e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 100e18, 0, SUPPLIER, hex"");
        _openPosition(10e18, 200e18, 100e18);

        uint256 lenderShares = morpho.supplyShares(id, address(this));
        uint256 tooMany = lenderShares + 1e18 * SharesMathLib.VIRTUAL_SHARES;
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_LIQUIDITY_AVAILABLE));
        _lido().settle(marketParams, 0, tooMany, address(this), BORROWER, RECEIVER);
    }

    /* AUTHORIZATION */

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
            authorizer: authorizer, authorized: address(this), isAuthorized: true, nonce: 0, deadline: block.timestamp
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

    /* CONTROLLER */

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
        uint256 expectedCanceled = supplyShares.toAssetsDown(morpho.totalSupplyAssets(id), morpho.totalSupplyShares(id));
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

    /* EVENTS */

    function testSettleEmitsEvent() public {
        _openPosition(100e18, 100e18, 70e18);
        uint256 supplyShares = morpho.supplyShares(id, address(this)) / 2;
        uint256 expectedCanceled = supplyShares.toAssetsDown(morpho.totalSupplyAssets(id), morpho.totalSupplyShares(id));
        uint256 expectedSeized = _seizedFor(expectedCanceled);
        uint256 expectedCanceledShares =
            expectedCanceled.toSharesUp(morpho.totalBorrowAssets(id), morpho.totalBorrowShares(id));

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.Settle(
            id,
            address(this),
            address(this),
            BORROWER,
            supplyShares,
            expectedCanceled,
            expectedCanceledShares,
            expectedSeized
        );
        _lido().settle(marketParams, 0, supplyShares, address(this), BORROWER, RECEIVER);
    }

    /* LIFECYCLE */

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

        // Canceling the entire stake zeroes the market exactly.
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

        uint256 supplySharesBefore = morpho.supplyShares(id, address(this));
        uint256 borrowSharesBefore = morpho.borrowShares(id, address(this));
        uint256 tBABefore = morpho.totalBorrowAssets(id);
        uint256 tBSBefore = morpho.totalBorrowShares(id);
        uint256 tSABefore = morpho.totalSupplyAssets(id);
        uint256 tSSBefore = morpho.totalSupplyShares(id);

        // onBehalf == borrower == address(this). Borrow-driven: `slice` is a BORROW-share count, burned exactly.
        uint256 slice = bound(sliceSeed, borrowSharesBefore / 4, (borrowSharesBefore * 3) / 4);
        (uint256 seized, uint256 canceled) =
            _lido().settle(marketParams, 0, slice, address(this), address(this), RECEIVER);
        assertEq(seized, canceled.mulDivDown(ORACLE_PRICE_SCALE, oracle.price()), "seized the cancelled debt's worth");

        // The slice burns exactly `slice` borrow shares; the debt is valued up; supply funds it via toSharesUp.
        assertEq(canceled, slice.toAssetsUp(tBABefore, tBSBefore), "debtCanceled == toAssetsUp(borrowShares)");
        assertEq(morpho.borrowShares(id, address(this)), borrowSharesBefore - slice, "self: debt shares burned exactly");
        assertEq(
            morpho.supplyShares(id, address(this)),
            supplySharesBefore - canceled.toSharesUp(tSABefore, tSSBefore),
            "self: supply shares burned"
        );
        assertEq(morpho.collateral(id, address(this)), collateral - seized, "self: collateral seized");
        assertEq(collateralToken.balanceOf(RECEIVER), seized, "receiver got the seized collateral");
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
        uint256 collateralSeized = debtCanceled.mulDivDown(ORACLE_PRICE_SCALE, newPrice);
        vm.assume(collateralSeized > 0 && collateralSeized <= collateral);
        uint256 sliceShares = debtCanceled * SharesMathLib.VIRTUAL_SHARES;

        uint256 tSA = morpho.totalSupplyAssets(id);

        _lido().settle(marketParams, 0, sliceShares, address(this), BORROWER, RECEIVER);

        // The loss is NOT socialized: total supply fell only by the canceled amount.
        assertEq(morpho.totalSupplyAssets(id), tSA - debtCanceled, "no bad-debt write-down");
        assertGt(morpho.borrowShares(id, BORROWER), 0, "residual debt remains");
    }
}
