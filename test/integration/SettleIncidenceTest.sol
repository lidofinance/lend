// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTestWithController.sol";

import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";

/// @dev Tests that pin WHO bears each rounding in `settle`, that a borrower with no debt is unreachable,
///      and that the debt total's zero floor is exercised. These properties are not covered by the
///      arithmetic tests in SettleMathTest, which assert amounts rather than incidence.

/// @dev Does every rounding in `settle` land on the caller? Two properties, fuzzed on a multi-borrower
///      market with a drifted index and a fuzzed price.
contract SettleIncidenceTest is BaseTestWithController {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    address internal TARGET;
    address internal OTHER;

    MarketParams internal p;
    Id internal mid;

    function _setup(uint256 lltv, uint256 elapsed) internal {
        p = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: lltv
        });
        mid = p.id();
        ControllerMock ctrl = new ControllerMock(mid);
        vm.prank(OWNER);
        _lido().createMarket(p, address(ctrl), true);
        oracle.setPrice(ORACLE_PRICE_SCALE);

        TARGET = makeAddr("Target");
        OTHER = makeAddr("Other");

        _supplyAs(p, address(this), 100e18);
        _borrowAs(p, TARGET, 1000e18, 30e18);
        _borrowAs(p, OTHER, 1000e18, 60e18);

        vm.warp(block.timestamp + bound(elapsed, 1, 365 days));
        morpho.accrueInterest(p);
    }

    /// @dev Value of `who`'s debt, rounded DOWN so the borrower is not credited with rounding.
    function _debtDown(address who) internal view returns (uint256) {
        return morpho.borrowShares(mid, who).toAssetsDown(morpho.totalBorrowAssets(mid), morpho.totalBorrowShares(mid));
    }

    /// @dev Value of this contract's supply claim, rounded DOWN.
    function _supplyDown() internal view returns (uint256) {
        return morpho.supplyShares(mid, address(this))
            .toAssetsDown(morpho.totalSupplyAssets(mid), morpho.totalSupplyShares(mid));
    }

    function testIncidenceFuzz(uint256 elapsed, uint256 cutSeed, uint256 priceSeed) public {
        _setup(0.77 ether, elapsed);
        _setFuzzedPrice(priceSeed);

        uint256 held = morpho.borrowShares(mid, TARGET);
        uint256 cut = bound(cutSeed, 1, held);
        uint256 price = oracle.price();
        // Mirror the core's seize derivation, so only cuts the core accepts are exercised.
        vm.assume(
            cut.toAssetsDown(morpho.totalBorrowAssets(mid), morpho.totalBorrowShares(mid))
                .mulDivDown(ORACLE_PRICE_SCALE, price) != 0
        );

        uint256 targetDebtBefore = _debtDown(TARGET);
        uint256 targetCollBefore = morpho.collateral(mid, TARGET);
        uint256 lenderSupplyBefore = _supplyDown();
        uint256 otherDebtBefore = _debtDown(OTHER);

        uint256 supplyBurned;
        uint256 seized;
        (seized,,, supplyBurned) = _lido().settle(p, cut, address(this), TARGET, RECEIVER);

        // What each side actually gave up or received, in loan-asset value.
        uint256 collateralValueTaken = seized.mulDivDown(price, ORACLE_PRICE_SCALE);
        uint256 targetDebtRelief = targetDebtBefore - _debtDown(TARGET);
        uint256 lenderSupplyGiven = lenderSupplyBefore - _supplyDown();

        // PROPERTY 1: the borrower never pays more collateral value than the debt relief it receives.
        assertLe(collateralValueTaken, targetDebtRelief, "borrower pays no more than it is relieved of");

        // PROPERTY 2: the caller never collects more collateral value than the supply claim it gave up.
        assertLe(collateralValueTaken, lenderSupplyGiven, "caller collects no more than it surrenders");

        // PROPERTY 3: the untouched borrower is never made worse off.
        assertLe(_debtDown(OTHER), otherDebtBefore, "bystander borrower never owes more");

        assertEq(morpho.collateral(mid, TARGET), targetCollBefore - seized, "collateral delta");
    }
}

/// @dev Can the rounded-down seize basis let a borrower with no debt be settled against?
contract SettleDebtlessBorrowerTest is BaseTestWithController {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    address internal VICTIM;
    MarketParams internal p;
    Id internal mid;

    /// @dev The exact fixture the old debtless-seizure PoC used: an index driven so far that one raw borrow
    ///      share is worth more than one loan-asset unit.
    function _expensiveMarket(uint256 lltv) internal {
        p = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: lltv
        });
        mid = p.id();
        ControllerMock ctrl = new ControllerMock(mid);
        vm.prank(OWNER);
        _lido().createMarket(p, address(ctrl), true);
        oracle.setPrice(ORACLE_PRICE_SCALE);

        vm.prank(OWNER);
        morpho.setFee(p, MAX_FEE);

        _supplyAs(p, address(this), 100);
        _borrowAs(p, BORROWER, 1e18, 100);
        for (uint256 i; i < 15; ++i) {
            vm.warp(block.timestamp + 365 days);
            morpho.accrueInterest(p);
        }

        VICTIM = makeAddr("DebtlessVictim");
        collateralToken.setBalance(VICTIM, 1e18);
        vm.startPrank(VICTIM);
        collateralToken.approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(p, 1e18, VICTIM, hex"");
        vm.stopPrank();
    }

    function testDebtlessBorrowerCannotBeSettledFuzz(uint256 cutSeed) public {
        _expensiveMarket(0.66 ether);

        assertEq(morpho.borrowShares(mid, VICTIM), 0, "victim owes nothing");
        assertGt(morpho.collateral(mid, VICTIM), 0, "victim has collateral to take");
        // The state that broke the old supply-anchored derivation is present.
        assertGt(
            morpho.totalBorrowAssets(mid) + SharesMathLib.VIRTUAL_ASSETS,
            morpho.totalBorrowShares(mid) + SharesMathLib.VIRTUAL_SHARES,
            "one borrow share is worth more than one asset unit"
        );

        uint256 collBefore = morpho.collateral(mid, VICTIM);
        uint256 cut = bound(cutSeed, 1, type(uint128).max);

        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_DEBT));
        _lido().settle(p, cut, address(this), VICTIM, RECEIVER);

        assertEq(morpho.collateral(mid, VICTIM), collBefore, "collateral untouched");
    }

    /// @dev A zero cut is rejected before anything is derived, so it cannot reach the seize either.
    function testZeroCutRejected() public {
        _expensiveMarket(0.67 ether);
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_SLICE_TOO_SMALL));
        _lido().settle(p, 0, address(this), VICTIM, RECEIVER);
    }
}

/// @dev Exercises the one path where `borrowAssetsCanceled` exceeds `totalBorrowAssets` and the core's
///      zero floor does real work. No other settle test reaches it.
contract SettleDebtFloorTest is BaseTestWithController {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    MarketParams internal p;
    Id internal mid;

    function testZeroFloorSubIsExercised() public {
        p = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.53 ether
        });
        mid = p.id();
        ControllerMock ctrl = new ControllerMock(mid);
        vm.prank(OWNER);
        _lido().createMarket(p, address(ctrl), true);
        oracle.setPrice(ORACLE_PRICE_SCALE);

        // No time is warped anywhere, so the IRM never accrues and the index moves only through settle.
        _supplyAs(p, address(this), 100);
        _borrowAs(p, BORROWER, 1e18, 100);

        // A permissionless one-share repay removes a whole asset unit for a share worth a millionth of it,
        // which drops the borrow-share price below the value it starts at. Settle can no longer produce this
        // state itself, since it rejects a cut worth less than one asset unit, but repay still can.
        loanToken.setBalance(BORROWER, 10);
        vm.startPrank(BORROWER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.repay(p, 0, 1, BORROWER, hex"");
        vm.stopPrank();
        assertGt(
            morpho.totalBorrowShares(mid),
            SharesMathLib.VIRTUAL_SHARES * morpho.totalBorrowAssets(mid),
            "borrow-share price now below its starting value"
        );

        // Fresh liquidity, so the supply gate stops being the binding constraint.
        _supplyAs(p, SUPPLIER, 100);

        uint256 holding = morpho.borrowShares(mid, BORROWER);
        uint256 tbaBefore = morpho.totalBorrowAssets(mid);
        uint256 tsaBefore = morpho.totalSupplyAssets(mid);
        uint256 canceledExpected = holding.toAssetsUp(tbaBefore, morpho.totalBorrowShares(mid));

        // The precondition the floor exists for.
        assertEq(canceledExpected, tbaBefore + 1, "the cut values up to exactly one unit above the debt total");

        vm.prank(SUPPLIER);
        (, uint256 canceled,,) = _lido().settle(p, holding, SUPPLIER, BORROWER, RECEIVER);

        assertEq(canceled, canceledExpected, "returned value is the unfloored amount");
        assertEq(morpho.totalBorrowAssets(mid), 0, "debt total floored at zero instead of underflowing");
        assertEq(morpho.borrowShares(mid, BORROWER), 0, "position closed exactly");
        // The supply side takes the full unfloored amount, so free liquidity absorbs the extra unit.
        assertEq(morpho.totalSupplyAssets(mid), tsaBefore - canceled, "supply total takes the full amount");
    }
}

/// @dev The dust close. A debt worth less than one collateral unit seizes nothing, so `settle` may close such
///      a position but may never cut a piece off it. Without this, the position could never be settled at all:
///      a smaller cut seizes nothing either, and `repay` can leave one behind. The lender pays the canceled
///      amount and gets no collateral. That cost fits the per-call bound of `SettleRoundingAccumulationTest`,
///      because a zero seizure means the debt is worth less than one collateral unit.
contract SettleDustHoldingTest is BaseTestWithController {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    ControllerMock internal ctrl;

    /// @dev A fresh controlled market at `price`, with `address(this)` lending `supplied` and BORROWER
    ///      borrowing `borrowed` against `collateral`.
    function _market(uint256 lltv, uint256 price, uint256 supplied, uint256 collateral, uint256 borrowed)
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
        ctrl = new ControllerMock(marketId);
        vm.prank(OWNER);
        _lido().createMarket(params, address(ctrl), true);
        oracle.setPrice(price);

        _supplyAs(params, address(this), supplied);
        _borrowAs(params, BORROWER, collateral, borrowed);
    }

    /// @dev First case: `repay` leaves less than one loan unit of debt. The shares value DOWN to zero, so
    ///      there is no basis to price a seizure from.
    function testShareDustHoldingClosesForZeroCollateral() public {
        (MarketParams memory p, Id mid) = _market(0.91 ether, ORACLE_PRICE_SCALE, 1000, 1e18, 100);

        uint256 held = morpho.borrowShares(mid, BORROWER);
        loanToken.setBalance(BORROWER, 1000);
        vm.startPrank(BORROWER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.repay(p, 0, held - 500_000, BORROWER, hex""); // leaves 500_000 shares = half a loan unit
        vm.stopPrank();

        uint256 dust = morpho.borrowShares(mid, BORROWER);
        assertEq(
            dust.toAssetsDown(morpho.totalBorrowAssets(mid), morpho.totalBorrowShares(mid)), 0, "values DOWN to nothing"
        );
        assertEq(dust.toAssetsUp(morpho.totalBorrowAssets(mid), morpho.totalBorrowShares(mid)), 1, "and UP to one unit");

        uint256 collateralBefore = morpho.collateral(mid, BORROWER);
        uint256 receiverBefore = collateralToken.balanceOf(RECEIVER);
        uint256 lenderSharesBefore = morpho.supplyShares(mid, address(this));
        uint256 tsaBefore = morpho.totalSupplyAssets(mid);

        (uint256 seized, uint256 canceled, uint256 sharesCanceled, uint256 burned) =
            _lido().settle(p, dust, address(this), BORROWER, RECEIVER);

        assertEq(seized, 0, "no collateral backs the unit");
        assertEq(canceled, 1, "one loan unit canceled");
        assertEq(sharesCanceled, dust, "the whole holding");
        assertEq(morpho.borrowShares(mid, BORROWER), 0, "position closed");
        assertEq(morpho.totalBorrowShares(mid), 0, "market debt shares zeroed");
        assertEq(morpho.totalBorrowAssets(mid), 0, "market debt assets zeroed");

        // The borrower keeps every collateral unit: the close forgives, it does not seize.
        assertEq(morpho.collateral(mid, BORROWER), collateralBefore, "collateral untouched");
        assertEq(collateralToken.balanceOf(RECEIVER), receiverBefore, "receiver paid nothing");

        // The whole cost lands on the settling lender, which burns supply for the unit it is not paid for.
        assertEq(morpho.supplyShares(mid, address(this)), lenderSharesBefore - burned, "lender burned the unit");
        assertEq(morpho.totalSupplyAssets(mid), tsaBefore - 1, "supply total down by exactly the unit");

        // Unrepeatable: closing the position is what spends the allowance.
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_DEBT));
        _lido().settle(p, 1, address(this), BORROWER, RECEIVER);
    }

    /// @dev Second case: the collateral is expensive, so the whole debt buys no collateral unit. Fuzzed over
    ///      the price and over the debt, up to the largest debt that still seizes nothing. Whatever it costs,
    ///      it fits the per-call bound, because a zero seizure means the debt is worth less than one unit.
    function testPricedOutHoldingClosesForZeroCollateralFuzz(uint256 priceSeed, uint256 debtSeed) public {
        uint256 price = bound(priceSeed, 2 * ORACLE_PRICE_SCALE, MAX_COLLATERAL_PRICE);
        // The debt seizes nothing as long as it is worth less than one collateral unit.
        uint256 debt = bound(debtSeed, 1, price / ORACLE_PRICE_SCALE - 1);
        (MarketParams memory p, Id mid) = _market(0.9 ether, price, debt, 1e18, debt);

        uint256 held = morpho.borrowShares(mid, BORROWER);
        uint256 collateralBefore = morpho.collateral(mid, BORROWER);
        uint256 tsaBefore = morpho.totalSupplyAssets(mid);

        (uint256 seized, uint256 canceled,,) = _lido().settle(p, held, address(this), BORROWER, RECEIVER);

        assertEq(seized, 0, "the whole debt buys less than one collateral unit");
        assertEq(canceled, debt, "the whole debt canceled");
        assertEq(morpho.borrowShares(mid, BORROWER), 0, "position closed");
        assertEq(morpho.collateral(mid, BORROWER), collateralBefore, "collateral untouched");
        assertEq(morpho.totalSupplyAssets(mid), tsaBefore - canceled, "the settling lender ate the whole amount");

        // The same bound SettleRoundingAccumulationTest checks, here on a call that seizes nothing.
        uint256 lossScaled = canceled * ORACLE_PRICE_SCALE - seized * price;
        assertLt(lossScaled, ORACLE_PRICE_SCALE + price, "inside the ordinary per-call bound");
    }

    /// @dev Only a close is allowed. Any smaller cut still reverts, so nobody can take a position apart one
    ///      free unit at a time.
    function testDustPartialCutStillRevertsFuzz(uint256 cutSeed) public {
        (MarketParams memory p, Id mid) = _market(0.9 ether, 2 * ORACLE_PRICE_SCALE, 10, 1e18, 1);

        uint256 held = morpho.borrowShares(mid, BORROWER);
        uint256 cut = bound(cutSeed, 1, held - 1);

        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_SLICE_TOO_SMALL));
        _lido().settle(p, cut, address(this), BORROWER, RECEIVER);
    }

    /// @dev Where the exception stops, on one market. Two of the three units buy no collateral, and that cut
    ///      reverts because it does not close the position. The whole three units are worth exactly one
    ///      collateral unit, so the close seizes and takes the normal path instead.
    function testZeroSeizureBoundaryFallsBackToOrdinaryPath() public {
        (MarketParams memory p, Id mid) = _market(0.9 ether, 3 * ORACLE_PRICE_SCALE, 10, 1e18, 3);
        uint256 held = morpho.borrowShares(mid, BORROWER);

        assertEq(_seizedForShares(mid, held * 2 / 3), 0, "two of the three units buy nothing");
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_SLICE_TOO_SMALL));
        _lido().settle(p, held * 2 / 3, address(this), BORROWER, RECEIVER);

        (uint256 seized, uint256 canceled,,) = _lido().settle(p, held, address(this), BORROWER, RECEIVER);
        assertEq(canceled, 3, "three loan units canceled");
        assertEq(seized, 1, "which is exactly one collateral unit, so no exception was needed");
    }

    /// @dev The controller sees the zero seizure in the payload, so it can still refuse the close.
    function testDustCloseHookSeesZeroSeizureAndCanVeto() public {
        (MarketParams memory p, Id mid) = _market(0.9 ether, 2 * ORACLE_PRICE_SCALE, 10, 1e18, 1);
        uint256 held = morpho.borrowShares(mid, BORROWER);

        ctrl.setRevertOn(ILidoLendMarketController.HookEvent.Settle, true);
        vm.expectRevert("blocked by controller");
        _lido().settle(p, held, address(this), BORROWER, RECEIVER);
        assertEq(morpho.borrowShares(mid, BORROWER), held, "veto left the holding open");

        ctrl.setRevertOn(ILidoLendMarketController.HookEvent.Settle, false);
        _lido().settle(p, held, address(this), BORROWER, RECEIVER);

        ILidoLendMarketController.SettleHookData memory d =
            abi.decode(ctrl.lastData(), (ILidoLendMarketController.SettleHookData));
        assertEq(d.seizedAssets, 0, "hook saw the zero seizure");
        assertEq(d.borrowAssetsCanceled, 1, "hook saw the single canceled unit");
        assertEq(d.borrowSharesCanceled, held, "hook saw the whole holding");
    }
}
