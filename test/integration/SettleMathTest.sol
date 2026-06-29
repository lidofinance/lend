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

    // The liquidity gate fires when debtCanceled > free liquidity; the boundary is tight (+1 reverts, exact passes).
    function testSettleLiquidityGateBoundary(uint256 priceSeed) public {
        _setFuzzedPrice(priceSeed);
        _openPosition(100e18, 100e18, 70e18);
        uint256 freeLiquidity = morpho.totalSupplyAssets(id) - morpho.totalBorrowAssets(id);
        assertEq(freeLiquidity, 30e18, "free liquidity");
        // Single supplier: settleable supply = own supply (100) − free liquidity (30) = the borrowed 70.
        uint256 settleableSupply = 100e18 - freeLiquidity;
        assertEq(settleableSupply, 70e18, "settleable supply");

        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_LIQUIDITY_AVAILABLE));
        _lido()
            .settle(
                marketParams,
                0,
                (settleableSupply + 1) * SharesMathLib.VIRTUAL_SHARES,
                address(this),
                BORROWER,
                RECEIVER
            );

        uint256 lenderSharesBefore = morpho.supplyShares(id, address(this));
        uint256 sliceShares = settleableSupply * SharesMathLib.VIRTUAL_SHARES;
        (uint256 seizedAssets,) = _lido().settle(marketParams, 0, sliceShares, address(this), BORROWER, RECEIVER);
        assertEq(seizedAssets, _seizedFor(settleableSupply), "seized the cancelled debt's worth of collateral");
        assertEq(morpho.supplyShares(id, address(this)), lenderSharesBefore - sliceShares, "lender shares reduced");
    }

    // Supplying assets directly (not shares) yields debtCanceled == the supplied amount exactly.
    function testSettleByAssetsInput(uint256 priceSeed) public {
        _setFuzzedPrice(priceSeed);
        _openPosition(100e18, 100e18, 70e18); // free liquidity = 30e18
        uint256 settleAssets = 40e18; // > free liquidity, within the borrower's 70e18 debt

        (uint256 seizedAssets, uint256 canceledAssets) =
            _lido().settle(marketParams, settleAssets, 0, address(this), BORROWER, RECEIVER);

        assertEq(canceledAssets, settleAssets, "debtCanceled equals the supplyAssets input");
        assertEq(seizedAssets, _seizedFor(settleAssets), "seized the cancelled debt's worth of collateral");
    }

    // Each cap has its own error; the revert string pins which check fired.

    // At an extreme price, debtCanceled == 1 → collateralSeized rounds to 0 → rejected before any state write.
    function testSettleOverCapZeroCollateral() public {
        _openPosition(100e18, 200e18, 100e18);
        oracle.setPrice(MAX_COLLATERAL_PRICE);
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_SLICE_TOO_SMALL));
        _lido().settle(marketParams, 0, 1 * SharesMathLib.VIRTUAL_SHARES, address(this), BORROWER, RECEIVER);
    }

    // debtCanceled 60e18 → collateralSeized 120e18 > 100e18 collateral at half price.
    function testSettleOverCapCollateral() public {
        _openPosition(100e18, 100e18, 70e18);
        oracle.setPrice(ORACLE_PRICE_SCALE / 2); // collateral now worth 50e18
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_COLLATERAL));
        _lido().settle(marketParams, 0, 60e18 * SharesMathLib.VIRTUAL_SHARES, address(this), BORROWER, RECEIVER);
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
        _lido().settle(marketParams, 0, 80e18 * SharesMathLib.VIRTUAL_SHARES, address(this), BORROWER, RECEIVER);
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
            _lido().settle(marketParams, 0, vars.sliceShares, address(this), BORROWER, RECEIVER);

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

        _lido().settle(params, 1e18, 0, address(this), BORROWER, RECEIVER);

        assertEq(morpho.lastUpdate(marketId), block.timestamp, "settle realized pending interest");
    }

    // A fully-settleable position cannot be closed because the debt-cap rounds the share burn UP past
    // the borrower's holding. To cancel a borrower's entire debt the caller must pass its asset value
    // rounded up (toAssetsUp of their shares); the cap then converts that back with toSharesUp and
    // overshoots, reverting with SETTLEMENT_EXCEEDS_DEBT. This test FAILS on the current code; it passes
    // once the burn is capped to the borrower's shares (min(toSharesUp(...), borrowShares)).
    //
    // Setup: two borrowers, 2 wei each (100% utilization). After ~82 days the total debt drifts 4 -> 5:
    //   totalBorrowAssets = 5, totalBorrowShares = 4e6, each borrower holds 2e6 shares.
    //
    // BORROWER's 2e6 shares are worth toAssetsUp(2e6, 5, 4e6) = ceil(2.4) = 3 wei — the amount that must
    // be cancelled to clear all 2e6 shares. But the cap converts it back to:
    //   toSharesUp(3, 5, 4e6) = ceil(15e6 / 6) = 2_500_000 > 2e6  → reverts
    // (toSharesDown would give floor(2.5e6) = 2_500_000 too — same revert; only capping the burn fixes it.)
    //
    // A second borrower keeps the lender's settleable supply (4 wei) above the 3-wei cut so the liquidity
    // gate clears and only the debt-cap decides the outcome.
    /// @dev Dumps the market totals and BORROWER's position so each step is visible with `-vv`.
    function _dump(string memory step, Id marketId, address borrower2) internal {
        emit log_string(step);
        emit log_named_uint("  totalSupplyAssets", morpho.totalSupplyAssets(marketId));
        emit log_named_uint("  totalSupplyShares", morpho.totalSupplyShares(marketId));
        emit log_named_uint("  totalBorrowAssets", morpho.totalBorrowAssets(marketId));
        emit log_named_uint("  totalBorrowShares", morpho.totalBorrowShares(marketId));
        emit log_named_uint("  lender supplyShares", morpho.supplyShares(marketId, address(this)));
        emit log_named_uint("  BORROWER borrowShares", morpho.borrowShares(marketId, BORROWER));
        emit log_named_uint("  borrower2 borrowShares", morpho.borrowShares(marketId, borrower2));
    }

    function testSettleClosePositionRoundsBurnPastHolding() public {
        MarketParams memory params = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.9 ether
        });
        Id marketId = params.id();
        ControllerMock ctrl = new ControllerMock(marketId);
        vm.prank(OWNER);
        _lido().createMarket(params, address(ctrl), true);
        oracle.setPrice(ORACLE_PRICE_SCALE); // 1:1, isolate share rounding from the price leg

        address borrower2 = makeAddr("Borrower2");

        loanToken.setBalance(address(this), 12);
        morpho.supply(params, 12, 0, address(this), hex"");
        _dump("after lender supplies 12 wei", marketId, borrower2);

        collateralToken.setBalance(BORROWER, 1e18);
        collateralToken.setBalance(borrower2, 1e18);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(params, 1e18, BORROWER, hex"");
        morpho.borrow(params, 7, 0, BORROWER, BORROWER);
        vm.stopPrank();
        _dump("after BORROWER borrows 7 wei", marketId, borrower2);

        vm.startPrank(borrower2);
        collateralToken.approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(params, 1e18, borrower2, hex"");
        morpho.borrow(params, 5, 0, borrower2, borrower2);
        vm.stopPrank();
        _dump("after borrower2 borrows 5 wei", marketId, borrower2);

        vm.warp(block.timestamp + 30 days);
        morpho.accrueInterest(params);
        _dump("after 82 days + accrue (debt drifts 12 -> 13)", marketId, borrower2);

        // Pin the drifted state the comment reasons about, so a change here fails loudly here.
        assertEq(morpho.totalBorrowAssets(marketId), 13, "total debt drifted 12 -> 13 wei");
        assertEq(morpho.totalBorrowShares(marketId), 12e6, "total borrow shares == 12e6");
        assertEq(morpho.borrowShares(marketId, BORROWER), 7e6, "BORROWER holds 2e6 shares");

        // To clear all of BORROWER's 2e6 shares, cancel their debt valued up (3 wei).
        uint256 fullDebt = morpho.borrowShares(marketId, BORROWER)
            .toAssetsUp(morpho.totalBorrowAssets(marketId), morpho.totalBorrowShares(marketId));
        assertEq(fullDebt, 7, "b1 full debt valued up is 7 wei");

        // To clear all of BORROWER's 2e6 shares, cancel their debt valued up (3 wei).
        uint256 fullDebt1 = morpho.borrowShares(marketId, borrower2)
            .toAssetsUp(morpho.totalBorrowAssets(marketId), morpho.totalBorrowShares(marketId));
        assertEq(fullDebt1, 6, "b2 full debt valued up is 6 wei");

        // Show exactly why the settle of `fullDebt` reverts: the cap converts it back to more shares
        // than BORROWER holds (rounding direction is irrelevant — the overshoot is ~500k shares).
        emit log_string("attempting to close BORROWER by settling fullDebt");
        emit log_named_uint("  settle amount (wei)", fullDebt);
        emit log_named_uint(
            "  toSharesUp(fullDebt)  -> shares to burn",
            fullDebt.toSharesUp(morpho.totalBorrowAssets(marketId), morpho.totalBorrowShares(marketId))
        );
        emit log_named_uint(
            "  toSharesDown(fullDebt)-> shares to burn",
            fullDebt.toSharesDown(morpho.totalBorrowAssets(marketId), morpho.totalBorrowShares(marketId))
        );
        emit log_named_uint("  BORROWER actually holds", morpho.borrowShares(marketId, BORROWER));

        // BUG: the cap burns toSharesUp(3) = 2.5e6 > 2e6 and reverts; capping the burn would close it.

        // _lido().settle(params, fullDebt, 0, address(this), BORROWER, RECEIVER);
        emit log_named_uint("supplier shares", morpho.supplyShares(marketId, address(this)));
        _lido().settle(params, fullDebt, 0, address(this), BORROWER, RECEIVER);
        emit log_named_uint(
            "borrower balance",
            morpho.borrowShares(marketId, BORROWER)
                .toAssetsUp(morpho.totalBorrowAssets(marketId), morpho.totalBorrowShares(marketId))
        );

        emit log_string("1");

        vm.startPrank(BORROWER);
        _lido().repay(params, 1, 0, BORROWER, hex"");

        emit log_named_uint(
            "borrower balance",
            morpho.borrowShares(marketId, BORROWER)
                .toAssetsUp(morpho.totalBorrowAssets(marketId), morpho.totalBorrowShares(marketId))
        );

        emit log_string("2");

        // assertEq(morpho.borrowShares(marketId, BORROWER), 0, "position fully closed");
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
            _lido().settle(params, 0, vars.sliceShares, address(this), BORROWER, RECEIVER);
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

    // Settle by ASSETS: the burned supply shares, valued back to assets, must equal the cancelled debt exactly;
    // an under-burn would value back to debtCanceled - 1.
    function testSettleByAssetsShareRoundingWithInterestFuzz(uint256 elapsed, uint256 assetsSeed) public {
        (MarketParams memory params, Id marketId) = _openMarketWithAccruedInterest(0.625 ether, elapsed);

        Vars memory vars;
        vars.totalSupplyAssets = morpho.totalSupplyAssets(marketId);
        vars.totalSupplyShares = morpho.totalSupplyShares(marketId);
        vars.lenderShares = morpho.supplyShares(marketId, address(this));
        vars.debtCanceled =
            bound(assetsSeed, 1, vars.lenderShares.toAssetsDown(vars.totalSupplyAssets, vars.totalSupplyShares));
        vm.assume(vars.debtCanceled.toSharesUp(vars.totalSupplyAssets, vars.totalSupplyShares) <= vars.lenderShares);

        (, vars.actualCanceled) = _lido().settle(params, vars.debtCanceled, 0, address(this), BORROWER, RECEIVER);
        uint256 supplySharesBurned = vars.lenderShares - morpho.supplyShares(marketId, address(this));

        assertEq(vars.actualCanceled, vars.debtCanceled, "assets input == cancelled debt");
        assertEq(
            supplySharesBurned.toAssetsDown(vars.totalSupplyAssets, vars.totalSupplyShares),
            vars.debtCanceled,
            "burned supply valued back == cancelled debt"
        );
        assertEq(morpho.totalSupplyShares(marketId), vars.totalSupplyShares - supplySharesBurned, "total supply shares");
        assertEq(morpho.totalSupplyAssets(marketId), vars.totalSupplyAssets - vars.debtCanceled, "total supply assets");
    }
}
