// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../InvariantTest.sol";

import {ILidoBlue} from "../../src/interfaces/ILidoBlue.sol";
import {EnforcingControllerMock} from "../../src/mocks/EnforcingControllerMock.sol";
import {OracleMock} from "../../src/mocks/OracleMock.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";

// Invariant suite for `deleverage` on one controller-bound market with two borrowers. The market is kept
// near zero free liquidity (LENDER supplies, a borrower borrows the same) so the liquidity gate clears;
// `warp` lets interest compound the share/asset rate far from 1:1; `setControllerPrice` swings health so a
// borrower can go underwater. The controller enforces post-cut solvency — the bad-debt backstop the real
// LidoMarketController must provide. `deleverageNoRevert` asserts the exact post-state of every successful
// cut against the contract's *returned* values plus an independent collateral-value-conservation bound, so
// it catches a wrong formula and not just a regressed one. Deterministic tests cover the branches fuzzing
// reaches rarely: the controller blocking an insolvent cut, and the gate blocking a cut while liquidity
// exists.
//
// Out of scope (covered elsewhere or known limits): caller != onBehalf authorization (integration tests),
// and a second supplier (only the borrow side is multi-position here).
contract DeleverageInvariantTest is InvariantTest {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MorphoLib for IMorpho;
    using MarketParamsLib for MarketParams;

    uint256 internal constant MIN_PRICE = ORACLE_PRICE_SCALE / 100;
    uint256 internal constant MAX_PRICE = ORACLE_PRICE_SCALE * 10;
    uint256 internal constant MARKET_FEE = 0.1e18;
    // Stop accruing once borrow assets reach this, so interest can drift the rate ~100x without ever
    // overflowing the uint128 totals (a single 365d/100%-APR step at the cap stays well under uint128 max).
    uint256 internal constant DRIFT_CAP = 100 * MAX_TEST_AMOUNT;

    address internal LENDER;
    address internal LENDER2; // second supplier; never acts again — a cut must leave its position untouched
    address internal CB; // controller-market borrower
    address internal CB2; // second borrower (bystander when a cut targets CB, and vice versa)

    MarketParams internal cParams;
    Id internal cId;
    EnforcingControllerMock internal cController;
    OracleMock internal cOracle; // dedicated oracle: a distinct market id, and price swings stay isolated

    struct Cut {
        bool ok;
        uint256 sliceShares;
        uint256 debtCanceled;
        uint256 collateralSeized;
        uint256 burn;
        bool insolvent;
    }

    struct Bal {
        uint256 lenderSupplyShares;
        uint256 totalSupplyShares;
        uint256 totalSupplyAssets;
        uint256 borrowerBorrowShares;
        uint256 totalBorrowShares;
        uint256 totalBorrowAssets;
        uint256 collateral;
        uint256 receiverCollateralBalance;
        uint256 bystanderBorrowShares;
        uint256 bystanderCollateral;
        uint256 lender2Shares;
    }

    function _targetSenders() internal override {
        LENDER = makeAddr("Lender");
        _targetSender(LENDER);
    }

    function setUp() public override {
        selectors.push(this.topUpControllerMarket.selector);
        selectors.push(this.deleverageNoRevert.selector);
        selectors.push(this.setControllerPrice.selector);
        selectors.push(this.warp.selector);

        super.setUp();

        cOracle = new OracleMock();
        cOracle.setPrice(ORACLE_PRICE_SCALE);
        cParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(cOracle),
            irm: address(irm),
            lltv: DEFAULT_TEST_LLTV
        });
        cId = cParams.id();
        cController = new EnforcingControllerMock(cId, address(morpho), address(cOracle));
        vm.startPrank(OWNER);
        ILidoBlue(address(morpho)).createMarket(cParams, address(cController), true);
        morpho.setFee(cParams, MARKET_FEE);
        vm.stopPrank();

        CB = makeAddr("ControllerBorrower");
        CB2 = makeAddr("ControllerBorrower2");
        // A price drop can push a borrower underwater; debt (capped to MAX_TEST_AMOUNT in topUp) keeps
        // shares within uint128.
        _seedBorrower(CB);
        _seedBorrower(CB2);

        // A second lender that never acts again. Every cut targets onBehalf == LENDER, so LENDER2's position
        // must stay untouched. Its supply is matched by a CB borrow so free liquidity stays ~0.
        LENDER2 = makeAddr("Lender2");
        uint256 seed = MAX_TEST_AMOUNT / 10;
        loanToken.setBalance(LENDER2, seed);
        vm.startPrank(LENDER2);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(cParams, seed, 0, LENDER2, hex"");
        vm.stopPrank();
        vm.prank(CB);
        morpho.borrow(cParams, seed, 0, CB, CB);
    }

    function _seedBorrower(address borrower) internal {
        vm.startPrank(borrower);
        loanToken.approve(address(morpho), type(uint256).max);
        collateralToken.approve(address(morpho), type(uint256).max);
        vm.stopPrank();

        collateralToken.setBalance(borrower, MAX_TEST_AMOUNT);
        vm.prank(borrower);
        morpho.supplyCollateral(cParams, MAX_TEST_AMOUNT, borrower, hex"");
    }

    /* HANDLERS */

    function setControllerPrice(uint256 price) external {
        cOracle.setPrice(bound(price, MIN_PRICE, MAX_PRICE));
    }

    function warp(uint256 elapsed) external {
        if (morpho.totalBorrowAssets(cId) > DRIFT_CAP) return;
        _forward(bound(elapsed, 1 hours, 365 days) / BLOCK_TIME);
    }

    // Keeps the market near zero free liquidity (LENDER supplies, the borrower borrows the same), growing
    // the borrower's debt within both its health cap and MAX_TEST_AMOUNT, with headroom against rounding.
    function topUpControllerMarket(uint256 borrowerSeed, uint256 amount) external {
        morpho.accrueInterest(cParams);

        address borrower = borrowerSeed % 2 == 0 ? CB : CB2;
        uint256 price = cOracle.price();
        uint256 debt =
            morpho.borrowShares(cId, borrower).toAssetsUp(morpho.totalBorrowAssets(cId), morpho.totalBorrowShares(cId));
        uint256 maxDebt = Math.min(
            MAX_TEST_AMOUNT,
            morpho.collateral(cId, borrower).mulDivDown(price, ORACLE_PRICE_SCALE).wMulDown(cParams.lltv)
        );
        if (maxDebt <= debt + 2 * MIN_TEST_AMOUNT) return;

        amount = bound(amount, MIN_TEST_AMOUNT, (maxDebt - debt) / 2);

        loanToken.setBalance(LENDER, amount);
        vm.prank(LENDER);
        morpho.supply(cParams, amount, 0, LENDER, hex"");
        vm.prank(borrower);
        morpho.borrow(cParams, amount, 0, borrower, borrower);
    }

    function deleverageNoRevert(uint256 borrowerSeed, uint256 sliceSeed) external {
        morpho.accrueInterest(cParams);

        address borrower = borrowerSeed % 2 == 0 ? CB : CB2;
        Cut memory c = _findCut(borrower, sliceSeed);
        if (!c.ok || c.insolvent) return;

        _executeAndAssertCut(borrower, c);
    }

    /* DETERMINISTIC TESTS */

    // Happy path, asserted independently of fuzzing luck: guarantees a solvency-preserving cut both
    // executes and lands its exact deltas, so the suite cannot silently go vacuous if a handler bound
    // later stops the fuzzer from ever firing a real cut.
    function test_deleverageHappyPath() public {
        uint256 amount = MAX_TEST_AMOUNT / 4;
        loanToken.setBalance(LENDER, amount);
        vm.prank(LENDER);
        morpho.supply(cParams, amount, 0, LENDER, hex"");
        vm.prank(CB);
        morpho.borrow(cParams, amount, 0, CB, CB);

        Cut memory c = _findCut(CB, morpho.supplyShares(cId, LENDER) / 2);
        assertTrue(c.ok && !c.insolvent, "setup: expected a core-valid, solvent cut");

        _executeAndAssertCut(CB, c);
    }

    // The controller is the only bad-debt backstop (the core has none); "an insolvent-leaving cut is
    // rejected" is deterministic, so assert it directly instead of hoping the fuzzer lands the rare
    // underwater + valid-slice coincidence.
    function test_controllerBlocksInsolventCut() public {
        uint256 price = cOracle.price();
        uint256 amount = morpho.collateral(cId, CB).mulDivDown(price, ORACLE_PRICE_SCALE).wMulDown(cParams.lltv) / 2;
        loanToken.setBalance(LENDER, amount);
        vm.prank(LENDER);
        morpho.supply(cParams, amount, 0, LENDER, hex"");
        vm.prank(CB);
        morpho.borrow(cParams, amount, 0, CB, CB);

        cOracle.setPrice(price / 5); // collateral value drops to ~2x below the debt

        // Quarter stake: small enough to pass the core's pre-hook checks, too small to cure the deficit.
        Cut memory c = _findCut(CB, morpho.supplyShares(cId, LENDER) / 4);
        assertTrue(c.ok && c.insolvent, "setup: expected a core-valid, insolvent-leaving cut");

        vm.prank(LENDER);
        vm.expectRevert(bytes("controller: would be insolvent"));
        ILidoBlue(address(morpho)).deleverage(cParams, c.sliceShares, CB, LENDER, LENDER);
    }

    // deleverage is the fallback for when ordinary liquidity is gone; the gate must reject a cut whose
    // canceled debt could simply be repaid from free liquidity instead.
    function test_deleverageBlockedWhenLiquidityAvailable() public {
        uint256 borrowAmount = MAX_TEST_AMOUNT / 8;
        loanToken.setBalance(LENDER, 2 * borrowAmount);
        vm.prank(LENDER);
        morpho.supply(cParams, 2 * borrowAmount, 0, LENDER, hex""); // avail = borrowAmount > 0
        vm.prank(CB);
        morpho.borrow(cParams, borrowAmount, 0, CB, CB);

        // debtCanceled ~ a quarter of supply < avail, so the gate must block.
        uint256 sliceShares = morpho.supplyShares(cId, LENDER) / 4;
        vm.prank(LENDER);
        vm.expectRevert(bytes(ErrorsLib.DELEVERAGE_LIQUIDITY_AVAILABLE));
        ILidoBlue(address(morpho)).deleverage(cParams, sliceShares, CB, LENDER, LENDER);
    }

    /* INVARIANTS */

    function invariantSupplyShares() public {
        uint256 sum = morpho.supplyShares(cId, LENDER) + morpho.supplyShares(cId, LENDER2)
            + morpho.supplyShares(cId, CB) + morpho.supplyShares(cId, CB2) + morpho.supplyShares(cId, FEE_RECIPIENT);
        assertEq(sum, morpho.totalSupplyShares(cId), "supply shares");
    }

    function invariantBorrowShares() public {
        uint256 sum = morpho.borrowShares(cId, LENDER) + morpho.borrowShares(cId, CB) + morpho.borrowShares(cId, CB2)
            + morpho.borrowShares(cId, FEE_RECIPIENT);
        assertEq(sum, morpho.totalBorrowShares(cId), "borrow shares");
    }

    /* HELPERS */

    // Submits the cut and asserts: exact deltas on every touched slot (against the contract's returned
    // values), the bystander borrower is untouched, and seized collateral is worth no more than the debt
    // canceled (value conservation, derived independently of the contract's seize formula).
    function _executeAndAssertCut(address borrower, Cut memory c) internal {
        address bystander = borrower == CB ? CB2 : CB;
        uint256 price = cOracle.price();

        Bal memory b = Bal({
            lenderSupplyShares: morpho.supplyShares(cId, LENDER),
            totalSupplyShares: morpho.totalSupplyShares(cId),
            totalSupplyAssets: morpho.totalSupplyAssets(cId),
            borrowerBorrowShares: morpho.borrowShares(cId, borrower),
            totalBorrowShares: morpho.totalBorrowShares(cId),
            totalBorrowAssets: morpho.totalBorrowAssets(cId),
            collateral: morpho.collateral(cId, borrower),
            receiverCollateralBalance: collateralToken.balanceOf(LENDER),
            bystanderBorrowShares: morpho.borrowShares(cId, bystander),
            bystanderCollateral: morpho.collateral(cId, bystander),
            lender2Shares: morpho.supplyShares(cId, LENDER2)
        });

        vm.prank(LENDER);
        (uint256 collateralSeized, uint256 debtCanceled) =
            ILidoBlue(address(morpho)).deleverage(cParams, c.sliceShares, borrower, LENDER, LENDER);

        // Drift sentinel: the contract still computes what the mirror predicts.
        assertEq(collateralSeized, c.collateralSeized, "dlv: return collateralSeized");
        assertEq(debtCanceled, c.debtCanceled, "dlv: return debtCanceled");

        // Exact deltas, measured against the contract's own returned values.
        assertEq(morpho.supplyShares(cId, LENDER), b.lenderSupplyShares - c.sliceShares, "dlv: lender supplyShares");
        assertEq(morpho.totalSupplyShares(cId), b.totalSupplyShares - c.sliceShares, "dlv: totalSupplyShares");
        assertEq(morpho.totalSupplyAssets(cId), b.totalSupplyAssets - debtCanceled, "dlv: totalSupplyAssets");
        assertEq(morpho.borrowShares(cId, borrower), b.borrowerBorrowShares - c.burn, "dlv: borrower borrowShares");
        assertEq(morpho.totalBorrowShares(cId), b.totalBorrowShares - c.burn, "dlv: totalBorrowShares");
        assertEq(morpho.totalBorrowAssets(cId), b.totalBorrowAssets - debtCanceled, "dlv: totalBorrowAssets");
        assertEq(morpho.collateral(cId, borrower), b.collateral - collateralSeized, "dlv: collateral");
        assertEq(
            collateralToken.balanceOf(LENDER),
            b.receiverCollateralBalance + collateralSeized,
            "dlv: receiver collateral"
        );

        // The bystander borrower is untouched.
        assertEq(morpho.borrowShares(cId, bystander), b.bystanderBorrowShares, "dlv: bystander borrowShares");
        assertEq(morpho.collateral(cId, bystander), b.bystanderCollateral, "dlv: bystander collateral");

        // The bystander lender is untouched: its shares are unchanged and its claim is not diluted by the cut.
        assertEq(morpho.supplyShares(cId, LENDER2), b.lender2Shares, "dlv: bystander lender shares");
        uint256 l2Before = b.lender2Shares.toAssetsDown(b.totalSupplyAssets, b.totalSupplyShares);
        uint256 l2After = b.lender2Shares.toAssetsDown(morpho.totalSupplyAssets(cId), morpho.totalSupplyShares(cId));
        assertGe(l2After, l2Before, "dlv: bystander lender claim");

        // Value conservation: the lender seizes collateral worth no more than the debt it cancels, and not
        // meaningfully less. Derived from "deleverage is a 1:1 value swap", independent of the seize formula.
        uint256 seizedValue = collateralSeized.mulDivDown(price, ORACLE_PRICE_SCALE);
        assertLe(seizedValue, debtCanceled, "dlv: value extraction");
        assertLe(debtCanceled - seizedValue, price / ORACLE_PRICE_SCALE + 1, "dlv: value tightness");
    }

    // Mirrors every core pre-hook check and the controller's solvency check, so callers know whether a cut
    // succeeds and whether the controller would reject it. Reads are taken after `accrueInterest` so they
    // match the totals the core uses in the same block.
    function _findCut(address borrower, uint256 sliceSeed) internal view returns (Cut memory c) {
        uint256 lenderShares = morpho.supplyShares(cId, LENDER);
        uint256 borrowerShares = morpho.borrowShares(cId, borrower);
        if (lenderShares == 0 || borrowerShares == 0) return c;

        uint256 tSA = morpho.totalSupplyAssets(cId);
        uint256 tSS = morpho.totalSupplyShares(cId);
        uint256 tBA = morpho.totalBorrowAssets(cId);
        uint256 tBS = morpho.totalBorrowShares(cId);

        c.sliceShares = bound(sliceSeed, 1, lenderShares);
        c.debtCanceled = c.sliceShares.toAssetsDown(tSA, tSS);
        if (c.debtCanceled <= (tSA > tBA ? tSA - tBA : 0)) return c; // liquidity gate

        uint256 price = cOracle.price();
        uint256 collateral = morpho.collateral(cId, borrower);
        c.collateralSeized = c.debtCanceled.mulDivDown(ORACLE_PRICE_SCALE, price);
        if (c.collateralSeized == 0 || c.collateralSeized > collateral) return c;

        c.burn = c.debtCanceled.toSharesUp(tBA, tBS);
        if (c.burn > borrowerShares) return c;

        // Replicate EnforcingControllerMock.on exactly (same reads, same rounding).
        uint256 debt = borrowerShares.toAssetsUp(tBA, tBS);
        uint256 postCollateralValue = (collateral - c.collateralSeized).mulDivDown(price, ORACLE_PRICE_SCALE);
        uint256 postDebt = debt > c.debtCanceled ? debt - c.debtCanceled : 0;
        c.insolvent = postCollateralValue < postDebt;

        c.ok = true;
    }
}
