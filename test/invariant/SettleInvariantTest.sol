// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../InvariantTest.sol";

import {ILidoLend} from "../../src/interfaces/ILidoLend.sol";
import {EnforcingControllerMock} from "../../src/mocks/EnforcingControllerMock.sol";
import {OracleMock} from "../../src/mocks/OracleMock.sol";

// Invariant suite for `settle` on one controller-bound market with two borrowers. The market is kept
// near zero free liquidity (LENDER supplies, a borrower borrows the same). `warp` lets interest compound
// the share/asset rate far from 1:1, and `setControllerPrice` swings health so a borrower can go underwater.
// This suite's controller rejects cuts that would leave the borrower insolvent. `settleNoRevert` asserts
// the exact post-state of every successful cut against the contract's *returned* values plus an independent
// collateral-value-conservation bound, so it catches a wrong formula and not just a regressed one. Deterministic
// tests cover the branches fuzzing reaches rarely: a hook rejecting an insolvent cut and a successful cut
// independent of free liquidity.
//
// Out of scope (covered elsewhere): caller != onBehalf authorization (integration tests).
contract SettleInvariantTest is InvariantTest {
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

    // Audit FZ-02: loan tokens the core keeps above the accounting idle because a settle's `debtCanceled`
    // exceeded the pre-cut borrow total and the core floored that total at zero. Computed from the
    // pre-state and the returned value, never from the measured balance.
    uint256 internal settleZeroFloorExcess;
    uint256 internal auditSettleCuts;

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
        selectors.push(this.settleNoRevert.selector);
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
        ILidoLend(address(morpho)).createMarket(cParams, address(cController), true);
        morpho.setFee(cParams, MARKET_FEE);
        vm.stopPrank();

        CB = makeAddr("ControllerBorrower");
        CB2 = makeAddr("ControllerBorrower2");
        // A price drop can push a borrower underwater. Debt (capped to MAX_TEST_AMOUNT in topUp) keeps
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
        (uint256 collateralSeized, uint256 debtCanceled, uint256 sharesCanceled, uint256 sharesBurned) =
            ILidoLend(address(morpho)).settle(cParams, c.burn, LENDER, borrower, LENDER);

        // Drift sentinel: the contract still computes what the mirror predicts.
        assertEq(collateralSeized, c.collateralSeized, "dlv: return collateralSeized");
        assertEq(debtCanceled, c.debtCanceled, "dlv: return debtCanceled");
        assertEq(sharesCanceled, c.burn, "dlv: return borrowSharesCanceled");
        assertEq(sharesBurned, c.sliceShares, "dlv: return supplySharesBurned");
        assertLe(sharesBurned, b.lenderSupplyShares, "dlv: burn within lender ownership");

        // Audit FZ-02 ghost: the part of `debtCanceled` above the pre-cut borrow total leaves supply only.
        settleZeroFloorExcess += UtilsLib.zeroFloorSub(debtCanceled, b.totalBorrowAssets);
        ++auditSettleCuts;

        // Exact deltas, measured against the contract's own returned values.
        assertEq(morpho.supplyShares(cId, LENDER), b.lenderSupplyShares - sharesBurned, "dlv: lender supplyShares");
        assertEq(morpho.totalSupplyShares(cId), b.totalSupplyShares - sharesBurned, "dlv: totalSupplyShares");
        assertEq(morpho.totalSupplyAssets(cId), b.totalSupplyAssets - debtCanceled, "dlv: totalSupplyAssets");
        assertEq(morpho.borrowShares(cId, borrower), b.borrowerBorrowShares - c.burn, "dlv: borrower borrowShares");
        assertEq(morpho.totalBorrowShares(cId), b.totalBorrowShares - c.burn, "dlv: totalBorrowShares");
        // `debtCanceled` may exceed the pre-cut total by 1, which the core floors at zero.
        assertEq(
            morpho.totalBorrowAssets(cId),
            UtilsLib.zeroFloorSub(b.totalBorrowAssets, debtCanceled),
            "dlv: totalBorrowAssets"
        );
        assertEq(morpho.collateral(cId, borrower), b.collateral - collateralSeized, "dlv: collateral");
        assertEq(
            collateralToken.balanceOf(LENDER),
            b.receiverCollateralBalance + collateralSeized,
            "dlv: receiver collateral"
        );

        // The bystander borrower is untouched.
        assertEq(morpho.borrowShares(cId, bystander), b.bystanderBorrowShares, "dlv: bystander borrowShares");
        assertEq(morpho.collateral(cId, bystander), b.bystanderCollateral, "dlv: bystander collateral");

        // The bystander lender's shares are untouched by the cut.
        assertEq(morpho.supplyShares(cId, LENDER2), b.lender2Shares, "dlv: bystander lender shares");

        // Value conservation: the seized collateral is worth the canceled debt up to two rounding steps. The
        // debt removal rounds the cut UP while the seizure prices it DOWN, which is one asset unit of slack
        // absorbed by the settling lender, and the price conversion adds its own step on top. Derived from
        // "settlement is a value swap net of the rounding the initiator eats", independent of the seize
        // formula (whose exact output is already pinned by the drift sentinel above).
        uint256 seizedValue = collateralSeized.mulDivDown(price, ORACLE_PRICE_SCALE);
        assertLe(seizedValue, debtCanceled, "dlv: seized value never exceeds the canceled debt");
        assertApproxEqAbs(seizedValue, debtCanceled, price / ORACLE_PRICE_SCALE + 2, "dlv: value conservation");

        // Requirement bounds, not formula pins: the sentinel above is updated whenever the formula is, while
        // these fail when a new formula hands the caller a profit. Each side is valued against the claim.
        assertLe(
            collateralSeized.mulDivUp(price, ORACLE_PRICE_SCALE),
            c.burn.toAssetsDown(b.totalBorrowAssets, b.totalBorrowShares),
            "dlv: payout never exceeds the down-rounded cut, even valued against the market"
        );
        assertGe(
            sharesBurned.toAssetsDown(b.totalSupplyAssets, b.totalSupplyShares),
            debtCanceled,
            "dlv: burned supply is worth at least the canceled debt"
        );
        _assertBorrowerValueExchange(borrower, bystander, b, collateralSeized, price);
        _assertBurnAndBystanderLender(b, sharesBurned, debtCanceled);
    }

    // Audit FZ-22. Upper bound on the burn: `sliceShares = toSharesUp(debtCanceled)`, so the burned shares are
    // worth at most the canceled debt plus one pre-cut share's value, rounded up. Bystander lender: LENDER2's
    // shares are untouched, so its value tracks the supply rate, which a cut must not lower (cross-multiplied
    // with the virtual offsets, no tolerance).
    function _assertBurnAndBystanderLender(Bal memory b, uint256 sharesBurned, uint256 debtCanceled) internal {
        uint256 preShareValueUp = uint256(1).mulDivUp(
            b.totalSupplyAssets + SharesMathLib.VIRTUAL_ASSETS, b.totalSupplyShares + SharesMathLib.VIRTUAL_SHARES
        );
        assertLe(
            sharesBurned.toAssetsDown(b.totalSupplyAssets, b.totalSupplyShares),
            debtCanceled + preShareValueUp,
            "FZ-22: burned supply value <= debtCanceled + ceil(pre share price)"
        );

        uint256 tSA = morpho.totalSupplyAssets(cId);
        uint256 tSS = morpho.totalSupplyShares(cId);
        assertGe(
            (tSA + SharesMathLib.VIRTUAL_ASSETS) * (b.totalSupplyShares + SharesMathLib.VIRTUAL_SHARES),
            (b.totalSupplyAssets + SharesMathLib.VIRTUAL_ASSETS) * (tSS + SharesMathLib.VIRTUAL_SHARES),
            "FZ-22: supply share rate never falls across a cut"
        );
        assertGe(
            b.lender2Shares.toAssetsDown(tSA, tSS),
            b.lender2Shares.toAssetsDown(b.totalSupplyAssets, b.totalSupplyShares),
            "FZ-22: bystander lender value never falls across a cut"
        );
    }

    // `debtCanceled` leaves the market as a whole, so only part of it lands on the target's own position and
    // the bounds above cannot see a cut that overcharges it. Both valuations round the same way, which keeps
    // the difference non-negative.
    function _assertBorrowerValueExchange(
        address borrower,
        address bystander,
        Bal memory b,
        uint256 collateralSeized,
        uint256 price
    ) internal {
        uint256 tBA = morpho.totalBorrowAssets(cId);
        uint256 tBS = morpho.totalBorrowShares(cId);

        uint256 targetBefore = b.borrowerBorrowShares.toAssetsDown(b.totalBorrowAssets, b.totalBorrowShares);
        uint256 targetAfter = morpho.borrowShares(cId, borrower).toAssetsDown(tBA, tBS);
        assertLe(
            collateralSeized.mulDivUp(price, ORACLE_PRICE_SCALE),
            targetBefore - targetAfter,
            "dlv: target pays no more collateral value than the debt relief it receives"
        );

        uint256 bystanderBefore = b.bystanderBorrowShares.toAssetsDown(b.totalBorrowAssets, b.totalBorrowShares);
        uint256 bystanderAfter = morpho.borrowShares(cId, bystander).toAssetsDown(tBA, tBS);
        assertLe(bystanderAfter, bystanderBefore, "dlv: untouched borrower never owes more");
    }

    // Mirrors every core pre-hook check and the controller's solvency check for an exact borrow-share cut.
    // Reads are taken after `accrueInterest` so they match the totals the core uses in the same block.
    function _findCut(address borrower, uint256 sliceSeed) internal view returns (Cut memory c) {
        uint256 lenderShares = morpho.supplyShares(cId, LENDER);
        uint256 borrowerShares = morpho.borrowShares(cId, borrower);
        if (lenderShares == 0 || borrowerShares == 0) return c;

        uint256 tSA = morpho.totalSupplyAssets(cId);
        uint256 tSS = morpho.totalSupplyShares(cId);
        uint256 tBA = morpho.totalBorrowAssets(cId);
        uint256 tBS = morpho.totalBorrowShares(cId);

        c.burn = bound(sliceSeed, 1, borrowerShares);
        c.debtCanceled = c.burn.toAssetsUp(tBA, tBS);
        c.sliceShares = c.debtCanceled.toSharesUp(tSA, tSS);
        if (c.sliceShares > lenderShares) return c;

        uint256 price = cOracle.price();
        uint256 collateral = morpho.collateral(cId, borrower);
        // The core prices the seizure off the cut's rounded-DOWN asset value, while the debt removal rounds it
        // up, so a cut worth less than one asset unit seizes nothing and the core rejects it.
        c.collateralSeized = c.burn.toAssetsDown(tBA, tBS).mulDivDown(ORACLE_PRICE_SCALE, price);
        if (c.collateralSeized == 0 || c.collateralSeized > collateral) return c;

        // Replicate EnforcingControllerMock.on exactly (same reads, same rounding, same zero floor).
        uint256 postDebt =
            (borrowerShares - c.burn).toAssetsUp(UtilsLib.zeroFloorSub(tBA, c.debtCanceled), tBS - c.burn);
        uint256 postCollateralValue = (collateral - c.collateralSeized).mulDivDown(price, ORACLE_PRICE_SCALE);
        c.insolvent = postCollateralValue < postDebt;

        c.ok = true;
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

    function settleNoRevert(uint256 borrowerSeed, uint256 sliceSeed) external {
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
    function testSettleHappyPath() public {
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
    function testControllerBlocksInsolventCut() public {
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
        vm.expectRevert(bytes("borrower would be insolvent"));
        ILidoLend(address(morpho)).settle(cParams, c.burn, LENDER, CB, LENDER);
    }

    // This solvent cut exceeds the lender's supply beyond free liquidity, but succeeds when the hook returns
    // because the shares being burned are owned.
    function testSettleBeyondFreeLiquidity(uint256 fracSeed) public {
        uint256 borrowAmount = MAX_TEST_AMOUNT / 8;
        loanToken.setBalance(LENDER, 2 * borrowAmount);
        vm.prank(LENDER);
        morpho.supply(cParams, 2 * borrowAmount, 0, LENDER, hex"");
        vm.prank(CB);
        morpho.borrow(cParams, borrowAmount, 0, CB, CB);

        uint256 sliceShares = morpho.supplyShares(cId, LENDER) * bound(fracSeed, 51, 90) / 100;
        Cut memory c = _findCut(CB, sliceShares);

        uint256 suppliedAssets =
            morpho.supplyShares(cId, LENDER).toAssetsDown(morpho.totalSupplyAssets(cId), morpho.totalSupplyShares(cId));
        uint256 freeLiquidity = morpho.totalSupplyAssets(cId) - morpho.totalBorrowAssets(cId);
        assertGe(suppliedAssets, freeLiquidity, "setup: supply covers free liquidity");
        uint256 supplyBeyondFreeLiquidity = suppliedAssets - freeLiquidity;

        assertTrue(c.ok && !c.insolvent, "setup: expected accepted cut");
        assertGt(c.debtCanceled, supplyBeyondFreeLiquidity, "setup: cut exceeds supply beyond free liquidity");
        _executeAndAssertCut(CB, c);
    }

    // Audit reach test (FZ-02, FZ-22): a successful cut runs the FZ-22 asserts inside `_executeAndAssertCut`,
    // then both aggregate custody invariants are checked on the post-cut state.
    function test_auditReach_settleCustodyAndBystander() public {
        uint256 amount = MAX_TEST_AMOUNT / 4;
        loanToken.setBalance(LENDER, amount);
        vm.prank(LENDER);
        morpho.supply(cParams, amount, 0, LENDER, hex"");
        vm.prank(CB);
        morpho.borrow(cParams, amount, 0, CB, CB);
        _forward(30 days / BLOCK_TIME); // interest and the 10% fee move both share rates off 1:1

        this.settleNoRevert(0, morpho.borrowShares(cId, CB) / 3);

        assertGt(auditSettleCuts, 0, "reach: a cut was executed");
        assertGt(morpho.supplyShares(cId, FEE_RECIPIENT), 0, "reach: fee shares were minted");
        assertGt(morpho.supplyShares(cId, LENDER2), 0, "reach: bystander lender holds shares");
        invariantAggregateLoanCustody();
        invariantAggregateCollateralCustody();
        invariantSupplyShares();
        invariantBorrowShares();
    }

    // Audit reach test (FZ-02 zero floor, F11). CB is the only controller-market borrower (setUp). A one-share
    // repay pulls `toAssetsUp(1) == 1` and moves the borrow total to 1 asset per 1e6 shares minus one share, so a
    // full-debt cut then cancels `toAssetsUp(all shares)` = the pre-repay total, one unit above the stored total.
    // The core floors the total at zero (`LidoLend.sol` settle `zeroFloorSub`) and keeps that unit as loan tokens,
    // which only the `settleZeroFloorExcess` ghost accounts for.
    function test_auditReach_settleZeroFloor() public {
        uint256 amount = MAX_TEST_AMOUNT / 4;
        loanToken.setBalance(LENDER, amount);
        vm.prank(LENDER);
        morpho.supply(cParams, amount, 0, LENDER, hex"");

        assertEq(morpho.borrowShares(cId, CB2), 0, "setup: CB is the only controller-market borrower");
        loanToken.setBalance(CB, 1);
        vm.prank(CB);
        morpho.repay(cParams, 0, 1, CB, hex"");

        uint256 shares = morpho.borrowShares(cId, CB);
        assertEq(shares, morpho.totalBorrowShares(cId), "setup: CB holds every borrow share");
        this.settleNoRevert(0, shares);

        assertGt(auditSettleCuts, 0, "reach: a full-debt cut was executed");
        assertEq(morpho.borrowShares(cId, CB), 0, "reach: CB fully settled");
        assertEq(morpho.totalBorrowAssets(cId), 0, "reach: borrow total floored at zero");
        assertGt(settleZeroFloorExcess, 0, "reach FZ-02: settle zero-floor excess");
        invariantAggregateLoanCustody();
        invariantAggregateCollateralCustody();
        invariantSupplyShares();
        invariantBorrowShares();
    }

    /* INVARIANTS */

    // Audit FZ-02 (loan side). The core holds exactly the accounting idle of both markets on these shared
    // tokens, plus what settle zero floors left behind. `topUpControllerMarket` supplies and borrows the same
    // amount, accrual moves both totals equally, and settle moves no loan token.
    function invariantAggregateLoanCustody() public {
        uint256 idle = morpho.totalSupplyAssets(cId) - morpho.totalBorrowAssets(cId) + morpho.totalSupplyAssets(id)
            - morpho.totalBorrowAssets(id);
        assertEq(loanToken.balanceOf(address(morpho)), idle + settleZeroFloorExcess, "FZ-02: loan custody");
    }

    // Audit FZ-02 (collateral side). Every collateral token the core holds is recorded on a position in one of
    // the two markets; settle sends the seized part to the receiver.
    function invariantAggregateCollateralCustody() public {
        uint256 sum = morpho.collateral(cId, CB) + morpho.collateral(cId, CB2) + morpho.collateral(cId, LENDER)
            + morpho.collateral(cId, LENDER2) + morpho.collateral(id, CB) + morpho.collateral(id, CB2)
            + morpho.collateral(id, LENDER) + morpho.collateral(id, LENDER2);
        assertEq(collateralToken.balanceOf(address(morpho)), sum, "FZ-02: collateral custody");
    }

    function afterInvariant() public {
        emit log_named_uint("auditSettleCuts", auditSettleCuts);
        emit log_named_uint("settleZeroFloorExcess", settleZeroFloorExcess);
    }

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
}
