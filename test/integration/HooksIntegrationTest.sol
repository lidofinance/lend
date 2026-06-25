// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTestWithController.sol";

import {ILidoLend} from "../../src/interfaces/ILidoLend.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";

/// @notice Controller that records, per hook, what the core looked like at the instant the hook fired:
///         the market's `lastUpdate` and totals as seen mid-action. Used to pin the documented
///         interest-accrual ordering of each action relative to its hook.
contract ProbeController is ILidoLendMarketController {
    using MorphoLib for IMorpho;

    bytes32 internal immutable _marketId;
    IMorpho internal immutable core;

    mapping(uint8 => uint256) public seenLastUpdate;
    mapping(uint8 => uint256) public seenTotalSupplyAssets;
    mapping(uint8 => uint256) public seenTotalBorrowAssets;
    mapping(uint8 => bool) public fired;

    constructor(Id marketId_, IMorpho core_) {
        _marketId = Id.unwrap(marketId_);
        core = core_;
    }

    function marketId() external view returns (Id) {
        return Id.wrap(_marketId);
    }

    function on(Id id, HookEvent hookEvent, bytes calldata) external {
        uint8 e = uint8(hookEvent);
        fired[e] = true;
        seenLastUpdate[e] = core.lastUpdate(id);
        seenTotalSupplyAssets[e] = core.totalSupplyAssets(id);
        seenTotalBorrowAssets[e] = core.totalBorrowAssets(id);
    }
}

contract HooksIntegrationTest is BaseTestWithController {
    using SharesMathLib for uint256;
    using MorphoLib for IMorpho;
    using MarketParamsLib for MarketParams;

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
        assertEq(Id.unwrap(controller.lastId()), Id.unwrap(id), "market id");
        assertEq(uint8(controller.lastEvent()), uint8(ILidoLendMarketController.HookEvent.Supply), "event");
        ILidoLendMarketController.SupplyHookData memory d =
            abi.decode(controller.lastData(), (ILidoLendMarketController.SupplyHookData));
        assertEq(d.caller, SUPPLIER, "caller");
        assertEq(d.onBehalf, SUPPLIER, "onBehalf");
        assertEq(d.assets, 10e18, "assets");
        assertEq(d.shares, 10e18 * SharesMathLib.VIRTUAL_SHARES, "shares");
    }

    function testHookSupplyBlocks() public {
        controller.setRevertOn(ILidoLendMarketController.HookEvent.Supply, true);
        loanToken.setBalance(SUPPLIER, 10e18);

        uint256 shares = morpho.supplyShares(id, SUPPLIER);
        uint256 tSA = morpho.totalSupplyAssets(id);
        uint256 bal = loanToken.balanceOf(SUPPLIER);
        uint256 morphoBal = loanToken.balanceOf(address(morpho));

        vm.prank(SUPPLIER);
        vm.expectRevert(_blocked());
        morpho.supply(marketParams, 10e18, 0, SUPPLIER, hex"");

        assertEq(morpho.supplyShares(id, SUPPLIER), shares, "supply shares unchanged");
        assertEq(morpho.totalSupplyAssets(id), tSA, "total supply assets unchanged");
        assertEq(loanToken.balanceOf(SUPPLIER), bal, "supplier balance unchanged");
        assertEq(loanToken.balanceOf(address(morpho)), morphoBal, "morpho balance unchanged");
    }

    function testHookWithdrawFires() public {
        loanToken.setBalance(SUPPLIER, 10e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 10e18, 0, SUPPLIER, hex"");

        uint256 before = controller.hookCount();
        vm.prank(SUPPLIER);
        morpho.withdraw(marketParams, 4e18, 0, SUPPLIER, SUPPLIER);

        assertEq(controller.hookCount(), before + 1, "fired");
        assertEq(Id.unwrap(controller.lastId()), Id.unwrap(id), "market id");
        assertEq(uint8(controller.lastEvent()), uint8(ILidoLendMarketController.HookEvent.Withdraw), "event");
        ILidoLendMarketController.WithdrawHookData memory d =
            abi.decode(controller.lastData(), (ILidoLendMarketController.WithdrawHookData));
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

        controller.setRevertOn(ILidoLendMarketController.HookEvent.Withdraw, true);

        uint256 shares = morpho.supplyShares(id, SUPPLIER);
        uint256 tSA = morpho.totalSupplyAssets(id);
        uint256 bal = loanToken.balanceOf(SUPPLIER);
        uint256 morphoBal = loanToken.balanceOf(address(morpho));

        vm.prank(SUPPLIER);
        vm.expectRevert(_blocked());
        morpho.withdraw(marketParams, 4e18, 0, SUPPLIER, SUPPLIER);

        assertEq(morpho.supplyShares(id, SUPPLIER), shares, "supply shares unchanged");
        assertEq(morpho.totalSupplyAssets(id), tSA, "total supply assets unchanged");
        assertEq(loanToken.balanceOf(SUPPLIER), bal, "supplier balance unchanged");
        assertEq(loanToken.balanceOf(address(morpho)), morphoBal, "morpho balance unchanged");
    }

    function testHookBorrowFires() public {
        _supplyAndCollateral();

        uint256 before = controller.hookCount();
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 50e18, 0, BORROWER, BORROWER);

        assertEq(controller.hookCount(), before + 1, "fired");
        assertEq(Id.unwrap(controller.lastId()), Id.unwrap(id), "market id");
        assertEq(uint8(controller.lastEvent()), uint8(ILidoLendMarketController.HookEvent.Borrow), "event");
        ILidoLendMarketController.BorrowHookData memory d =
            abi.decode(controller.lastData(), (ILidoLendMarketController.BorrowHookData));
        assertEq(d.caller, BORROWER, "caller");
        assertEq(d.onBehalf, BORROWER, "onBehalf");
        assertEq(d.receiver, BORROWER, "receiver");
        assertEq(d.assets, 50e18, "assets");
        assertEq(d.shares, 50e18 * SharesMathLib.VIRTUAL_SHARES, "shares");
    }

    function testHookBorrowBlocks() public {
        _supplyAndCollateral();
        controller.setRevertOn(ILidoLendMarketController.HookEvent.Borrow, true);

        uint256 shares = morpho.borrowShares(id, BORROWER);
        uint256 tBA = morpho.totalBorrowAssets(id);
        uint256 bal = loanToken.balanceOf(BORROWER);
        uint256 morphoBal = loanToken.balanceOf(address(morpho));

        vm.prank(BORROWER);
        vm.expectRevert(_blocked());
        morpho.borrow(marketParams, 50e18, 0, BORROWER, BORROWER);

        assertEq(morpho.borrowShares(id, BORROWER), shares, "borrow shares unchanged");
        assertEq(morpho.totalBorrowAssets(id), tBA, "total borrow assets unchanged");
        assertEq(loanToken.balanceOf(BORROWER), bal, "borrower balance unchanged");
        assertEq(loanToken.balanceOf(address(morpho)), morphoBal, "morpho balance unchanged");
    }

    function testHookRepayFires() public {
        _supplyAndCollateral();
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 50e18, 0, BORROWER, BORROWER);

        uint256 before = controller.hookCount();
        vm.prank(BORROWER);
        morpho.repay(marketParams, 20e18, 0, BORROWER, hex"");

        assertEq(controller.hookCount(), before + 1, "fired");
        assertEq(Id.unwrap(controller.lastId()), Id.unwrap(id), "market id");
        assertEq(uint8(controller.lastEvent()), uint8(ILidoLendMarketController.HookEvent.Repay), "event");
        ILidoLendMarketController.RepayHookData memory d =
            abi.decode(controller.lastData(), (ILidoLendMarketController.RepayHookData));
        assertEq(d.caller, BORROWER, "caller");
        assertEq(d.onBehalf, BORROWER, "onBehalf");
        assertEq(d.assets, 20e18, "assets");
        assertEq(d.shares, 20e18 * SharesMathLib.VIRTUAL_SHARES, "shares");
    }

    function testHookRepayBlocks() public {
        _supplyAndCollateral();
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 50e18, 0, BORROWER, BORROWER);

        controller.setRevertOn(ILidoLendMarketController.HookEvent.Repay, true);

        uint256 shares = morpho.borrowShares(id, BORROWER);
        uint256 tBA = morpho.totalBorrowAssets(id);
        uint256 bal = loanToken.balanceOf(BORROWER);
        uint256 morphoBal = loanToken.balanceOf(address(morpho));

        vm.prank(BORROWER);
        vm.expectRevert(_blocked());
        morpho.repay(marketParams, 20e18, 0, BORROWER, hex"");

        assertEq(morpho.borrowShares(id, BORROWER), shares, "borrow shares unchanged");
        assertEq(morpho.totalBorrowAssets(id), tBA, "total borrow assets unchanged");
        assertEq(loanToken.balanceOf(BORROWER), bal, "borrower balance unchanged");
        assertEq(loanToken.balanceOf(address(morpho)), morphoBal, "morpho balance unchanged");
    }

    function testHookSupplyCollateralFires() public {
        collateralToken.setBalance(BORROWER, 10e18);
        uint256 before = controller.hookCount();
        vm.prank(BORROWER);
        morpho.supplyCollateral(marketParams, 10e18, BORROWER, hex"");

        assertEq(controller.hookCount(), before + 1, "fired");
        assertEq(Id.unwrap(controller.lastId()), Id.unwrap(id), "market id");
        assertEq(uint8(controller.lastEvent()), uint8(ILidoLendMarketController.HookEvent.SupplyCollateral), "event");
        ILidoLendMarketController.SupplyCollateralHookData memory d =
            abi.decode(controller.lastData(), (ILidoLendMarketController.SupplyCollateralHookData));
        assertEq(d.caller, BORROWER, "caller");
        assertEq(d.onBehalf, BORROWER, "onBehalf");
        assertEq(d.assets, 10e18, "assets");
    }

    function testHookSupplyCollateralBlocks() public {
        controller.setRevertOn(ILidoLendMarketController.HookEvent.SupplyCollateral, true);
        collateralToken.setBalance(BORROWER, 10e18);

        uint256 collat = morpho.collateral(id, BORROWER);
        uint256 bal = collateralToken.balanceOf(BORROWER);
        uint256 morphoBal = collateralToken.balanceOf(address(morpho));

        vm.prank(BORROWER);
        vm.expectRevert(_blocked());
        morpho.supplyCollateral(marketParams, 10e18, BORROWER, hex"");

        assertEq(morpho.collateral(id, BORROWER), collat, "collateral unchanged");
        assertEq(collateralToken.balanceOf(BORROWER), bal, "borrower balance unchanged");
        assertEq(collateralToken.balanceOf(address(morpho)), morphoBal, "morpho balance unchanged");
    }

    function testHookWithdrawCollateralFires() public {
        collateralToken.setBalance(BORROWER, 10e18);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(marketParams, 10e18, BORROWER, hex"");
        uint256 before = controller.hookCount();
        morpho.withdrawCollateral(marketParams, 4e18, BORROWER, BORROWER);
        vm.stopPrank();

        assertEq(controller.hookCount(), before + 1, "fired");
        assertEq(Id.unwrap(controller.lastId()), Id.unwrap(id), "market id");
        assertEq(uint8(controller.lastEvent()), uint8(ILidoLendMarketController.HookEvent.WithdrawCollateral), "event");
        ILidoLendMarketController.WithdrawCollateralHookData memory d =
            abi.decode(controller.lastData(), (ILidoLendMarketController.WithdrawCollateralHookData));
        assertEq(d.caller, BORROWER, "caller");
        assertEq(d.onBehalf, BORROWER, "onBehalf");
        assertEq(d.receiver, BORROWER, "receiver");
        assertEq(d.assets, 4e18, "assets");
    }

    function testHookWithdrawCollateralBlocks() public {
        collateralToken.setBalance(BORROWER, 10e18);
        vm.prank(BORROWER);
        morpho.supplyCollateral(marketParams, 10e18, BORROWER, hex"");

        controller.setRevertOn(ILidoLendMarketController.HookEvent.WithdrawCollateral, true);

        uint256 collat = morpho.collateral(id, BORROWER);
        uint256 bal = collateralToken.balanceOf(BORROWER);
        uint256 morphoBal = collateralToken.balanceOf(address(morpho));

        vm.prank(BORROWER);
        vm.expectRevert(_blocked());
        morpho.withdrawCollateral(marketParams, 4e18, BORROWER, BORROWER);

        assertEq(morpho.collateral(id, BORROWER), collat, "collateral unchanged");
        assertEq(collateralToken.balanceOf(BORROWER), bal, "borrower balance unchanged");
        assertEq(collateralToken.balanceOf(address(morpho)), morphoBal, "morpho balance unchanged");
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
        assertEq(Id.unwrap(controller.lastId()), Id.unwrap(id), "market id");
        assertEq(uint8(controller.lastEvent()), uint8(ILidoLendMarketController.HookEvent.Liquidate), "event");
        ILidoLendMarketController.LiquidateHookData memory d =
            abi.decode(controller.lastData(), (ILidoLendMarketController.LiquidateHookData));
        assertEq(d.caller, LIQUIDATOR, "caller");
        assertEq(d.borrower, BORROWER, "borrower");
        assertEq(d.seizedAssets, 10e18, "seizedAssets");
        assertGt(d.repaidAssets, 0, "repaidAssets resolved");
        assertGt(d.repaidShares, 0, "repaidShares resolved");
    }

    function testHookLiquidateBlocks() public {
        _openUnhealthy();
        controller.setRevertOn(ILidoLendMarketController.HookEvent.Liquidate, true);

        uint256 shares = morpho.borrowShares(id, BORROWER);
        uint256 collat = morpho.collateral(id, BORROWER);
        uint256 tBA = morpho.totalBorrowAssets(id);
        uint256 loanBal = loanToken.balanceOf(LIQUIDATOR);
        uint256 collatBal = collateralToken.balanceOf(LIQUIDATOR);

        vm.prank(LIQUIDATOR);
        vm.expectRevert(_blocked());
        morpho.liquidate(marketParams, BORROWER, 10e18, 0, hex"");

        assertEq(morpho.borrowShares(id, BORROWER), shares, "borrow shares unchanged");
        assertEq(morpho.collateral(id, BORROWER), collat, "collateral unchanged");
        assertEq(morpho.totalBorrowAssets(id), tBA, "total borrow assets unchanged");
        assertEq(loanToken.balanceOf(LIQUIDATOR), loanBal, "liquidator loan balance unchanged");
        assertEq(collateralToken.balanceOf(LIQUIDATOR), collatBal, "liquidator collateral balance unchanged");
    }

    function testHookAccrueInterestFires() public {
        uint256 before = controller.hookCount();
        morpho.accrueInterest(marketParams);

        assertEq(controller.hookCount(), before + 1, "fired");
        assertEq(Id.unwrap(controller.lastId()), Id.unwrap(id), "market id");
        assertEq(uint8(controller.lastEvent()), uint8(ILidoLendMarketController.HookEvent.AccrueInterest), "event");
        ILidoLendMarketController.AccrueInterestHookData memory d =
            abi.decode(controller.lastData(), (ILidoLendMarketController.AccrueInterestHookData));
        assertEq(d.caller, address(this), "caller");
    }

    function testHookAccrueInterestBlocks() public {
        controller.setRevertOn(ILidoLendMarketController.HookEvent.AccrueInterest, true);
        vm.warp(block.timestamp + 1 days);

        uint256 last = morpho.lastUpdate(id);
        uint256 tSA = morpho.totalSupplyAssets(id);
        uint256 tBA = morpho.totalBorrowAssets(id);

        vm.expectRevert(_blocked());
        morpho.accrueInterest(marketParams);

        assertEq(morpho.lastUpdate(id), last, "lastUpdate unchanged");
        assertEq(morpho.totalSupplyAssets(id), tSA, "total supply assets unchanged");
        assertEq(morpho.totalBorrowAssets(id), tBA, "total borrow assets unchanged");
    }

    /* HOOK TIMING vs INTEREST ACCRUAL (live IRM) */

    uint8 internal constant SUPPLY_COLLATERAL = uint8(ILidoLendMarketController.HookEvent.SupplyCollateral);
    uint8 internal constant WITHDRAW_COLLATERAL = uint8(ILidoLendMarketController.HookEvent.WithdrawCollateral);
    uint8 internal constant ACCRUE_INTEREST = uint8(ILidoLendMarketController.HookEvent.AccrueInterest);

    MarketParams internal liveParams;
    Id internal liveId;
    ProbeController internal probe;

    function _setUpLiveMarket() internal {
        liveParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.55 ether // distinct id from the inherited (0.8) and base markets
        });
        liveId = liveParams.id();
        probe = new ProbeController(liveId, morpho);
        vm.prank(OWNER);
        ILidoLend(address(morpho)).createMarket(liveParams, address(probe), true);

        uint256 supplied = 100e18;
        loanToken.setBalance(address(this), supplied);
        morpho.supply(liveParams, supplied, 0, address(this), hex"");
        collateralToken.setBalance(BORROWER, 1000e18);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(liveParams, 1000e18, BORROWER, hex""); // ample headroom so a year of interest stays
        // healthy
        morpho.borrow(liveParams, 80e18, 0, BORROWER, BORROWER); // 80% utilization → non-trivial rate
        vm.stopPrank();
    }

    // supplyCollateral does NOT accrue before its hook → the hook sees a STALE lastUpdate and un-accrued totals.
    function testHookSupplyCollateralDoesNotAccrueBeforeHook() public {
        _setUpLiveMarket();
        uint256 tBABefore = morpho.totalBorrowAssets(liveId);

        vm.warp(block.timestamp + 365 days);
        collateralToken.setBalance(BORROWER, 1e18);
        vm.prank(BORROWER);
        morpho.supplyCollateral(liveParams, 1e18, BORROWER, hex"");

        assertTrue(probe.fired(SUPPLY_COLLATERAL), "hook fired");
        assertLt(probe.seenLastUpdate(SUPPLY_COLLATERAL), block.timestamp, "hook saw stale lastUpdate");
        assertEq(probe.seenTotalBorrowAssets(SUPPLY_COLLATERAL), tBABefore, "hook saw un-accrued borrow assets");
        // supplyCollateral never accrues, so totals stay un-accrued through the whole call too.
        assertEq(morpho.totalBorrowAssets(liveId), tBABefore, "supplyCollateral left interest un-accrued");
        assertEq(morpho.lastUpdate(liveId), probe.seenLastUpdate(SUPPLY_COLLATERAL), "lastUpdate never advanced");
    }

    // withdrawCollateral DOES accrue before its hook → the hook sees a FRESH lastUpdate and accrued totals.
    function testHookWithdrawCollateralAccruesBeforeHook() public {
        _setUpLiveMarket();
        uint256 tBABefore = morpho.totalBorrowAssets(liveId);

        vm.warp(block.timestamp + 365 days);
        vm.prank(BORROWER);
        morpho.withdrawCollateral(liveParams, 1e18, BORROWER, BORROWER);

        assertTrue(probe.fired(WITHDRAW_COLLATERAL), "hook fired");
        assertEq(probe.seenLastUpdate(WITHDRAW_COLLATERAL), block.timestamp, "hook saw fresh lastUpdate");
        assertGt(probe.seenTotalBorrowAssets(WITHDRAW_COLLATERAL), tBABefore, "hook saw accrued borrow assets");
    }

    // accrueInterest fires its hook BEFORE accruing → the hook sees the PRE-accrual lastUpdate and un-accrued totals.
    function testHookAccrueInterestFiresBeforeAccruing() public {
        _setUpLiveMarket();
        uint256 lastBefore = morpho.lastUpdate(liveId);
        uint256 tBABefore = morpho.totalBorrowAssets(liveId);

        vm.warp(block.timestamp + 365 days);
        morpho.accrueInterest(liveParams);

        assertTrue(probe.fired(ACCRUE_INTEREST), "hook fired");
        assertEq(probe.seenLastUpdate(ACCRUE_INTEREST), lastBefore, "hook saw pre-accrual lastUpdate");
        assertLt(probe.seenLastUpdate(ACCRUE_INTEREST), block.timestamp, "pre-accrual lastUpdate is stale");
        assertEq(probe.seenTotalBorrowAssets(ACCRUE_INTEREST), tBABefore, "hook saw un-accrued borrow assets");
        assertGt(morpho.totalBorrowAssets(liveId), tBABefore, "interest accrued after the hook");
    }
}
