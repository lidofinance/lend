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

    struct CloseSnap {
        uint256 held;
        uint256 canceled;
        uint256 supplyBurn;
        uint256 seized;
        uint256 lenderShares;
        uint256 totalSupplyShares;
        uint256 totalSupplyAssets;
        uint256 totalBorrowShares;
        uint256 totalBorrowAssets;
        uint256 collateral;
        uint256 receiver;
        uint256 secondBorrow;
    }

    /// @dev Settle tests run at a non-1:1 price so the loan->collateral conversion is actually exercised instead
    ///      of collapsing to identity. Tests needing a specific price override it.
    function setUp() public override {
        super.setUp();
        oracle.setPrice(137 * ORACLE_PRICE_SCALE / 100); // collateral worth 1.37x the loan token
    }

    /* ACCESS CONTROL */

    // Every pre-derivation guard, in check order. Each guard reverts before any state is written, so a
    // single live position covers them all. (The settleable-supply gate needs its own liquidity
    // structure and lives in testSettleCannotCancelMoreThanOwned.)
    function testSettleGuardReverts() public {
        _openPosition(100e18, 200e18, 100e18);

        // Market not created (same tokens, an lltv no market was created with).
        MarketParams memory uncreated = marketParams;
        uncreated.lltv = DEFAULT_TEST_LLTV / 2;
        vm.expectRevert(bytes(ErrorsLib.MARKET_NOT_CREATED));
        _lido().settle(uncreated, 0, 1, address(this), BORROWER, RECEIVER);

        // Settlement disabled: the default BaseTest market (live IRM, no controller) never opted in.
        MarketParams memory base = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: DEFAULT_TEST_LLTV
        });
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_DISABLED));
        _lido().settle(base, 0, 1, address(this), BORROWER, RECEIVER);

        // Exactly one anchor must be non-zero.
        vm.expectRevert(bytes(ErrorsLib.INCONSISTENT_INPUT));
        _lido().settle(marketParams, 1, 1, address(this), BORROWER, RECEIVER);
        vm.expectRevert(bytes(ErrorsLib.INCONSISTENT_INPUT));
        _lido().settle(marketParams, 0, 0, address(this), BORROWER, RECEIVER);

        // Zero receiver.
        vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
        _lido().settle(marketParams, 0, 1, address(this), BORROWER, address(0));

        // Caller not authorized to manage onBehalf.
        vm.prank(RECEIVER);
        vm.expectRevert(bytes(ErrorsLib.UNAUTHORIZED));
        _lido().settle(marketParams, 0, 1, BORROWER, BORROWER, RECEIVER);

        // Borrower without debt: any cut exceeds it (the debt cap catches it). The getter is read
        // before expectRevert, which arms against the next external call.
        uint256 halfSupply = morpho.supplyShares(id, address(this)) / 2;
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_DEBT));
        _lido().settle(marketParams, halfSupply, 0, address(this), ONBEHALF, RECEIVER);
    }

    // The lender's whole supply sits within free liquidity so its settleable supply is 0; the gate
    // rejects any cut against it cleanly (no underflow), before the share subtraction. Fuzzed across
    // the whole range that stays within BORROWER's 100e18 debt (the debt cap is checked first).
    function testSettleCannotCancelMoreThanOwned(uint256 cutSeed) public {
        uint256 borrowed = 100e18;
        loanToken.setBalance(SUPPLIER, 100e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 100e18, 0, SUPPLIER, hex"");
        _openPosition(10e18, 200e18, borrowed);

        uint256 cut = bound(cutSeed, 1, borrowed);
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_SETTLEABLE_SUPPLY));
        _lido().settle(marketParams, cut * SharesMathLib.VIRTUAL_SHARES, 0, address(this), BORROWER, RECEIVER);
    }

    /* AUTHORIZATION */

    function testSettleAuthorizedViaApproval() public {
        _openPosition(100e18, 100e18, 70e18);
        morpho.setAuthorization(RECEIVER, true);

        uint256 sharesBefore = morpho.supplyShares(id, address(this));
        uint256 supplyShares = sharesBefore / 2;

        vm.prank(RECEIVER);
        _lido().settle(marketParams, supplyShares, 0, address(this), BORROWER, RECEIVER);

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
        _lido().settle(marketParams, sharesBefore / 2, 0, authorizer, BORROWER, RECEIVER);

        assertEq(morpho.nonce(authorizer), 1, "signature consumed");
        assertEq(morpho.supplyShares(id, authorizer), sharesBefore - sharesBefore / 2, "settled via sig authorization");
    }

    /* CONTROLLER */

    // The core validates the cut before consulting the controller: an invalid cut reverts with the
    // core's own error and the settle hook is never dispatched. Controllers rely on this — they trust
    // `shares <= debt` and `0 < seize <= collateral` without re-checking.
    function testSettleGuardsPrecedeHook() public {
        uint256 borrowed = 70e18;
        _openPosition(100e18, 100e18, borrowed);
        // Armed to revert: were the hook consulted, the revert reason would be the controller's.
        controller.setRevertOn(ILidoLendMarketController.HookEvent.Settle, true);

        // Debt cap fires without a dispatch.
        uint256 overDebtSlice = (borrowed + 1e18) * SharesMathLib.VIRTUAL_SHARES;
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_DEBT));
        _lido().settle(marketParams, overDebtSlice, 0, address(this), BORROWER, RECEIVER);

        // Collateral cap fires without a dispatch.
        oracle.setPrice(ORACLE_PRICE_SCALE / 2);
        uint256 overCollateralSlice = 60e18 * SharesMathLib.VIRTUAL_SHARES;
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_COLLATERAL));
        _lido().settle(marketParams, overCollateralSlice, 0, address(this), BORROWER, RECEIVER);

        assertEq(controller.eventCount(ILidoLendMarketController.HookEvent.Settle), 0, "settle hook never dispatched");
    }

    function testSettleControllerCanBlock() public {
        _openPosition(100e18, 100e18, 70e18);
        controller.setRevertOn(ILidoLendMarketController.HookEvent.Settle, true);
        uint256 supplyShares = morpho.supplyShares(id, address(this)) / 2;

        uint256 supplyBefore = morpho.supplyShares(id, address(this));
        uint256 borrowBefore = morpho.borrowShares(id, BORROWER);
        uint256 collatBefore = morpho.collateral(id, BORROWER);
        uint256 receiverBefore = collateralToken.balanceOf(RECEIVER);

        vm.expectRevert(bytes("blocked by controller"));
        _lido().settle(marketParams, supplyShares, 0, address(this), BORROWER, RECEIVER);

        // The hook fires before any state write, so a veto must leave every touched slot untouched.
        assertEq(morpho.supplyShares(id, address(this)), supplyBefore, "supply shares unchanged");
        assertEq(morpho.borrowShares(id, BORROWER), borrowBefore, "borrow shares unchanged");
        assertEq(morpho.collateral(id, BORROWER), collatBefore, "collateral unchanged");
        assertEq(collateralToken.balanceOf(RECEIVER), receiverBefore, "receiver balance unchanged");
    }

    // The hook payload and the Settle event carry the same derived values; one pass pins both.
    function testSettleHookPayloadAndEvent() public {
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
            RECEIVER,
            supplyShares,
            expectedCanceled,
            expectedCanceledShares,
            expectedSeized
        );
        _lido().settle(marketParams, supplyShares, 0, address(this), BORROWER, RECEIVER);

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

    /* LIFECYCLE */

    function testSettleBorrowerExitsWhole(uint256 supplied, uint256 sliceSeed, uint256 priceSeed) public {
        supplied = bound(supplied, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT / 2);
        uint256 collateral = 2 * supplied;
        _setFuzzedPrice(priceSeed);
        _openPosition(supplied, collateral, supplied); // supply == borrow → free liquidity 0

        uint256 lenderShares = morpho.supplyShares(id, address(this));
        uint256 slice = bound(sliceSeed, lenderShares / 4, (lenderShares * 3) / 4);
        (uint256 seized, uint256 canceled,,) = _lido().settle(marketParams, slice, 0, address(this), BORROWER, RECEIVER);
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
        (uint256 seized,,,) = _lido().settle(marketParams, allShares, 0, address(this), BORROWER, RECEIVER);

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
        uint256 totalBorrowAssetsBefore = morpho.totalBorrowAssets(id);
        uint256 totalBorrowSharesBefore = morpho.totalBorrowShares(id);

        // onBehalf == borrower == address(this).
        uint256 slice = bound(sliceSeed, supplySharesBefore / 4, (supplySharesBefore * 3) / 4);
        (uint256 seized, uint256 canceled,,) =
            _lido().settle(marketParams, slice, 0, address(this), address(this), RECEIVER);
        assertEq(seized, canceled.mulDivDown(ORACLE_PRICE_SCALE, oracle.price()), "seized the cancelled debt's worth");

        uint256 burn = canceled.toSharesUp(totalBorrowAssetsBefore, totalBorrowSharesBefore);
        assertEq(morpho.supplyShares(id, address(this)), supplySharesBefore - slice, "self: supply shares burned");
        assertEq(morpho.borrowShares(id, address(this)), borrowSharesBefore - burn, "self: debt shares burned");
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
        uint256 held = morpho.borrowShares(id, BORROWER);

        _lido().settle(marketParams, sliceShares, 0, address(this), BORROWER, RECEIVER);

        // The loss is NOT socialized: total supply fell only by the canceled amount, and the borrower
        // keeps the residual debt exactly (1:1 index: debtCanceled < borrowed, so the burn < holding).
        assertEq(morpho.totalSupplyAssets(id), tSA - debtCanceled, "no bad-debt write-down");
        assertEq(
            morpho.borrowShares(id, BORROWER),
            held - debtCanceled * SharesMathLib.VIRTUAL_SHARES,
            "residual debt remains"
        );
    }

    /* BORROW-ANCHORED (closes the position to zero) */

    // A second borrower soaks the rest of the liquidity, so the lender's settleable supply exceeds BORROWER's
    // debt and the borrowShares anchor closes BORROWER to exactly zero. Asserts the borrow-anchored deltas,
    // the Settle event, and the hook payload. (The sole-borrower-whole-pool case, where this cap blocks the
    // close, is its own test in SettleMathTest.)
    function testSettleBorrowAnchoredClosesToZero() public {
        _supply(100e18);
        _borrowAs(marketParams, BORROWER, 80e18, 60e18);
        _borrowAs(marketParams, REPAYER, 60e18, 40e18); // free liquidity 0, settleable > BORROWER debt

        CloseSnap memory s;
        s.held = morpho.borrowShares(id, BORROWER);
        s.totalBorrowAssets = morpho.totalBorrowAssets(id);
        s.totalBorrowShares = morpho.totalBorrowShares(id);
        s.totalSupplyAssets = morpho.totalSupplyAssets(id);
        s.totalSupplyShares = morpho.totalSupplyShares(id);
        s.canceled = s.held.toAssetsUp(s.totalBorrowAssets, s.totalBorrowShares);
        s.supplyBurn = s.canceled.toSharesUp(s.totalSupplyAssets, s.totalSupplyShares);
        s.seized = _seizedFor(s.canceled);
        s.lenderShares = morpho.supplyShares(id, address(this));
        s.collateral = morpho.collateral(id, BORROWER);
        s.receiver = collateralToken.balanceOf(RECEIVER);
        s.secondBorrow = morpho.borrowShares(id, REPAYER);

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.Settle(
            id, address(this), address(this), BORROWER, RECEIVER, s.supplyBurn, s.canceled, s.held, s.seized
        );
        (uint256 seized, uint256 canceled, uint256 sharesCanceled, uint256 sharesBurned) =
            _lido().settle(marketParams, 0, s.held, address(this), BORROWER, RECEIVER);

        assertEq(canceled, s.canceled, "canceled == debt valued up");
        assertEq(seized, s.seized, "seized at the oracle price");
        assertEq(sharesCanceled, s.held, "return borrowSharesCanceled == exact input");
        assertEq(sharesBurned, s.supplyBurn, "return supplySharesBurned == derived burn");
        assertEq(morpho.borrowShares(id, BORROWER), 0, "borrower closed to zero");
        assertEq(s.lenderShares - morpho.supplyShares(id, address(this)), s.supplyBurn, "supply burn derived from cut");
        assertEq(s.totalSupplyShares - morpho.totalSupplyShares(id), s.supplyBurn, "total supply shares -= burn");
        assertEq(s.totalSupplyAssets - morpho.totalSupplyAssets(id), canceled, "total supply assets -= canceled");
        assertEq(s.totalBorrowShares - morpho.totalBorrowShares(id), s.held, "total borrow shares -= holding");
        assertEq(s.totalBorrowAssets - morpho.totalBorrowAssets(id), canceled, "total borrow assets -= canceled");
        assertEq(s.collateral - morpho.collateral(id, BORROWER), seized, "collateral seized");
        assertEq(collateralToken.balanceOf(RECEIVER) - s.receiver, seized, "receiver got the collateral");
        assertEq(morpho.borrowShares(id, REPAYER), s.secondBorrow, "second borrower untouched");

        // The hook payload carries the exact debt-share input and the values derived from it.
        ILidoLendMarketController.SettleHookData memory d =
            abi.decode(controller.lastData(), (ILidoLendMarketController.SettleHookData));
        assertEq(d.supplySharesBurned, s.supplyBurn, "supplySharesBurned (derived)");
        assertEq(d.borrowAssetsCanceled, s.canceled, "borrowAssetsCanceled (debt valued up)");
        assertEq(d.borrowSharesCanceled, s.held, "borrowSharesCanceled == exact input");
        assertEq(d.seizedAssets, s.seized, "seizedAssets");
    }

    // Fuzz: across a healthy price range, the borrowShares anchor closes the borrower to exactly zero, cancels
    // the debt valued up, seizes the matching collateral, and leaves the market solvent.
    function testSettleBorrowAnchoredCloseFuzz(uint256 supplied, uint256 priceSeed) public {
        supplied = bound(supplied, 4 * MIN_TEST_AMOUNT, MAX_TEST_AMOUNT / 2);
        _setFuzzedPrice(priceSeed);
        uint256 b1 = supplied / 2;
        _supply(supplied);
        _borrowAs(marketParams, BORROWER, 2 * supplied, b1);
        _borrowAs(marketParams, REPAYER, 2 * supplied, supplied - b1); // free liquidity 0, settleable > BORROWER debt

        uint256 held = morpho.borrowShares(id, BORROWER);
        uint256 expectedCanceled = held.toAssetsUp(morpho.totalBorrowAssets(id), morpho.totalBorrowShares(id));

        (uint256 seized, uint256 canceled,,) = _lido().settle(marketParams, 0, held, address(this), BORROWER, RECEIVER);

        assertEq(morpho.borrowShares(id, BORROWER), 0, "borrower closed to zero");
        assertEq(canceled, expectedCanceled, "canceled == debt valued up");
        assertEq(seized, _seizedFor(canceled), "seized at the oracle price");
        // Supply and borrow fell by the same `canceled`, so the zero free liquidity is preserved exactly.
        assertEq(morpho.totalSupplyAssets(id), morpho.totalBorrowAssets(id), "free liquidity stays zero");
    }
}
