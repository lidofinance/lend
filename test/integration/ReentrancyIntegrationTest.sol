// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";

import {IMorphoBase} from "../../src/interfaces/IMorpho.sol";
import {ILidoBlue} from "../../src/interfaces/ILidoBlue.sol";
import {ReentrantControllerMock} from "../../src/mocks/ReentrantControllerMock.sol";

contract ReentrancyIntegrationTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using MorphoLib for IMorpho;

    MarketParams internal dp;
    Id internal did;
    ReentrantControllerMock internal rc;

    function _lido() internal view returns (ILidoBlue) {
        return ILidoBlue(address(morpho));
    }

    /// @dev Arms the reentrant call and asserts the hook actually dispatches it (a negative control:
    ///      the test stays meaningful even if the outer call later reverts for some unrelated reason).
    function _armAndExpect(bytes memory reentry) internal {
        rc.arm(reentry);
        vm.expectCall(address(morpho), reentry);
    }

    function setUp() public override {
        super.setUp();
        // `irm == 0` gives an id distinct from the default (irm) market; bound to the reentrant controller.
        dp = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(0),
            lltv: DEFAULT_TEST_LLTV
        });
        did = dp.id();
        rc = new ReentrantControllerMock(did, address(morpho));
        vm.prank(OWNER);
        _lido().createMarket(dp, address(rc), true);

        // Worst case: the controller is fully funded/approved and authorized to act for the lender.
        loanToken.setBalance(address(rc), 1e30);
        collateralToken.setBalance(address(rc), 1e30);
        vm.startPrank(address(rc));
        loanToken.approve(address(morpho), type(uint256).max);
        collateralToken.approve(address(morpho), type(uint256).max);
        vm.stopPrank();
        morpho.setAuthorization(address(rc), true);
    }

    function testReentrancySupplyCannotWithdrawUncredited() public {
        loanToken.setBalance(address(this), 10e18);
        // Reenter withdraw of shares the in-flight supply has not credited yet → underflow.
        _armAndExpect(
            abi.encodeCall(
                IMorphoBase.withdraw, (dp, 0, 10e18 * SharesMathLib.VIRTUAL_SHARES, address(this), address(this))
            )
        );
        vm.expectRevert(stdError.arithmeticError);
        morpho.supply(dp, 10e18, 0, address(this), hex"");
    }

    function testReentrancyWithdrawCannotDoubleWithdraw() public {
        loanToken.setBalance(address(this), 100e18);
        morpho.supply(dp, 100e18, 0, address(this), hex"");

        uint256 shares = morpho.supplyShares(did, address(this));
        _armAndExpect(abi.encodeCall(IMorphoBase.withdraw, (dp, 0, shares, address(this), address(this))));
        vm.expectRevert(stdError.arithmeticError);
        morpho.withdraw(dp, 0, shares, address(this), address(this));
    }

    function testReentrancyBorrowCannotExceedLtv() public {
        loanToken.setBalance(address(this), 100e18);
        morpho.supply(dp, 100e18, 0, address(this), hex"");
        collateralToken.setBalance(address(this), 100e18);
        morpho.supplyCollateral(dp, 100e18, address(this), hex""); // maxBorrow = 80e18

        // Reenter another 50e18 borrow → two 50e18 borrows exceed the 80e18 cap → outer health check reverts.
        _armAndExpect(abi.encodeCall(IMorphoBase.borrow, (dp, 50e18, 0, address(this), address(this))));
        vm.expectRevert(bytes(ErrorsLib.INSUFFICIENT_COLLATERAL));
        morpho.borrow(dp, 50e18, 0, address(this), address(this));
    }

    function testReentrancyRepayCannotOverRepay() public {
        loanToken.setBalance(address(this), 100e18);
        morpho.supply(dp, 100e18, 0, address(this), hex"");
        collateralToken.setBalance(address(this), 100e18);
        morpho.supplyCollateral(dp, 100e18, address(this), hex"");
        morpho.borrow(dp, 50e18, 0, address(this), address(this)); // debt 50e18

        // Reenter repay 40e18 (paid by the funded rc); the outer's second 40e18 burn underflows the 50e18 debt.
        _armAndExpect(abi.encodeCall(IMorphoBase.repay, (dp, 40e18, 0, address(this), hex"")));
        vm.expectRevert(stdError.arithmeticError);
        morpho.repay(dp, 40e18, 0, address(this), hex"");
    }

    function testReentrancySupplyCollateralCannotWithdrawUncredited() public {
        collateralToken.setBalance(address(this), 10e18);
        // Reenter withdrawCollateral before the in-flight supplyCollateral credits it → underflow.
        _armAndExpect(abi.encodeCall(IMorphoBase.withdrawCollateral, (dp, 10e18, address(this), address(this))));
        vm.expectRevert(stdError.arithmeticError);
        morpho.supplyCollateral(dp, 10e18, address(this), hex"");
    }

    function testReentrancyWithdrawCollateralCannotDoubleWithdraw() public {
        collateralToken.setBalance(address(this), 100e18);
        morpho.supplyCollateral(dp, 100e18, address(this), hex"");

        _armAndExpect(abi.encodeCall(IMorphoBase.withdrawCollateral, (dp, 100e18, address(this), address(this))));
        vm.expectRevert(stdError.arithmeticError);
        morpho.withdrawCollateral(dp, 100e18, address(this), address(this));
    }

    function testReentrancyLiquidateCannotDoubleLiquidate() public {
        loanToken.setBalance(address(this), 100e18);
        morpho.supply(dp, 100e18, 0, address(this), hex"");
        collateralToken.setBalance(BORROWER, 100e18);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(dp, 100e18, BORROWER, hex"");
        morpho.borrow(dp, 70e18, 0, BORROWER, BORROWER);
        vm.stopPrank();
        oracle.setPrice(ORACLE_PRICE_SCALE / 2); // unhealthy

        // Two *partial* liquidations would both be legitimate (the liquidator pays each time), so we target the
        // over-seize boundary: the reentrant call seizes the ENTIRE collateral (zeroing it and realizing bad debt
        // → borrowShares = 0), so the outer's precomputed burn underflows → atomic revert.
        _armAndExpect(abi.encodeCall(IMorphoBase.liquidate, (dp, BORROWER, 100e18, 0, hex"")));
        loanToken.setBalance(address(this), 100e18);
        vm.expectRevert(stdError.arithmeticError);
        morpho.liquidate(dp, BORROWER, 100e18, 0, hex"");
    }

    function testReentrancyAccrueInterestCannotOverWithdraw() public {
        loanToken.setBalance(address(this), 100e18);
        morpho.supply(dp, 100e18, 0, address(this), hex"");

        // Reenter a withdraw larger than the supply → underflow, even though entered via accrueInterest.
        _armAndExpect(abi.encodeCall(IMorphoBase.withdraw, (dp, 200e18, 0, address(this), address(this))));
        vm.expectRevert(stdError.arithmeticError);
        morpho.accrueInterest(dp);
    }

    function testReentrancyDeleverageCannotDoubleSpend() public {
        loanToken.setBalance(address(this), 100e18);
        morpho.supply(dp, 100e18, 0, address(this), hex"");
        collateralToken.setBalance(BORROWER, 200e18);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(dp, 200e18, BORROWER, hex"");
        morpho.borrow(dp, 100e18, 0, BORROWER, BORROWER); // free liquidity 0
        vm.stopPrank();

        // Reenter the same 0.7 slice: burned once, the outer's second burn underflows → atomic revert.
        uint256 slice = 70e18 * SharesMathLib.VIRTUAL_SHARES;
        _armAndExpect(abi.encodeCall(ILidoBlue.deleverage, (dp, slice, BORROWER, address(this), RECEIVER)));
        vm.expectRevert(stdError.arithmeticError);
        _lido().deleverage(dp, slice, BORROWER, address(this), RECEIVER);
    }

    function testReentrancyDeleverageWithinLimitsStaysConsistent() public {
        loanToken.setBalance(address(this), 100e18);
        morpho.supply(dp, 100e18, 0, address(this), hex"");
        collateralToken.setBalance(BORROWER, 200e18);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(dp, 200e18, BORROWER, hex"");
        morpho.borrow(dp, 100e18, 0, BORROWER, BORROWER);
        vm.stopPrank();

        // Two 0.3 slices (reentrant + outer) sum to 0.6 < the full balance: both apply, result == one 0.6 cut.
        uint256 slice = 30e18 * SharesMathLib.VIRTUAL_SHARES;
        _armAndExpect(abi.encodeCall(ILidoBlue.deleverage, (dp, slice, BORROWER, address(this), RECEIVER)));

        uint256 lenderSharesBefore = morpho.supplyShares(did, address(this));
        uint256 borrowSharesBefore = morpho.borrowShares(did, BORROWER);
        uint256 collateralBefore = morpho.collateral(did, BORROWER);

        _lido().deleverage(dp, slice, BORROWER, address(this), RECEIVER);

        assertEq(morpho.supplyShares(did, address(this)), lenderSharesBefore - 2 * slice, "lender shares: 2 slices");
        assertEq(
            morpho.borrowShares(did, BORROWER),
            borrowSharesBefore - 60e18 * SharesMathLib.VIRTUAL_SHARES,
            "borrow shares: 2 slices"
        );
        assertEq(morpho.collateral(did, BORROWER), collateralBefore - 60e18, "collateral: 2x30e18 seized");
        assertEq(collateralToken.balanceOf(RECEIVER), 60e18, "receiver got 2x30e18");
    }
}
