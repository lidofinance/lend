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

        // No time is warped, so the IRM never accrues; the borrow index changes only through the repay below.
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

/// @dev A debt holding worth less than one loan-asset unit cannot be settled at all, because the seizure
///      prices it down to zero. It stays open and must be cleared with `repay` or `liquidate`.
contract SettleDustHoldingTest is BaseTestWithController {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    function testDustPositionCannotBeClosed() public {
        MarketParams memory p = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.91 ether
        });
        Id i = p.id();
        ControllerMock c = new ControllerMock(i);
        vm.prank(OWNER);
        _lido().createMarket(p, address(c), true);
        oracle.setPrice(ORACLE_PRICE_SCALE);

        _supplyAs(p, address(this), 1000);
        _borrowAs(p, BORROWER, 1e18, 100);

        // Repay all but a sub-unit sliver of shares.
        uint256 held = morpho.borrowShares(i, BORROWER);
        loanToken.setBalance(BORROWER, 1000);
        vm.startPrank(BORROWER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.repay(p, 0, held - 500_000, BORROWER, hex""); // leaves 500_000 shares = 0.5 asset units
        vm.stopPrank();

        uint256 dust = morpho.borrowShares(i, BORROWER);
        emit log_named_uint("shares left", dust);
        emit log_named_uint("valued DOWN", dust.toAssetsDown(morpho.totalBorrowAssets(i), morpho.totalBorrowShares(i)));
        emit log_named_uint("valued UP  ", dust.toAssetsUp(morpho.totalBorrowAssets(i), morpho.totalBorrowShares(i)));

        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_SLICE_TOO_SMALL));
        _lido().settle(p, dust, address(this), BORROWER, RECEIVER);
        emit log_string("-> full close of a sub-unit position REVERTS");
    }
}
