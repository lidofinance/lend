// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTestWithController.sol";

import {ILidoLend} from "../../src/interfaces/ILidoLend.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";

/// @dev Tests that verify the arithmetic correctness of `settle`: conversion formulas, rounding
///      directions, gate/cap boundaries, and share-price invariants after interest accrual.
///      Access control, hook payloads, events, and position-lifecycle tests live in SettleIntegrationTest.
contract SettleMathTest is BaseTestWithController {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    // Kept in memory to avoid stack-too-deep under the no-via-ir profile.
    struct Vars {
        uint256 freeLiquidity;
        uint256 debtCanceled;
        uint256 sliceShares;
        uint256 totalSupplyAssets;
        uint256 totalSupplyShares;
        uint256 totalBorrowAssets;
        uint256 totalBorrowShares;
        uint256 collateralSeized;
        uint256 borrowSharesToBurn;
        uint256 lenderShares;
        uint256 borrowSharesBefore;
        uint256 morphoCollateralBefore;
        uint256 morphoLoanBefore;
        uint256 actualSeized;
        uint256 actualCanceled;
    }

    function _lido() internal view returns (ILidoLend) {
        return ILidoLend(address(morpho));
    }

    /// @dev Collateral seized for cancelling `debtAssets` at the current price (matches the core's mulDivDown).
    function _seizedFor(uint256 debtAssets) internal view returns (uint256) {
        return debtAssets.mulDivDown(ORACLE_PRICE_SCALE, oracle.price());
    }

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

    /// @dev Fresh controlled market with a non-1:1 share:asset rate. Supply == borrow == 40e18 (zero free
    ///      liquidity), ample collateral, then warped `elapsedSeed` (<= 365 days) and accrued. Resets price
    ///      to 1:1 so only share rounding is in play. Pass an `lltv` distinct from the setUp market so the
    ///      id is fresh.
    function _openMarketWithAccruedInterest(uint256 lltv, uint256 elapsedSeed)
        internal
        returns (MarketParams memory params, Id marketId)
    {
        params = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: lltv
        });
        marketId = params.id();
        ControllerMock ctrl = new ControllerMock(marketId);
        vm.prank(OWNER);
        _lido().createMarket(params, address(ctrl), true);

        oracle.setPrice(ORACLE_PRICE_SCALE);

        loanToken.setBalance(address(this), 40e18);
        morpho.supply(params, 40e18, 0, address(this), hex"");
        collateralToken.setBalance(BORROWER, 1000e18);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(params, 1000e18, BORROWER, hex"");
        morpho.borrow(params, 40e18, 0, BORROWER, BORROWER);
        vm.stopPrank();

        vm.warp(block.timestamp + bound(elapsedSeed, 1, 365 days));
        morpho.accrueInterest(params);
        assertGt(
            morpho.totalSupplyAssets(marketId),
            morpho.totalSupplyShares(marketId) / SharesMathLib.VIRTUAL_SHARES,
            "no accrued interest"
        );
    }

    // The settleable supply is the cut's tight bound: settling exactly it passes, one wei more reverts. In this
    // single-borrower fixture settleable equals the borrower's debt, so the extra wei is caught by the debt cap
    // (EXCEEDS_DEBT); the liquidity gate's own boundary is exercised in the invariant suite.
    function testSettleLiquidityGateBoundary(uint256 priceSeed) public {
        _setFuzzedPrice(priceSeed);
        _openPosition(100e18, 100e18, 70e18);
        uint256 freeLiquidity = morpho.totalSupplyAssets(id) - morpho.totalBorrowAssets(id);
        assertEq(freeLiquidity, 30e18, "free liquidity");
        // Single supplier: settleable supply = own supply (100) − free liquidity (30) = the borrowed 70.
        uint256 settleableSupply = 100e18 - freeLiquidity;
        assertEq(settleableSupply, 70e18, "settleable supply");

        // Under the two-anchor API this supply slice cancels 70e18 + 1 of debt, whose borrowSharesToBurn
        // (70e18*VS + 1e6) exceeds BORROWER's 70e18*VS holding, so the debt cap fires before the liquidity
        // gate (new check order: EXCEEDS_DEBT precedes LIQUIDITY_AVAILABLE).
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_DEBT));
        _lido()
            .settle(
                marketParams,
                (settleableSupply + 1) * SharesMathLib.VIRTUAL_SHARES,
                0,
                address(this),
                BORROWER,
                RECEIVER
            );

        uint256 lenderSharesBefore = morpho.supplyShares(id, address(this));
        uint256 sliceShares = settleableSupply * SharesMathLib.VIRTUAL_SHARES;
        (uint256 seizedAssets,) = _lido().settle(marketParams, sliceShares, 0, address(this), BORROWER, RECEIVER);
        assertEq(seizedAssets, _seizedFor(settleableSupply), "seized the cancelled debt's worth of collateral");
        assertEq(morpho.supplyShares(id, address(this)), lenderSharesBefore - sliceShares, "lender shares reduced");
    }

    // To cancel a target asset amount of debt, pass the equivalent supply shares. The supply index is
    // 1:1 here, so `toAssetsDown(toSharesUp(40e18)) == 40e18` exactly and debtCanceled lands on the
    // asset amount.
    function testSettleToTargetAssetAmount(uint256 priceSeed) public {
        _setFuzzedPrice(priceSeed);
        _openPosition(100e18, 100e18, 70e18); // free liquidity = 30e18
        uint256 settleAssets = 40e18; // > free liquidity, within the borrower's 70e18 debt
        uint256 supplyShares = settleAssets.toSharesUp(morpho.totalSupplyAssets(id), morpho.totalSupplyShares(id));

        (uint256 seizedAssets, uint256 canceledAssets) =
            _lido().settle(marketParams, supplyShares, 0, address(this), BORROWER, RECEIVER);

        assertEq(canceledAssets, settleAssets, "debtCanceled equals the supplyShares' asset value");
        assertEq(seizedAssets, _seizedFor(settleAssets), "seized the cancelled debt's worth of collateral");
    }

    // Each cap has its own error; the revert string pins which check fired.

    // At an extreme price, debtCanceled == 1 → collateralSeized rounds to 0 → rejected before any state write.
    function testSettleOverCapZeroCollateral() public {
        _openPosition(100e18, 200e18, 100e18);
        oracle.setPrice(MAX_COLLATERAL_PRICE);
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_SLICE_TOO_SMALL));
        _lido().settle(marketParams, 1 * SharesMathLib.VIRTUAL_SHARES, 0, address(this), BORROWER, RECEIVER);
    }

    // debtCanceled 60e18 → collateralSeized 120e18 > 100e18 collateral at half price.
    function testSettleOverCapCollateral() public {
        _openPosition(100e18, 100e18, 70e18);
        oracle.setPrice(ORACLE_PRICE_SCALE / 2); // collateral now worth 50e18
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_COLLATERAL));
        _lido().settle(marketParams, 60e18 * SharesMathLib.VIRTUAL_SHARES, 0, address(this), BORROWER, RECEIVER);
    }

    // A second borrower shrinks free liquidity so the lender's settleable supply rises above BORROWER's
    // 70e18 debt, letting the debt cap fire instead of the liquidity gate.
    function testSettleOverCapBorrowShares() public {
        _openPosition(100e18, 100e18, 70e18);
        // After: total borrow 95, free liquidity 5, settleable 95.
        collateralToken.setBalance(ONBEHALF, 100e18);
        vm.startPrank(ONBEHALF);
        morpho.supplyCollateral(marketParams, 100e18, ONBEHALF, hex"");
        morpho.borrow(marketParams, 25e18, 0, ONBEHALF, ONBEHALF);
        vm.stopPrank();

        // debtCanceled 80e18 clears the gate (<= 95) but burns more than BORROWER's 70e18 debt.
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_DEBT));
        _lido().settle(marketParams, 80e18 * SharesMathLib.VIRTUAL_SHARES, 0, address(this), BORROWER, RECEIVER);
    }

    // Full arithmetic verification: pins every delta and both rounding directions across fuzzed prices,
    // collateral amounts, and slice sizes.
    function testSettleSuccessFuzz(
        uint256 collateral,
        uint256 borrowed,
        uint256 price,
        uint256 extraSeed,
        uint256 sliceSeed
    ) public {
        (collateral, borrowed, price) = _boundHealthyPosition(collateral, borrowed, price);
        oracle.setPrice(price);

        Vars memory vars;
        // Fuzz both regimes: free liquidity = freeLiquidity ∈ [0, borrowed-1] < borrowed (cancel window non-empty).
        vars.freeLiquidity = bound(extraSeed, 0, borrowed - 1);
        _openPosition(borrowed + vars.freeLiquidity, collateral, borrowed);
        assertEq(
            morpho.totalSupplyAssets(id) - morpho.totalBorrowAssets(id), vars.freeLiquidity, "free liquidity == extra"
        );

        // debtCanceled ∈ (freeLiquidity, borrowed]: clears the gate, within the borrower's debt and collateral.
        vars.debtCanceled = bound(sliceSeed, vars.freeLiquidity + 1, borrowed);
        vars.sliceShares = vars.debtCanceled * SharesMathLib.VIRTUAL_SHARES;

        vars.totalSupplyAssets = morpho.totalSupplyAssets(id);
        vars.totalSupplyShares = morpho.totalSupplyShares(id);
        vars.totalBorrowAssets = morpho.totalBorrowAssets(id);
        vars.totalBorrowShares = morpho.totalBorrowShares(id);

        assertEq(
            vars.sliceShares.toAssetsDown(vars.totalSupplyAssets, vars.totalSupplyShares),
            vars.debtCanceled,
            "slice maps to debtCanceled"
        );

        vars.collateralSeized = _seizedFor(vars.debtCanceled);
        vars.borrowSharesToBurn = vars.debtCanceled.toSharesUp(vars.totalBorrowAssets, vars.totalBorrowShares);
        vm.assume(vars.collateralSeized > 0); // discards only a tiny slice at extreme price

        vars.morphoCollateralBefore = collateralToken.balanceOf(address(morpho));
        vars.morphoLoanBefore = loanToken.balanceOf(address(morpho));
        vars.lenderShares = morpho.supplyShares(id, address(this));
        vars.borrowSharesBefore = morpho.borrowShares(id, BORROWER);

        (vars.actualSeized, vars.actualCanceled) =
            _lido().settle(marketParams, vars.sliceShares, 0, address(this), BORROWER, RECEIVER);

        // Exact arithmetic (pins rounding direction).
        assertEq(vars.actualCanceled, vars.debtCanceled, "return debtCanceled");
        assertEq(vars.actualSeized, vars.collateralSeized, "return collateralSeized");
        assertEq(morpho.supplyShares(id, address(this)), vars.lenderShares - vars.sliceShares, "lender shares");
        assertEq(morpho.totalSupplyShares(id), vars.totalSupplyShares - vars.sliceShares, "total supply shares");
        assertEq(morpho.totalSupplyAssets(id), vars.totalSupplyAssets - vars.debtCanceled, "total supply assets");
        assertEq(morpho.borrowShares(id, BORROWER), vars.borrowSharesBefore - vars.borrowSharesToBurn, "borrow shares");
        assertEq(morpho.totalBorrowShares(id), vars.totalBorrowShares - vars.borrowSharesToBurn, "total borrow shares");
        assertEq(morpho.totalBorrowAssets(id), vars.totalBorrowAssets - vars.debtCanceled, "total borrow assets");

        // Formula-independent invariants.
        assertEq(
            morpho.totalSupplyAssets(id) - morpho.totalBorrowAssets(id), vars.freeLiquidity, "free liquidity preserved"
        );
        assertEq(collateralToken.balanceOf(RECEIVER), vars.collateralSeized, "receiver got the collateral");
        assertEq(
            collateralToken.balanceOf(address(morpho)),
            vars.morphoCollateralBefore - vars.collateralSeized,
            "morpho collateral"
        );
        assertEq(loanToken.balanceOf(address(morpho)), vars.morphoLoanBefore, "no loan tokens move");
    }

    // settle must realize pending interest itself (it calls _accrueInterest before computing the cut).
    function testSettleAccruesInterest() public {
        (MarketParams memory params, Id marketId) = _openMarketWithAccruedInterest(0.75 ether, 30 days);

        uint256 staleUpdate = morpho.lastUpdate(marketId);
        vm.warp(block.timestamp + 30 days);
        assertEq(morpho.lastUpdate(marketId), staleUpdate, "precondition: interest pending, unrealized");

        _lido()
            .settle(
                params,
                uint256(1e18).toSharesUp(morpho.totalSupplyAssets(marketId), morpho.totalSupplyShares(marketId)),
                0,
                address(this),
                BORROWER,
                RECEIVER
            );

        assertEq(morpho.lastUpdate(marketId), block.timestamp, "settle realized pending interest");
    }

    /// @dev Dumps market totals and both borrowers' debt so each step is visible with `-vv`.
    function _dump(string memory step, Id marketId, address borrower2) internal {
        emit log_string(step);
        emit log_named_uint("  totalSupplyAssets ", morpho.totalSupplyAssets(marketId));
        emit log_named_uint("  totalSupplyShares ", morpho.totalSupplyShares(marketId));
        emit log_named_uint("  totalBorrowAssets ", morpho.totalBorrowAssets(marketId));
        emit log_named_uint("  totalBorrowShares ", morpho.totalBorrowShares(marketId));
        emit log_named_uint("  lender supplyShares", morpho.supplyShares(marketId, address(this)));
        emit log_named_uint("  BORROWER borrowSh ", morpho.borrowShares(marketId, BORROWER));
        emit log_named_uint("  BORROWER debt(ast)", _debtAssets(marketId, BORROWER));
        emit log_named_uint("  borrower2 borrowSh", morpho.borrowShares(marketId, borrower2));
        emit log_named_uint("  borrower2 debt(ast)", _debtAssets(marketId, borrower2));
    }

    /// @dev A borrower's debt valued up to loan assets at the market's current index.
    function _debtAssets(Id marketId, address borrower) internal view returns (uint256) {
        return morpho.borrowShares(marketId, borrower)
            .toAssetsUp(morpho.totalBorrowAssets(marketId), morpho.totalBorrowShares(marketId));
    }

    /// @dev Assets-per-share scaled by 1e18 — a readable "share price" for logs and direction checks.
    function _index(uint256 assets, uint256 shares) internal pure returns (uint256) {
        return shares == 0 ? 0 : (assets * 1e18) / shares;
    }

    /// @dev A controlled 1:1 market driven to a drifted index where a borrower's whole holding can no
    ///      longer be cancelled by its asset value: `toAssetsUp(holding)` converted back overshoots the
    ///      holding. Two borrowers keep the lender's settleable supply above the cut so only the debt-cap
    ///      decides the outcome. Dumps each step so the drifted state is visible with `-vv`.
    function _dustyTwoBorrowerMarket() internal returns (MarketParams memory params, Id marketId, address borrower2) {
        params = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.9 ether
        });
        marketId = params.id();
        ControllerMock ctrl = new ControllerMock(marketId);
        vm.prank(OWNER);
        _lido().createMarket(params, address(ctrl), true);
        oracle.setPrice(ORACLE_PRICE_SCALE); // 1:1, isolate share rounding from the price leg

        borrower2 = makeAddr("Borrower2");

        loanToken.setBalance(address(this), 12);
        morpho.supply(params, 12, 0, address(this), hex"");
        _dump("after lender supplies 12 wei", marketId, borrower2);

        collateralToken.setBalance(BORROWER, 1e18);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(params, 1e18, BORROWER, hex"");
        morpho.borrow(params, 7, 0, BORROWER, BORROWER);
        vm.stopPrank();
        _dump("after BORROWER borrows 7 wei", marketId, borrower2);

        collateralToken.setBalance(borrower2, 1e18);
        vm.startPrank(borrower2);
        collateralToken.approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(params, 1e18, borrower2, hex"");
        morpho.borrow(params, 5, 0, borrower2, borrower2);
        vm.stopPrank();
        _dump("after borrower2 borrows 5 wei", marketId, borrower2);

        vm.warp(block.timestamp + 30 days);
        morpho.accrueInterest(params);
        _dump("after 30 days + accrue (debt drifts up)", marketId, borrower2);

        // Pin the drifted state, so an IRM/timing change fails loudly right here.
        assertEq(morpho.totalBorrowAssets(marketId), 13, "drifted total debt");
        assertEq(morpho.totalBorrowShares(marketId), 12e6, "total borrow shares");
        assertEq(morpho.borrowShares(marketId, BORROWER), 7e6, "BORROWER holds 7e6 shares");
        assertEq(morpho.borrowShares(marketId, borrower2), 5e6, "borrower2 holds 5e6 shares");
    }

    // The borrow-share anchor closes a borrower's whole position even when its asset value cannot. On a
    // drifted index `toAssetsUp(holding)` converts back (UP or DOWN) to more shares than held, so a
    // value-anchored cut reverts SETTLEMENT_EXCEEDS_DEBT; passing the holding as `borrowShares` burns it
    // exactly and zeroes the position.
    function testSettleClosePositionRoundsBurnPastHolding() public {
        (MarketParams memory params, Id marketId, address borrower2) = _dustyTwoBorrowerMarket();

        Vars memory v;
        v.totalBorrowAssets = morpho.totalBorrowAssets(marketId);
        v.totalBorrowShares = morpho.totalBorrowShares(marketId);
        uint256 held = morpho.borrowShares(marketId, BORROWER); // 7e6

        // P1: the holding's asset value, converted back, overshoots the holding in BOTH directions.
        uint256 fullDebt = held.toAssetsUp(v.totalBorrowAssets, v.totalBorrowShares); // 8
        emit log_named_uint("BORROWER fullDebt = toAssetsUp(held)", fullDebt);
        emit log_named_uint("  toSharesUp(fullDebt)  ", fullDebt.toSharesUp(v.totalBorrowAssets, v.totalBorrowShares));
        emit log_named_uint("  toSharesDown(fullDebt)", fullDebt.toSharesDown(v.totalBorrowAssets, v.totalBorrowShares));
        emit log_named_uint("  BORROWER actually holds", held);
        assertEq(fullDebt, 8, "fullDebt valued up");
        assertGt(fullDebt.toSharesUp(v.totalBorrowAssets, v.totalBorrowShares), held, "toSharesUp overshoots holding");
        assertGt(
            fullDebt.toSharesDown(v.totalBorrowAssets, v.totalBorrowShares),
            held,
            "toSharesDown overshoots too (direction irrelevant)"
        );

        // P1b: a value-anchored cut (a supply slice worth fullDebt) reverts on the debt-cap.
        {
            uint256 valueSlice =
                fullDebt.toSharesUp(morpho.totalSupplyAssets(marketId), morpho.totalSupplyShares(marketId));
            emit log_named_uint("value-anchored supply slice", valueSlice);
            vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_DEBT));
            _lido().settle(params, valueSlice, 0, address(this), BORROWER, RECEIVER);
        }

        // P2/P3/P5: the borrow-share anchor closes BORROWER to exactly zero.
        v.totalSupplyAssets = morpho.totalSupplyAssets(marketId);
        v.totalSupplyShares = morpho.totalSupplyShares(marketId);
        v.lenderShares = morpho.supplyShares(marketId, address(this));
        v.borrowSharesBefore = _debtAssets(marketId, borrower2); // borrower2 debt valued up: 6

        (v.actualSeized, v.actualCanceled) = _lido().settle(params, 0, held, address(this), BORROWER, RECEIVER);
        _dump("after closing BORROWER via the borrowShares anchor", marketId, borrower2);
        emit log_named_uint("returned seizedAssets", v.actualSeized);
        emit log_named_uint("returned borrowAssetsCanceled", v.actualCanceled);

        assertEq(morpho.borrowShares(marketId, BORROWER), 0, "BORROWER closed to zero");
        assertEq(v.actualCanceled, fullDebt, "canceled == toAssetsUp(holding)");
        assertEq(v.actualSeized, _seizedFor(fullDebt), "seized == cut at oracle price");
        assertEq(morpho.totalBorrowShares(marketId), v.totalBorrowShares - held, "total borrow shares -= holding");
        assertEq(
            morpho.totalBorrowAssets(marketId),
            v.totalBorrowAssets - v.actualCanceled,
            "total borrow assets -= canceled"
        );
        assertEq(
            v.lenderShares - morpho.supplyShares(marketId, address(this)),
            v.actualCanceled.toSharesUp(v.totalSupplyAssets, v.totalSupplyShares),
            "supply burn derived from the cut"
        );

        // The remaining borrower keeps its shares; its debt drifts 6 -> 5 because the closer absorbed the
        // round-up (paid 8 for a ~7.58 position). borrower2 now owns the whole remaining pool.
        emit log_named_uint("borrower2 debt(ast) before close", v.borrowSharesBefore);
        emit log_named_uint("borrower2 debt(ast) after close", _debtAssets(marketId, borrower2));
        assertEq(morpho.borrowShares(marketId, borrower2), 5e6, "borrower2 shares untouched");
        assertEq(v.borrowSharesBefore, 6, "borrower2 debt before close");
        assertEq(_debtAssets(marketId, borrower2), 5, "borrower2 debt after close (closer ate the round-up)");
        assertEq(
            _debtAssets(marketId, borrower2), morpho.totalBorrowAssets(marketId), "borrower2 owns the remaining pool"
        );

        // --- rounding ledger: who pays, who receives -----------------------------------------
        // Before the cut the borrowers' rounded-up debts overcount the pool by 1 (8 + 6 = 14 > 13). That
        // overlapping wei is exactly what a value-anchored close could never land on.
        assertEq(fullDebt + v.borrowSharesBefore, 14, "rounded-up debts sum to 14");
        assertGt(fullDebt + v.borrowSharesBefore, v.totalBorrowAssets, "...overcounting the 13-wei pool");
        // The closing lender PAYS: burns the full 8 (toSharesUp) for BORROWER's ~7.58-fair holding.
        // borrower2 RECEIVES: 1 wei of relief (6 -> 5). Nothing is minted.
        emit log_named_uint(
            "lender PAID: supply burned (sh)", v.lenderShares - morpho.supplyShares(marketId, address(this))
        );
        emit log_named_uint("lender PAID: assets (canceled) ", v.actualCanceled);
        emit log_named_uint("borrower2 GOT: relief (wei)    ", v.borrowSharesBefore - _debtAssets(marketId, borrower2));
        assertEq(v.borrowSharesBefore - _debtAssets(marketId, borrower2), 1, "borrower2 relieved by 1 wei");

        // --- borrow / supply share price, before vs after (assets-per-share x1e18) ------------
        emit log_named_uint("borrow price before", _index(v.totalBorrowAssets, v.totalBorrowShares));
        emit log_named_uint(
            "borrow price after ", _index(morpho.totalBorrowAssets(marketId), morpho.totalBorrowShares(marketId))
        );
        emit log_named_uint("supply price before", _index(v.totalSupplyAssets, v.totalSupplyShares));
        emit log_named_uint(
            "supply price after ", _index(morpho.totalSupplyAssets(marketId), morpho.totalSupplyShares(marketId))
        );
        // Borrow index deflates (borrowers relieved), supply index inflates (remaining lenders enriched).
        assertLt(
            morpho.totalBorrowAssets(marketId) * v.totalBorrowShares,
            v.totalBorrowAssets * morpho.totalBorrowShares(marketId),
            "borrow price fell"
        );
        assertGt(
            morpho.totalSupplyAssets(marketId) * v.totalSupplyShares,
            v.totalSupplyAssets * morpho.totalSupplyShares(marketId),
            "supply price rose"
        );

        // --- solvency ------------------------------------------------------------------------
        // Supply and borrow assets fall by the same `canceled`, so free liquidity is invariant and the
        // protocol stays solvent (supply >= borrow). No value is created or destroyed.
        assertEq(
            v.totalSupplyAssets - morpho.totalSupplyAssets(marketId), v.actualCanceled, "supply assets -= canceled"
        );
        assertEq(
            v.totalBorrowAssets - morpho.totalBorrowAssets(marketId), v.actualCanceled, "borrow assets -= canceled"
        );
        assertEq(
            v.totalSupplyAssets - v.totalBorrowAssets,
            morpho.totalSupplyAssets(marketId) - morpho.totalBorrowAssets(marketId),
            "free liquidity preserved"
        );
        assertGe(morpho.totalSupplyAssets(marketId), morpho.totalBorrowAssets(marketId), "protocol still solvent");
    }

    // The supply-share anchor lets a lender exit its whole position: passing all of `onBehalf`'s supply
    // shares burns them to exactly zero. Needs a borrower whose debt exceeds the lender's supply so the
    // derived debt-share burn stays within the borrower's holding (no EXCEEDS_DEBT).
    function testSettleClosesLenderSupplyToZero() public {
        MarketParams memory params = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.85 ether
        });
        Id marketId = params.id();
        ControllerMock ctrl = new ControllerMock(marketId);
        vm.prank(OWNER);
        _lido().createMarket(params, address(ctrl), true);
        oracle.setPrice(ORACLE_PRICE_SCALE);

        address lenderB = makeAddr("LenderB");

        // Two lenders (50 each); one borrower owes the whole 100 (free liquidity 0). The borrower's debt
        // (100) exceeds our lender's supply (50), so the lender exits fully without hitting the debt-cap.
        loanToken.setBalance(address(this), 50);
        morpho.supply(params, 50, 0, address(this), hex"");
        loanToken.setBalance(lenderB, 50);
        vm.startPrank(lenderB);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(params, 50, 0, lenderB, hex"");
        vm.stopPrank();

        collateralToken.setBalance(BORROWER, 1e18);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(params, 1e18, BORROWER, hex"");
        morpho.borrow(params, 100, 0, BORROWER, BORROWER);
        vm.stopPrank();

        emit log_named_uint("lender supplyShares before", morpho.supplyShares(marketId, address(this)));
        emit log_named_uint("BORROWER borrowShares before", morpho.borrowShares(marketId, BORROWER));

        uint256 tsa = morpho.totalSupplyAssets(marketId);
        uint256 tba = morpho.totalBorrowAssets(marketId);
        uint256 tbs = morpho.totalBorrowShares(marketId);
        uint256 borrowerDebtBefore = _debtAssets(marketId, BORROWER); // 100

        uint256 all = morpho.supplyShares(marketId, address(this));
        (uint256 seized, uint256 canceled) = _lido().settle(params, all, 0, address(this), BORROWER, RECEIVER);

        emit log_named_uint("lender supplyShares after", morpho.supplyShares(marketId, address(this)));
        emit log_named_uint("BORROWER borrowShares after", morpho.borrowShares(marketId, BORROWER));
        emit log_named_uint("BORROWER debt(ast) after", _debtAssets(marketId, BORROWER));
        emit log_named_uint("returned borrowAssetsCanceled", canceled);
        emit log_named_uint("returned seizedAssets", seized);

        assertEq(morpho.supplyShares(marketId, address(this)), 0, "lender fully exited");
        assertEq(canceled, 50, "cancelled the lender's 50 supply value");
        // The borrower is left half-settled: shares and debt both halved, position still open.
        assertEq(morpho.borrowShares(marketId, BORROWER), 50e6, "borrower shares halved");
        assertEq(_debtAssets(marketId, BORROWER), 50, "borrower debt halved to 50");
        assertEq(morpho.totalBorrowAssets(marketId), 50, "total borrow assets halved");

        // --- solvency (clean: 1:1 with no accrual leaves no rounding) -------------------------
        assertEq(borrowerDebtBefore, 100, "borrower owed 100 before");
        assertEq(tsa - morpho.totalSupplyAssets(marketId), canceled, "supply assets -= canceled");
        assertEq(tba - morpho.totalBorrowAssets(marketId), canceled, "borrow assets -= canceled");
        assertEq(
            tsa - tba,
            morpho.totalSupplyAssets(marketId) - morpho.totalBorrowAssets(marketId),
            "free liquidity preserved"
        );
        assertGe(morpho.totalSupplyAssets(marketId), morpho.totalBorrowAssets(marketId), "protocol still solvent");

        // The exit removes supply and borrow proportionally, so the borrow share price is unchanged.
        emit log_named_uint("borrow price before", _index(tba, tbs));
        emit log_named_uint(
            "borrow price after ", _index(morpho.totalBorrowAssets(marketId), morpho.totalBorrowShares(marketId))
        );
        assertEq(
            _index(tba, tbs),
            _index(morpho.totalBorrowAssets(marketId), morpho.totalBorrowShares(marketId)),
            "borrow share price unchanged"
        );
    }

    // The borrow-share anchor does not bypass the collateral guard: a dust debt at a high price still
    // reverts SLICE_TOO_SMALL because the seized collateral rounds to zero.
    function testSettleCloseBlockedWhenSeizeRoundsToZero() public {
        (MarketParams memory params, Id marketId,) = _dustyTwoBorrowerMarket();
        oracle.setPrice(MAX_COLLATERAL_PRICE);

        uint256 held = morpho.borrowShares(marketId, BORROWER);
        emit log_named_uint("price", oracle.price());
        emit log_named_uint(
            "BORROWER fullDebt", held.toAssetsUp(morpho.totalBorrowAssets(marketId), morpho.totalBorrowShares(marketId))
        );
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_SLICE_TOO_SMALL));
        _lido().settle(params, 0, held, address(this), BORROWER, RECEIVER);
    }

    // Edge: a sole borrower who is the whole pool cannot be fully closed when the lender has no surplus.
    // The debt valued UP (toAssetsUp) is 1 wei above the lender's supply valued DOWN (settleable supply),
    // so the borrow-anchored close trips the settleable cap (SETTLEMENT_LIQUIDITY_AVAILABLE). A gap is
    // needed: another borrower, or lender surplus beyond this borrower's debt.
    function testSettleSoleBorrowerWholePoolBlockedByCap() public {
        MarketParams memory params = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.7 ether
        });
        Id marketId = params.id();
        ControllerMock ctrl = new ControllerMock(marketId);
        vm.prank(OWNER);
        _lido().createMarket(params, address(ctrl), true);
        oracle.setPrice(ORACLE_PRICE_SCALE);

        // Sole lender supplies 12, sole borrower borrows the whole 12 (free liquidity 0); drift 12 -> 13.
        loanToken.setBalance(address(this), 12);
        morpho.supply(params, 12, 0, address(this), hex"");
        collateralToken.setBalance(BORROWER, 1e18);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(params, 1e18, BORROWER, hex"");
        morpho.borrow(params, 12, 0, BORROWER, BORROWER);
        vm.stopPrank();
        vm.warp(block.timestamp + 30 days);
        morpho.accrueInterest(params);

        uint256 held = morpho.borrowShares(marketId, BORROWER);
        assertEq(held, morpho.totalBorrowShares(marketId), "borrower is the whole pool");
        assertEq(morpho.totalSupplyAssets(marketId), morpho.totalBorrowAssets(marketId), "free liquidity is zero");

        uint256 canceled = held.toAssetsUp(morpho.totalBorrowAssets(marketId), morpho.totalBorrowShares(marketId));
        uint256 settleable = morpho.supplyShares(marketId, address(this))
            .toAssetsDown(morpho.totalSupplyAssets(marketId), morpho.totalSupplyShares(marketId));
        emit log_named_uint("debt valued up   (close needs)", canceled);
        emit log_named_uint("supply valued down (settleable)", settleable);
        assertEq(canceled, settleable + 1, "the round-up overshoots settleable by exactly 1 wei");

        // So the borrow-anchored full close trips the settleable cap (asking for 13).
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_LIQUIDITY_AVAILABLE));
        _lido().settle(params, 0, held, address(this), BORROWER, RECEIVER);

        // But the supply-anchored exit works: it only asks for the claimable supply (12 == settleable), so it
        // clears the cap, the lender leaves to zero, and the borrower keeps the 1-wei virtual-buffer dust that
        // no supply can cancel. Closing the borrower to zero is simply impossible here (13 debt vs 12 supply).
        uint256 lenderShares = morpho.supplyShares(marketId, address(this));
        (, uint256 canceledViaSupply) = _lido().settle(params, lenderShares, 0, address(this), BORROWER, RECEIVER);
        emit log_named_uint("canceled via supplyShares", canceledViaSupply);
        emit log_named_uint("borrower debt left (wei)", _debtAssets(marketId, BORROWER));
        assertEq(canceledViaSupply, settleable, "supplyShares cancels all claimable supply (12)");
        assertEq(morpho.supplyShares(marketId, address(this)), 0, "lender fully exited via supplyShares");
        assertEq(_debtAssets(marketId, BORROWER), 1, "borrower left with the 1-wei buffer dust");
    }

    // Settle by SHARES: the burned debt shares, valued back to assets, must equal the cancelled debt exactly;
    // an under-burn (the pool-draining direction) would value back to debtCanceled - 1.
    function testSettleShareRoundingWithInterestFuzz(uint256 elapsed, uint256 sliceSeed) public {
        (MarketParams memory params, Id marketId) = _openMarketWithAccruedInterest(0.5 ether, elapsed);

        Vars memory vars;
        vars.totalSupplyAssets = morpho.totalSupplyAssets(marketId);
        vars.totalSupplyShares = morpho.totalSupplyShares(marketId);
        vars.totalBorrowAssets = morpho.totalBorrowAssets(marketId);
        vars.totalBorrowShares = morpho.totalBorrowShares(marketId);
        vars.lenderShares = morpho.supplyShares(marketId, address(this));
        vars.sliceShares = bound(sliceSeed, 1, vars.lenderShares);
        vm.assume(vars.sliceShares.toAssetsDown(vars.totalSupplyAssets, vars.totalSupplyShares) > 0); // skip zero-debt
        // slices

        vars.borrowSharesBefore = morpho.borrowShares(marketId, BORROWER);
        (vars.actualSeized, vars.actualCanceled) =
            _lido().settle(params, vars.sliceShares, 0, address(this), BORROWER, RECEIVER);
        uint256 borrowSharesBurned = vars.borrowSharesBefore - morpho.borrowShares(marketId, BORROWER);

        assertEq(
            morpho.supplyShares(marketId, address(this)), vars.lenderShares - vars.sliceShares, "supply burned == input"
        );
        assertEq(
            borrowSharesBurned.toAssetsDown(vars.totalBorrowAssets, vars.totalBorrowShares),
            vars.actualCanceled,
            "burned debt valued back == cancelled debt"
        );
        assertEq(vars.actualSeized, vars.actualCanceled, "seized == cancelled at 1:1");

        assertEq(morpho.totalSupplyShares(marketId), vars.totalSupplyShares - vars.sliceShares, "total supply shares");
        assertEq(
            morpho.totalSupplyAssets(marketId), vars.totalSupplyAssets - vars.actualCanceled, "total supply assets"
        );
        assertEq(morpho.totalBorrowShares(marketId), vars.totalBorrowShares - borrowSharesBurned, "total borrow shares");
        assertEq(
            morpho.totalBorrowAssets(marketId), vars.totalBorrowAssets - vars.actualCanceled, "total borrow assets"
        );
        assertEq(collateralToken.balanceOf(RECEIVER), vars.actualSeized, "receiver collateral");
    }

    // Settle to a target asset amount: the burned supply shares, valued back to assets, must equal the
    // cancelled debt exactly; an under-burn would value back to debtCanceled - 1.
    function testSettleAssetTargetRoundingWithInterestFuzz(uint256 elapsed, uint256 assetsSeed) public {
        (MarketParams memory params, Id marketId) = _openMarketWithAccruedInterest(0.625 ether, elapsed);

        Vars memory vars;
        vars.totalSupplyAssets = morpho.totalSupplyAssets(marketId);
        vars.totalSupplyShares = morpho.totalSupplyShares(marketId);
        vars.lenderShares = morpho.supplyShares(marketId, address(this));
        vars.debtCanceled =
            bound(assetsSeed, 1, vars.lenderShares.toAssetsDown(vars.totalSupplyAssets, vars.totalSupplyShares));
        vm.assume(vars.debtCanceled.toSharesUp(vars.totalSupplyAssets, vars.totalSupplyShares) <= vars.lenderShares);

        (, vars.actualCanceled) = _lido()
            .settle(
                params,
                vars.debtCanceled.toSharesUp(vars.totalSupplyAssets, vars.totalSupplyShares),
                0,
                address(this),
                BORROWER,
                RECEIVER
            );
        uint256 supplySharesBurned = vars.lenderShares - morpho.supplyShares(marketId, address(this));

        assertEq(vars.actualCanceled, vars.debtCanceled, "cancelled debt == asset target");
        assertEq(
            supplySharesBurned.toAssetsDown(vars.totalSupplyAssets, vars.totalSupplyShares),
            vars.debtCanceled,
            "burned supply valued back == cancelled debt"
        );
        assertEq(morpho.totalSupplyShares(marketId), vars.totalSupplyShares - supplySharesBurned, "total supply shares");
        assertEq(morpho.totalSupplyAssets(marketId), vars.totalSupplyAssets - vars.debtCanceled, "total supply assets");
    }
}
