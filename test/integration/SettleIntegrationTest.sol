// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTestWithController.sol";

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
    // single live position covers them all.
    function testSettleGuardReverts() public {
        _openPosition(100e18, 200e18, 100e18);

        // Market not created (same tokens, an lltv no market was created with).
        MarketParams memory uncreated = marketParams;
        uncreated.lltv = DEFAULT_TEST_LLTV / 2;
        vm.expectRevert(bytes(ErrorsLib.MARKET_NOT_CREATED));
        _lido().settle(uncreated, 1, address(this), BORROWER, RECEIVER);

        // Settlement disabled: the default BaseTest market (live IRM, no controller) never opted in.
        MarketParams memory base = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: DEFAULT_TEST_LLTV
        });
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_DISABLED));
        _lido().settle(base, 1, address(this), BORROWER, RECEIVER);

        // The exact borrow-share cut must be non-zero.
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_SLICE_TOO_SMALL));
        _lido().settle(marketParams, 0, address(this), BORROWER, RECEIVER);

        // Zero receiver.
        vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
        _lido().settle(marketParams, 1, address(this), BORROWER, address(0));

        // Caller not authorized to manage onBehalf.
        vm.prank(RECEIVER);
        vm.expectRevert(bytes(ErrorsLib.UNAUTHORIZED));
        _lido().settle(marketParams, 1, BORROWER, BORROWER, RECEIVER);

        // Borrower without debt: any cut exceeds it (the debt cap catches it). The getter is read
        // before expectRevert, which arms against the next external call.
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_DEBT));
        _lido().settle(marketParams, 1, address(this), ONBEHALF, RECEIVER);
    }

    /* AUTHORIZATION */

    function testSettleAuthorizedViaApproval() public {
        _openPosition(100e18, 100e18, 70e18);
        morpho.setAuthorization(RECEIVER, true);

        uint256 sharesBefore = morpho.supplyShares(id, address(this));
        uint256 borrowShares = morpho.borrowShares(id, BORROWER) / 2;

        vm.prank(RECEIVER);
        (,,, uint256 supplySharesBurned) = _lido().settle(marketParams, borrowShares, address(this), BORROWER, RECEIVER);

        assertEq(morpho.supplyShares(id, address(this)), sharesBefore - supplySharesBurned, "lender shares reduced");
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
        uint256 borrowShares = morpho.borrowShares(id, BORROWER) / 2;
        (,,, uint256 supplySharesBurned) = _lido().settle(marketParams, borrowShares, authorizer, BORROWER, RECEIVER);

        assertEq(morpho.nonce(authorizer), 1, "signature consumed");
        assertEq(
            morpho.supplyShares(id, authorizer), sharesBefore - supplySharesBurned, "settled via sig authorization"
        );
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
        _lido().settle(marketParams, overDebtSlice, address(this), BORROWER, RECEIVER);

        // Collateral cap fires without a dispatch.
        oracle.setPrice(ORACLE_PRICE_SCALE / 2);
        uint256 overCollateralSlice = 60e18 * SharesMathLib.VIRTUAL_SHARES;
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_COLLATERAL));
        _lido().settle(marketParams, overCollateralSlice, address(this), BORROWER, RECEIVER);

        assertEq(controller.eventCount(ILidoLendMarketController.HookEvent.Settle), 0, "settle hook never dispatched");
    }

    function testSettleControllerCanBlock() public {
        _openPosition(100e18, 100e18, 70e18);
        controller.setRevertOn(ILidoLendMarketController.HookEvent.Settle, true);
        uint256 borrowShares = morpho.borrowShares(id, BORROWER) / 2;

        uint256 supplyBefore = morpho.supplyShares(id, address(this));
        uint256 borrowBefore = morpho.borrowShares(id, BORROWER);
        uint256 collatBefore = morpho.collateral(id, BORROWER);
        uint256 receiverBefore = collateralToken.balanceOf(RECEIVER);

        vm.expectRevert(bytes("blocked by controller"));
        _lido().settle(marketParams, borrowShares, address(this), BORROWER, RECEIVER);

        // The hook fires before any state write, so a veto must leave every touched slot untouched.
        assertEq(morpho.supplyShares(id, address(this)), supplyBefore, "supply shares unchanged");
        assertEq(morpho.borrowShares(id, BORROWER), borrowBefore, "borrow shares unchanged");
        assertEq(morpho.collateral(id, BORROWER), collatBefore, "collateral unchanged");
        assertEq(collateralToken.balanceOf(RECEIVER), receiverBefore, "receiver balance unchanged");
    }

    // The hook payload and the Settle event carry the same derived values; one pass pins both.
    function testSettleHookPayloadAndEvent() public {
        _openPosition(100e18, 100e18, 70e18);
        uint256 expectedCanceledShares = morpho.borrowShares(id, BORROWER) / 2;
        uint256 expectedCanceled =
            expectedCanceledShares.toAssetsUp(morpho.totalBorrowAssets(id), morpho.totalBorrowShares(id));
        uint256 expectedSupplyShares =
            expectedCanceled.toSharesUp(morpho.totalSupplyAssets(id), morpho.totalSupplyShares(id));
        uint256 expectedSeized = _seizedFor(expectedCanceled);

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.Settle(
            id,
            address(this),
            address(this),
            BORROWER,
            RECEIVER,
            expectedSupplyShares,
            expectedCanceled,
            expectedCanceledShares,
            expectedSeized
        );
        _lido().settle(marketParams, expectedCanceledShares, address(this), BORROWER, RECEIVER);

        assertEq(uint8(controller.lastEvent()), uint8(ILidoLendMarketController.HookEvent.Settle), "hook event");
        assertEq(Id.unwrap(controller.lastId()), Id.unwrap(id), "hook market id");

        ILidoLendMarketController.SettleHookData memory d =
            abi.decode(controller.lastData(), (ILidoLendMarketController.SettleHookData));
        assertEq(d.caller, address(this), "caller");
        assertEq(d.onBehalf, address(this), "onBehalf");
        assertEq(d.borrower, BORROWER, "borrower");
        assertEq(d.receiver, RECEIVER, "receiver");
        assertEq(d.supplySharesBurned, expectedSupplyShares, "supplySharesBurned");
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

        uint256 borrowerShares = morpho.borrowShares(id, BORROWER);
        uint256 slice = bound(sliceSeed, borrowerShares / 4, (borrowerShares * 3) / 4);
        uint256 expectedSeized = _seizedForShares(id, slice);
        (uint256 seized,,,) = _lido().settle(marketParams, slice, address(this), BORROWER, RECEIVER);
        assertEq(seized, expectedSeized, "seized the cut's rounded-down worth");
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

        uint256 allShares = morpho.borrowShares(id, BORROWER);
        (uint256 seized,,,) = _lido().settle(marketParams, allShares, address(this), BORROWER, RECEIVER);

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
        // onBehalf == borrower == address(this).
        uint256 slice = bound(sliceSeed, borrowSharesBefore / 4, (borrowSharesBefore * 3) / 4);
        uint256 expectedSeized = _seizedForShares(id, slice);
        (uint256 seized,, uint256 borrowSharesCanceled, uint256 supplySharesBurned) =
            _lido().settle(marketParams, slice, address(this), address(this), RECEIVER);
        assertEq(seized, expectedSeized, "seized the cut's rounded-down worth");

        assertEq(borrowSharesCanceled, slice, "self: exact debt shares canceled");
        assertEq(
            morpho.supplyShares(id, address(this)),
            supplySharesBefore - supplySharesBurned,
            "self: supply shares burned"
        );
        assertEq(morpho.borrowShares(id, address(this)), borrowSharesBefore - slice, "self: debt shares burned");
        assertEq(morpho.collateral(id, address(this)), collateral - seized, "self: collateral seized");
        assertEq(collateralToken.balanceOf(RECEIVER), seized, "receiver got the seized collateral");
    }

    // With this controller, settlement can leave bad debt unrealized because the core has no
    // post-settlement solvency check (unlike `liquidate`).
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

        _lido().settle(marketParams, sliceShares, address(this), BORROWER, RECEIVER);

        // The loss is NOT socialized: total supply fell only by the canceled amount, and the borrower
        // keeps the residual debt exactly (1:1 index: debtCanceled < borrowed, so the burn < holding).
        assertEq(morpho.totalSupplyAssets(id), tSA - debtCanceled, "no bad-debt write-down");
        assertEq(
            morpho.borrowShares(id, BORROWER),
            held - debtCanceled * SharesMathLib.VIRTUAL_SHARES,
            "residual debt remains"
        );
    }

    function testOneCollateralUnitTopUpEnablesBadDebtRealization() public {
        (MarketParams memory params, Id marketId) = _settleToZeroCollateralWithResidualDebt();
        uint256 liquidationIncentiveFactor = _liquidationIncentiveFactor(params.lltv);

        uint256 oneShareSeized = uint256(1)
            .toAssetsDown(morpho.totalBorrowAssets(marketId), morpho.totalBorrowShares(marketId))
            .wMulDown(liquidationIncentiveFactor).mulDivDown(ORACLE_PRICE_SCALE, oracle.price());
        assertGt(oneShareSeized, 0, "direct one-share liquidation requires collateral");

        vm.prank(LIQUIDATOR);
        vm.expectRevert(stdError.arithmeticError);
        morpho.liquidate(params, BORROWER, 0, 1, hex"");

        // Supplying collateral for another account and liquidating it are both permissionless.
        collateralToken.setBalance(LIQUIDATOR, 1);
        vm.prank(LIQUIDATOR);
        morpho.supplyCollateral(params, 1, BORROWER, hex"");

        uint256 totalBorrowAssetsBefore = morpho.totalBorrowAssets(marketId);
        uint256 totalBorrowSharesBefore = morpho.totalBorrowShares(marketId);
        uint256 totalSupplyAssetsBefore = morpho.totalSupplyAssets(marketId);
        uint256 repaidShares = uint256(1).mulDivUp(oracle.price(), ORACLE_PRICE_SCALE)
            .wDivUp(liquidationIncentiveFactor).toSharesUp(totalBorrowAssetsBefore, totalBorrowSharesBefore);
        assertLt(repaidShares, morpho.borrowShares(marketId, BORROWER), "liquidation leaves shares to write off");

        uint256 expectedRepaidAssets = repaidShares.toAssetsUp(totalBorrowAssetsBefore, totalBorrowSharesBefore);
        loanToken.setBalance(LIQUIDATOR, expectedRepaidAssets);

        vm.prank(LIQUIDATOR);
        (uint256 seizedAssets, uint256 repaidAssets) = morpho.liquidate(params, BORROWER, 1, 0, hex"");

        assertEq(seizedAssets, 1, "top-up seized");
        assertEq(repaidAssets, expectedRepaidAssets, "liquidator-funded repayment");
        assertEq(morpho.collateral(marketId, BORROWER), 0, "collateral returned to zero");
        assertEq(morpho.borrowShares(marketId, BORROWER), 0, "residual borrow shares cleared");
        assertEq(morpho.totalBorrowShares(marketId), 0, "all market borrow shares cleared");
        assertLt(
            morpho.totalBorrowAssets(marketId),
            totalBorrowAssetsBefore - expectedRepaidAssets,
            "bad debt reduced borrow assets"
        );
        assertLt(morpho.totalSupplyAssets(marketId), totalSupplyAssetsBefore, "bad debt charged to suppliers");
        assertEq(collateralToken.balanceOf(LIQUIDATOR), 1, "liquidator recovered the top-up");
        assertEq(loanToken.balanceOf(LIQUIDATOR), 0, "liquidator funded the repayment");
    }

    function _settleToZeroCollateralWithResidualDebt() internal returns (MarketParams memory params, Id marketId) {
        params = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.79 ether
        });
        marketId = params.id();
        ControllerMock marketController = new ControllerMock(marketId);

        vm.prank(OWNER);
        _lido().createMarket(params, address(marketController), true);
        oracle.setPrice(ORACLE_PRICE_SCALE);

        uint256 initialCollateral = 1e18;
        _supplyAs(params, address(this), 100);
        _borrowAs(params, BORROWER, initialCollateral, 100);

        // Drive the index high enough that repaying one raw borrow share seizes positive collateral.
        for (uint256 i; i < 15; ++i) {
            vm.warp(block.timestamp + 365 days);
            morpho.accrueInterest(params);
        }

        uint256 cutShares = morpho.borrowShares(marketId, BORROWER) / 2;
        uint256 collateralForCut =
            cutShares.toAssetsDown(morpho.totalBorrowAssets(marketId), morpho.totalBorrowShares(marketId));
        assertLt(collateralForCut, initialCollateral, "fixture collateral fits the initial position");

        // Keep the borrower healthy while trimming collateral to exactly what settlement will seize.
        oracle.setPrice(10 * ORACLE_PRICE_SCALE);
        vm.prank(BORROWER);
        morpho.withdrawCollateral(params, initialCollateral - collateralForCut, BORROWER, BORROWER);
        oracle.setPrice(ORACLE_PRICE_SCALE);

        _lido().settle(params, cutShares, address(this), BORROWER, RECEIVER);
        assertEq(morpho.collateral(marketId, BORROWER), 0, "settlement exhausted collateral");
        assertGt(morpho.borrowShares(marketId, BORROWER), 0, "settlement left residual debt");
    }

    /* FULL CLOSE */

    // A second borrower keeps the market at zero free liquidity while the exact borrow-share input closes
    // BORROWER to zero. Asserts the deltas, the Settle event, and the hook payload.
    function testSettleClosesToZero() public {
        _supply(100e18);
        _borrowAs(marketParams, BORROWER, 80e18, 60e18);
        _borrowAs(marketParams, REPAYER, 60e18, 40e18); // free liquidity 0

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
            _lido().settle(marketParams, s.held, address(this), BORROWER, RECEIVER);

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

    // Fuzz: across a healthy price range, the exact borrow-share input closes the borrower to zero, cancels
    // the debt valued up, seizes the matching collateral, and leaves the market solvent.
    function testSettleCloseFuzz(uint256 supplied, uint256 priceSeed) public {
        supplied = bound(supplied, 4 * MIN_TEST_AMOUNT, MAX_TEST_AMOUNT / 2);
        _setFuzzedPrice(priceSeed);
        uint256 b1 = supplied / 2;
        _supply(supplied);
        _borrowAs(marketParams, BORROWER, 2 * supplied, b1);
        _borrowAs(marketParams, REPAYER, 2 * supplied, supplied - b1); // free liquidity 0

        uint256 held = morpho.borrowShares(id, BORROWER);
        uint256 expectedCanceled = held.toAssetsUp(morpho.totalBorrowAssets(id), morpho.totalBorrowShares(id));

        (uint256 seized, uint256 canceled,,) = _lido().settle(marketParams, held, address(this), BORROWER, RECEIVER);

        assertEq(morpho.borrowShares(id, BORROWER), 0, "borrower closed to zero");
        assertEq(canceled, expectedCanceled, "canceled == debt valued up");
        assertEq(seized, _seizedFor(canceled), "seized at the oracle price");
        // Supply and borrow fell by the same `canceled`, so the zero free liquidity is preserved exactly.
        assertEq(morpho.totalSupplyAssets(id), morpho.totalBorrowAssets(id), "free liquidity stays zero");
    }
}
