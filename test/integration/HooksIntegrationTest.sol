// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTestWithController.sol";

import {ILidoBlueMarketController} from "../../src/interfaces/ILidoBlueMarketController.sol";

contract HooksIntegrationTest is BaseTestWithController {
    using SharesMathLib for uint256;

    function _blocked() internal pure returns (bytes memory) {
        return bytes("controller: blocked");
    }

    function _supplyAndCollateral() internal {
        _supply(100e18);
        collateralToken.setBalance(BORROWER, 100e18);
        vm.prank(BORROWER);
        morpho.supplyCollateral(marketParams, 100e18, BORROWER, hex"");
    }

    function testHookSupplyFires() public {
        uint256 before = controller.hookCount();
        loanToken.setBalance(SUPPLIER, 10e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 10e18, 0, SUPPLIER, hex"");

        assertEq(controller.hookCount(), before + 1, "fired");
        assertEq(uint8(controller.lastEvent()), uint8(ILidoBlueMarketController.HookEvent.Supply), "event");
        ILidoBlueMarketController.SupplyHookData memory d =
            abi.decode(controller.lastData(), (ILidoBlueMarketController.SupplyHookData));
        assertEq(d.caller, SUPPLIER, "caller");
        assertEq(d.onBehalf, SUPPLIER, "onBehalf");
        assertEq(d.assets, 10e18, "assets");
        assertEq(d.shares, 10e18 * SharesMathLib.VIRTUAL_SHARES, "shares");
    }

    function testHookSupplyBlocks() public {
        controller.setRevertOn(ILidoBlueMarketController.HookEvent.Supply, true);
        loanToken.setBalance(SUPPLIER, 10e18);
        vm.prank(SUPPLIER);
        vm.expectRevert(_blocked());
        morpho.supply(marketParams, 10e18, 0, SUPPLIER, hex"");
    }

    function testHookWithdrawFires() public {
        loanToken.setBalance(SUPPLIER, 10e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 10e18, 0, SUPPLIER, hex"");

        uint256 before = controller.hookCount();
        vm.prank(SUPPLIER);
        morpho.withdraw(marketParams, 4e18, 0, SUPPLIER, SUPPLIER);

        assertEq(controller.hookCount(), before + 1, "fired");
        assertEq(uint8(controller.lastEvent()), uint8(ILidoBlueMarketController.HookEvent.Withdraw), "event");
        ILidoBlueMarketController.WithdrawHookData memory d =
            abi.decode(controller.lastData(), (ILidoBlueMarketController.WithdrawHookData));
        assertEq(d.caller, SUPPLIER, "caller");
        assertEq(d.onBehalf, SUPPLIER, "onBehalf");
        assertEq(d.receiver, SUPPLIER, "receiver");
        assertEq(d.assets, 4e18, "assets");
        assertEq(d.shares, 4e18 * SharesMathLib.VIRTUAL_SHARES, "shares");
    }

    function testHookWithdrawBlocks() public {
        loanToken.setBalance(SUPPLIER, 10e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 10e18, 0, SUPPLIER, hex"");

        controller.setRevertOn(ILidoBlueMarketController.HookEvent.Withdraw, true);
        vm.prank(SUPPLIER);
        vm.expectRevert(_blocked());
        morpho.withdraw(marketParams, 4e18, 0, SUPPLIER, SUPPLIER);
    }

    function testHookBorrowFires() public {
        _supplyAndCollateral();

        uint256 before = controller.hookCount();
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 50e18, 0, BORROWER, BORROWER);

        assertEq(controller.hookCount(), before + 1, "fired");
        assertEq(uint8(controller.lastEvent()), uint8(ILidoBlueMarketController.HookEvent.Borrow), "event");
        ILidoBlueMarketController.BorrowHookData memory d =
            abi.decode(controller.lastData(), (ILidoBlueMarketController.BorrowHookData));
        assertEq(d.caller, BORROWER, "caller");
        assertEq(d.onBehalf, BORROWER, "onBehalf");
        assertEq(d.receiver, BORROWER, "receiver");
        assertEq(d.assets, 50e18, "assets");
        assertEq(d.shares, 50e18 * SharesMathLib.VIRTUAL_SHARES, "shares");
    }

    function testHookBorrowBlocks() public {
        _supplyAndCollateral();
        controller.setRevertOn(ILidoBlueMarketController.HookEvent.Borrow, true);
        vm.prank(BORROWER);
        vm.expectRevert(_blocked());
        morpho.borrow(marketParams, 50e18, 0, BORROWER, BORROWER);
    }

    function testHookRepayFires() public {
        _supplyAndCollateral();
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 50e18, 0, BORROWER, BORROWER);

        uint256 before = controller.hookCount();
        vm.prank(BORROWER);
        morpho.repay(marketParams, 20e18, 0, BORROWER, hex"");

        assertEq(controller.hookCount(), before + 1, "fired");
        assertEq(uint8(controller.lastEvent()), uint8(ILidoBlueMarketController.HookEvent.Repay), "event");
        ILidoBlueMarketController.RepayHookData memory d =
            abi.decode(controller.lastData(), (ILidoBlueMarketController.RepayHookData));
        assertEq(d.caller, BORROWER, "caller");
        assertEq(d.onBehalf, BORROWER, "onBehalf");
        assertEq(d.assets, 20e18, "assets");
        assertEq(d.shares, 20e18 * SharesMathLib.VIRTUAL_SHARES, "shares");
    }

    function testHookRepayBlocks() public {
        _supplyAndCollateral();
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 50e18, 0, BORROWER, BORROWER);

        controller.setRevertOn(ILidoBlueMarketController.HookEvent.Repay, true);
        vm.prank(BORROWER);
        vm.expectRevert(_blocked());
        morpho.repay(marketParams, 20e18, 0, BORROWER, hex"");
    }

    function testHookSupplyCollateralFires() public {
        collateralToken.setBalance(BORROWER, 10e18);
        uint256 before = controller.hookCount();
        vm.prank(BORROWER);
        morpho.supplyCollateral(marketParams, 10e18, BORROWER, hex"");

        assertEq(controller.hookCount(), before + 1, "fired");
        assertEq(uint8(controller.lastEvent()), uint8(ILidoBlueMarketController.HookEvent.SupplyCollateral), "event");
        ILidoBlueMarketController.SupplyCollateralHookData memory d =
            abi.decode(controller.lastData(), (ILidoBlueMarketController.SupplyCollateralHookData));
        assertEq(d.caller, BORROWER, "caller");
        assertEq(d.onBehalf, BORROWER, "onBehalf");
        assertEq(d.assets, 10e18, "assets");
    }

    function testHookSupplyCollateralBlocks() public {
        controller.setRevertOn(ILidoBlueMarketController.HookEvent.SupplyCollateral, true);
        collateralToken.setBalance(BORROWER, 10e18);
        vm.prank(BORROWER);
        vm.expectRevert(_blocked());
        morpho.supplyCollateral(marketParams, 10e18, BORROWER, hex"");
    }

    function testHookWithdrawCollateralFires() public {
        collateralToken.setBalance(BORROWER, 10e18);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(marketParams, 10e18, BORROWER, hex"");
        uint256 before = controller.hookCount();
        morpho.withdrawCollateral(marketParams, 4e18, BORROWER, BORROWER);
        vm.stopPrank();

        assertEq(controller.hookCount(), before + 1, "fired");
        assertEq(uint8(controller.lastEvent()), uint8(ILidoBlueMarketController.HookEvent.WithdrawCollateral), "event");
        ILidoBlueMarketController.WithdrawCollateralHookData memory d =
            abi.decode(controller.lastData(), (ILidoBlueMarketController.WithdrawCollateralHookData));
        assertEq(d.caller, BORROWER, "caller");
        assertEq(d.onBehalf, BORROWER, "onBehalf");
        assertEq(d.receiver, BORROWER, "receiver");
        assertEq(d.assets, 4e18, "assets");
    }

    function testHookWithdrawCollateralBlocks() public {
        collateralToken.setBalance(BORROWER, 10e18);
        vm.prank(BORROWER);
        morpho.supplyCollateral(marketParams, 10e18, BORROWER, hex"");

        controller.setRevertOn(ILidoBlueMarketController.HookEvent.WithdrawCollateral, true);
        vm.prank(BORROWER);
        vm.expectRevert(_blocked());
        morpho.withdrawCollateral(marketParams, 4e18, BORROWER, BORROWER);
    }

    function _openUnhealthy() internal {
        _supply(100e18);
        collateralToken.setBalance(BORROWER, 100e18);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(marketParams, 100e18, BORROWER, hex"");
        morpho.borrow(marketParams, 70e18, 0, BORROWER, BORROWER);
        vm.stopPrank();
        oracle.setPrice(ORACLE_PRICE_SCALE / 2); // collateral worth 50e18 < 70e18 debt → unhealthy
        loanToken.setBalance(LIQUIDATOR, 100e18);
    }

    function testHookLiquidateFires() public {
        _openUnhealthy();

        uint256 before = controller.hookCount();
        vm.prank(LIQUIDATOR);
        morpho.liquidate(marketParams, BORROWER, 10e18, 0, hex"");

        assertEq(controller.hookCount(), before + 1, "fired");
        assertEq(uint8(controller.lastEvent()), uint8(ILidoBlueMarketController.HookEvent.Liquidate), "event");
        ILidoBlueMarketController.LiquidateHookData memory d =
            abi.decode(controller.lastData(), (ILidoBlueMarketController.LiquidateHookData));
        assertEq(d.caller, LIQUIDATOR, "caller");
        assertEq(d.borrower, BORROWER, "borrower");
        assertEq(d.seizedAssets, 10e18, "seizedAssets");
        assertGt(d.repaidShares, 0, "repaidShares resolved");
    }

    function testHookLiquidateBlocks() public {
        _openUnhealthy();
        controller.setRevertOn(ILidoBlueMarketController.HookEvent.Liquidate, true);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(_blocked());
        morpho.liquidate(marketParams, BORROWER, 10e18, 0, hex"");
    }

    function testHookAccrueInterestFires() public {
        uint256 before = controller.hookCount();
        morpho.accrueInterest(marketParams);

        assertEq(controller.hookCount(), before + 1, "fired");
        assertEq(uint8(controller.lastEvent()), uint8(ILidoBlueMarketController.HookEvent.AccrueInterest), "event");
        ILidoBlueMarketController.AccrueInterestHookData memory d =
            abi.decode(controller.lastData(), (ILidoBlueMarketController.AccrueInterestHookData));
        assertEq(d.caller, address(this), "caller");
    }

    function testHookAccrueInterestBlocks() public {
        controller.setRevertOn(ILidoBlueMarketController.HookEvent.AccrueInterest, true);
        vm.expectRevert(_blocked());
        morpho.accrueInterest(marketParams);
    }
}
