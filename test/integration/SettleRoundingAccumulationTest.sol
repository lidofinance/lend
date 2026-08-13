// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTestWithController.sol";

/// @dev How much value a `settle` caller can lose to rounding, as a bound fuzzed across the whole oracle
///      price range and across drifted supply/borrow share rates.
///
///      `settle` rounds against the settling side twice, and each loss is one indivisible unit of a
///      DIFFERENT token:
///
///        1. `:467` values the cut UP into `borrowAssetsCanceled`, while `:476` values the SAME shares
///           DOWN as the seizure basis. The lender burns supply for the up valuation and is paid for the
///           down one                                             -> < 1 LOAN wei per call
///        2. `:476-477` converts that basis to collateral with `mulDivDown`
///                                                                -> < 1 COLLATERAL wei per call
///
///      So per call, in loan-asset value:
///
///          canceled - seized * price / SCALE   <   1 loan wei  +  1 collateral wei
///
///      which, kept scaled by `ORACLE_PRICE_SCALE` to stay exact in integers, is
///
///          canceled * SCALE - seized * price   <   SCALE + price
///
///      The bound has no magic constant and no price dependence: it is one unit of each side, whatever
///      those units happen to be worth. In collateral wei it reads `SCALE / price + 1`, which is why a
///      "one wei" rounding can still be trillions of collateral wei when collateral is cheap per unit.
///
///      SCOPE: this is the cost of a settle that seizes collateral. A closing cut that seizes nothing costs
///      its caller the whole canceled amount, by choice and not by rounding, so it is not bounded here and
///      `_affordableCut` leaves those cuts out. They are covered by `SettleDustHoldingTest`.
contract SettleRoundingAccumulationTest is BaseTestWithController {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    uint256 internal constant MAX_CALLS = 20;
    /// @dev Collateral is fixed and the debt is sized against it, so a meaningful cut stays affordable at
    ///      every price. Comfortably inside uint128, and inside `seized * price` at the top of the range.
    uint256 internal constant COLLATERAL = 1e33;

    address internal LENDER;

    struct Ctx {
        MarketParams params;
        Id mid;
        uint256 price;
        uint256 executed;
        uint256 totalLossScaled;
        uint256 worstCallScaled;
    }

    /* WORKED CASE: WETH (18 decimals, $2500) collateral against a GUSD (2 decimals, $1) loan. */

    uint256 internal constant W_PRICE = 2.5e23; // 1 wei ETH == 2.5e-13 GUSD units
    uint256 internal constant W_WEI_PER_UNIT = ORACLE_PRICE_SCALE / W_PRICE; // 4e12
    uint256 internal constant W_CALLS = 50;
    /// @dev Offset by half a share unit so the two valuations differ on every call; the 50-call total is
    ///      an exact multiple of `VIRTUAL_SHARES`, so the single call escapes the gap.
    uint256 internal constant W_CUT = 10_000 * SharesMathLib.VIRTUAL_SHARES + SharesMathLib.VIRTUAL_SHARES / 2;

    struct RunOut {
        uint256 canceled;
        uint256 seized;
        uint256 gap;
    }

    function setUp() public override {
        super.setUp();
        LENDER = makeAddr("Lender");
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev The per-call ceiling, in loanWei*SCALE: one loan wei plus one collateral wei.
    function _boundScaled(uint256 price) internal pure returns (uint256) {
        return ORACLE_PRICE_SCALE + price;
    }

    /// @dev A controller-bound market whose supply and borrow share rates are both driven off 1:1 by a
    ///      fuzzed fee and a fuzzed amount of accrual. The fee is what makes the two rates diverge: it
    ///      mints supply shares to the fee recipient without touching the borrow side.
    function _driftedMarket(uint256 feeSeed, uint256 driftSeed, uint256 elapsedSeed, uint256 borrowed)
        internal
        returns (MarketParams memory p, Id mid)
    {
        p = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.75 ether // distinct from DEFAULT_TEST_LLTV, so this is a fresh market id
        });
        mid = p.id();
        address ctrl = address(new ControllerMock(mid)); // created first: `new` would consume the prank
        vm.prank(OWNER);
        _lido().createMarket(p, ctrl, true);

        // A fresh market already has fee 0, and `setFee` rejects a no-op write; skipping the call keeps
        // the zero-fee case inside the fuzz space rather than reverting on it.
        uint256 fee = bound(feeSeed, 0, MAX_FEE);
        if (fee != 0) {
            vm.prank(OWNER);
            morpho.setFee(p, fee);
        }

        // Sole lender, sole borrower, zero free liquidity.
        _supplyAs(p, LENDER, borrowed);
        _borrowAs(p, BORROWER, COLLATERAL, borrowed);

        // Whole-year rounds push the indices far from 1:1 (a borrow share can end up worth more than one
        // asset unit); the sub-year warp lands them on non-round values in between.
        uint256 rounds = bound(driftSeed, 0, 12);
        for (uint256 i; i < rounds; ++i) {
            vm.warp(block.timestamp + 365 days);
            morpho.accrueInterest(p);
        }
        vm.warp(block.timestamp + bound(elapsedSeed, 1, 365 days));
        morpho.accrueInterest(p);
    }

    /// @dev Largest cut that clears every core guard right now, or 0 if none does.
    function _affordableCut(Ctx memory c, uint256 seed) internal view returns (uint256) {
        uint256 tBA = morpho.totalBorrowAssets(c.mid);
        uint256 tBS = morpho.totalBorrowShares(c.mid);
        uint256 tSA = morpho.totalSupplyAssets(c.mid);
        uint256 tSS = morpho.totalSupplyShares(c.mid);

        uint256 borrowerShares = morpho.borrowShares(c.mid, BORROWER);
        uint256 lenderShares = morpho.supplyShares(c.mid, LENDER);
        if (borrowerShares == 0 || lenderShares == 0) return 0;

        // Debt the collateral can pay for, and debt the lender's own supply can cover.
        uint256 maxDebt = _min(
            morpho.collateral(c.mid, BORROWER).mulDivDown(c.price, ORACLE_PRICE_SCALE),
            lenderShares.toAssetsDown(tSA, tSS)
        );
        uint256 maxCut = _min(maxDebt.toSharesDown(tBA, tBS), borrowerShares);
        if (maxCut == 0) return 0;

        uint256 cut = bound(seed, 1, maxCut);

        // Re-check the guards on the chosen cut, exactly as the core computes them.
        uint256 canceled = cut.toAssetsUp(tBA, tBS);
        if (canceled.toSharesUp(tSA, tSS) > lenderShares) return 0;
        // A zero seizure is left out on purpose: such a cut is a close, and its cost is a choice rather than
        // a rounding, so it belongs to SettleDustHoldingTest instead.
        uint256 seized = cut.toAssetsDown(tBA, tBS).mulDivDown(ORACLE_PRICE_SCALE, c.price);
        if (seized == 0 || seized > morpho.collateral(c.mid, BORROWER)) return 0;

        return cut;
    }

    /// @dev THE INVARIANT. Across the full oracle price range, a fuzzed fee, fuzzed accrual (so both the
    ///      supply and the borrow share rate sit at fuzzed non-round values), fuzzed debt size and fuzzed
    ///      cut sizes: no `settle` that seizes collateral costs its caller more than one loan wei plus one
    ///      collateral wei, and N of them cost at most N of those. See SCOPE above for the closing cuts
    ///      that seize nothing.
    function testLenderLossPerCallBoundedFuzz(
        uint256 priceSeed,
        uint256 feeSeed,
        uint256 driftSeed,
        uint256 elapsedSeed,
        uint256 cutSeed,
        uint256 callsSeed
    ) public {
        Ctx memory c;
        c.price = bound(priceSeed, MIN_COLLATERAL_PRICE, MAX_COLLATERAL_PRICE);
        oracle.setPrice(c.price);

        // Size the debt against what the collateral is worth at this price, so cuts stay affordable at
        // both ends of the range. The 1/4 leaves room to seize the whole debt and keeps the position
        // healthy at borrow time.
        uint256 borrowed = _min(COLLATERAL.mulDivDown(c.price, ORACLE_PRICE_SCALE) / 4, 1e24);
        vm.assume(borrowed >= MIN_TEST_AMOUNT);

        (c.params, c.mid) = _driftedMarket(feeSeed, driftSeed, elapsedSeed, borrowed);

        // Both rates are off 1:1, which is what makes the two valuations of a cut diverge.
        uint256 calls = bound(callsSeed, 1, MAX_CALLS);

        for (uint256 i; i < calls; ++i) {
            uint256 cut = _affordableCut(c, uint256(keccak256(abi.encode(cutSeed, i))));
            if (cut == 0) continue;

            vm.prank(LENDER);
            (uint256 seized, uint256 canceled,,) = _lido().settle(c.params, cut, LENDER, BORROWER, LENDER);

            // What this call cost: supply value surrendered, minus the value of the collateral collected.
            uint256 lossScaled = canceled * ORACLE_PRICE_SCALE - seized * c.price;
            assertLt(lossScaled, _boundScaled(c.price), "per call: < 1 loan wei + 1 collateral wei");

            if (lossScaled > c.worstCallScaled) c.worstCallScaled = lossScaled;
            c.totalLossScaled += lossScaled;
            c.executed++;
        }

        vm.assume(c.executed > 0); // a run where no cut cleared the guards proves nothing

        // N calls pay it at most N times: the loss accumulates linearly, it does not compound.
        assertLt(c.totalLossScaled, c.executed * _boundScaled(c.price), "cumulative: < N of the same unit");

        // The same statement in the unit the lender is actually paid in.
        assertLe(c.worstCallScaled / c.price, ORACLE_PRICE_SCALE / c.price + 1, "per call, in collateral wei");
    }

    /// @dev A worked instance of the bound, on a real pair: WETH (18 decimals, $2500) collateral against a
    ///      GUSD (2 decimals, $1) loan, where `SCALE / price` is the exact integer 4e12. One loan wei of
    ///      basis is therefore 4,000,000,000,000 wei of ETH — worth a full US cent — and the price
    ///      conversion truncates nothing, isolating term 1 completely.
    ///
    ///      50 misaligned calls pay it 50 times; one aligned call escapes it entirely. This also keeps the
    ///      fuzz test above honest: it pins a loss that is NONZERO, so the bound cannot pass vacuously.
    function testWorkedCaseOneLoanWeiIsFourTrillionCollateralWei() public {
        (MarketParams memory p, Id mid) = _workedMarket();

        uint256 snapshot = vm.snapshot();
        RunOut memory frag = _run(p, mid, W_CUT, W_CALLS);

        assertTrue(vm.revertTo(snapshot), "state rewound");
        RunOut memory one = _run(p, mid, W_CUT * W_CALLS, 1);

        // The basis gap is charged on every fragmented call and not at all on the aligned single call.
        assertEq(frag.gap, W_CALLS, "one loan wei of basis per call");
        assertEq(one.gap, 0, "aligned cut escapes the basis gap entirely");

        // THE POINT: 50 loan wei is 50 * 4e12 == 2e14 wei of ETH the lender was never paid.
        uint256 shortfall = (frag.canceled * ORACLE_PRICE_SCALE - frag.seized * W_PRICE) / W_PRICE;
        assertEq(shortfall, W_CALLS * W_WEI_PER_UNIT, "basis gap scaled into collateral");
        assertEq(shortfall, 2e14, "0.0002 ETH == 50 cents");
        assertEq(one.canceled * ORACLE_PRICE_SCALE - one.seized * W_PRICE, 0, "the single call is short nothing");
    }

    function _workedMarket() internal returns (MarketParams memory p, Id mid) {
        p = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(0), // driftless: only the settle roundings move the indices
            lltv: 0.76 ether
        });
        mid = p.id();
        address ctrl = address(new ControllerMock(mid));
        vm.prank(OWNER);
        _lido().createMarket(p, ctrl, true);
        oracle.setPrice(W_PRICE);

        vm.label(address(collateralToken), "WETH");
        vm.label(address(loanToken), "GUSD");
        _supplyAs(p, LENDER, 600_000); // $6,000 of GUSD
        _borrowAs(p, BORROWER, 10e18, 600_000); // 10 ETH of collateral
    }

    function _run(MarketParams memory p, Id mid, uint256 cutShares, uint256 calls)
        internal
        returns (RunOut memory out)
    {
        for (uint256 i; i < calls; ++i) {
            uint256 tBA = morpho.totalBorrowAssets(mid);
            uint256 tBS = morpho.totalBorrowShares(mid);
            out.gap += cutShares.toAssetsUp(tBA, tBS) - cutShares.toAssetsDown(tBA, tBS);

            vm.prank(LENDER);
            (uint256 seized, uint256 canceled,,) = _lido().settle(p, cutShares, LENDER, BORROWER, LENDER);

            // The worked case must obey the same bound the fuzz test asserts.
            assertLt(canceled * ORACLE_PRICE_SCALE - seized * W_PRICE, _boundScaled(W_PRICE), "within the bound");

            out.canceled += canceled;
            out.seized += seized;
        }
    }
}
