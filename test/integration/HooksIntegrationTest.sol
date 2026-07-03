// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTestWithController.sol";

import {ILidoLend} from "../../src/interfaces/ILidoLend.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";

/// @notice Controller that records, per hook, what the core looked like at the instant the hook fired:
///         the market's `lastUpdate`, its totals, and the `subject` position as seen mid-action. Used to
///         pin the interest-accrual ordering of each action relative to its hook, and that hooks observe
///         the pre-action state.
contract ProbeController is ILidoLendMarketController {
    using MorphoLib for IMorpho;

    Id internal immutable _marketId;
    IMorpho internal immutable core;
    address internal immutable subject;

    mapping(HookEvent => uint256) public seenLastUpdate;
    mapping(HookEvent => uint256) public seenTotalSupplyAssets;
    mapping(HookEvent => uint256) public seenTotalBorrowAssets;
    mapping(HookEvent => uint256) public seenCollateral;
    mapping(HookEvent => uint256) public seenBorrowShares;
    mapping(HookEvent => bool) public fired;

    constructor(Id marketId_, IMorpho core_, address subject_) {
        _marketId = marketId_;
        core = core_;
        subject = subject_;
    }

    function marketId() external view returns (Id) {
        return _marketId;
    }

    function on(Id id, HookEvent hookEvent, bytes calldata) external {
        fired[hookEvent] = true;
        seenLastUpdate[hookEvent] = core.lastUpdate(id);
        seenTotalSupplyAssets[hookEvent] = core.totalSupplyAssets(id);
        seenTotalBorrowAssets[hookEvent] = core.totalBorrowAssets(id);
        seenCollateral[hookEvent] = core.collateral(id, subject);
        seenBorrowShares[hookEvent] = core.borrowShares(id, subject);
    }
}

/// @dev Each hooked action gets one test covering both sides of the hook on a shared fixture: a
///      controller veto leaves every touched slot and balance unchanged (the hook fires before state
///      writes), and the unblocked action dispatches the hook with the resolved payload. The accrual
///      ordering of each hook relative to `_accrueInterest` is pinned separately on a live-IRM market.
contract HooksIntegrationTest is BaseTestWithController {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using MarketParamsLib for MarketParams;

    ILidoLendMarketController.HookEvent internal constant SUPPLY_COLLATERAL =
    ILidoLendMarketController.HookEvent.SupplyCollateral;
    ILidoLendMarketController.HookEvent internal constant WITHDRAW_COLLATERAL =
    ILidoLendMarketController.HookEvent.WithdrawCollateral;
    ILidoLendMarketController.HookEvent internal constant ACCRUE_INTEREST =
    ILidoLendMarketController.HookEvent.AccrueInterest;

    MarketParams internal liveParams;
    Id internal liveId;
    ProbeController internal probe;

    /* HELPERS */

    function _blocked() internal pure returns (bytes memory) {
        return bytes("blocked by controller");
    }

    /// @dev Asserts the last dispatch hit this market with `hookEvent`, `count` dispatches ago at zero.
    function _assertDispatched(uint256 countBefore, ILidoLendMarketController.HookEvent hookEvent) internal {
        assertEq(controller.hookCount(), countBefore + 1, "fired");
        assertEq(Id.unwrap(controller.lastId()), Id.unwrap(id), "market id");
        assertEq(uint8(controller.lastEvent()), uint8(hookEvent), "event");
    }

    /* FIXTURES */

    function _supplyAndCollateral() internal {
        _supply(100e18);
        collateralToken.setBalance(BORROWER, 100e18);
        vm.prank(BORROWER);
        morpho.supplyCollateral(marketParams, 100e18, BORROWER, hex"");
    }

    function _openUnhealthy() internal {
        _openPosition(100e18, 100e18, 70e18);
        oracle.setPrice(ORACLE_PRICE_SCALE / 2); // collateral worth 50e18 < 70e18 debt → unhealthy
        loanToken.setBalance(LIQUIDATOR, 100e18);
    }

    function _setUpLiveMarket() internal {
        liveParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.55 ether // distinct id from the inherited (0.8) and base markets
        });
        liveId = liveParams.id();
        probe = new ProbeController(liveId, morpho, BORROWER);
        vm.prank(OWNER);
        ILidoLend(address(morpho)).createMarket(liveParams, address(probe), true);

        uint256 supplied = 100e18;
        loanToken.setBalance(address(this), supplied);
        morpho.supply(liveParams, supplied, 0, address(this), hex"");
        // Ample collateral headroom keeps a year of interest healthy; 80% utilization → non-trivial rate.
        _borrowAs(liveParams, BORROWER, 1000e18, 80e18);
    }

    /* FIRING, PAYLOAD, AND VETO */

    function testHookSupply() public {
        loanToken.setBalance(SUPPLIER, 10e18);

        controller.setRevertOn(ILidoLendMarketController.HookEvent.Supply, true);
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

        controller.setRevertOn(ILidoLendMarketController.HookEvent.Supply, false);
        uint256 count = controller.hookCount();
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 10e18, 0, SUPPLIER, hex"");

        _assertDispatched(count, ILidoLendMarketController.HookEvent.Supply);
        ILidoLendMarketController.SupplyHookData memory d =
            abi.decode(controller.lastData(), (ILidoLendMarketController.SupplyHookData));
        assertEq(d.caller, SUPPLIER, "caller");
        assertEq(d.onBehalf, SUPPLIER, "onBehalf");
        assertEq(d.assets, 10e18, "assets");
        assertEq(d.shares, 10e18 * SharesMathLib.VIRTUAL_SHARES, "shares");
    }

    function testHookWithdraw() public {
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

        controller.setRevertOn(ILidoLendMarketController.HookEvent.Withdraw, false);
        uint256 count = controller.hookCount();
        vm.prank(SUPPLIER);
        morpho.withdraw(marketParams, 4e18, 0, SUPPLIER, SUPPLIER);

        _assertDispatched(count, ILidoLendMarketController.HookEvent.Withdraw);
        ILidoLendMarketController.WithdrawHookData memory d =
            abi.decode(controller.lastData(), (ILidoLendMarketController.WithdrawHookData));
        assertEq(d.caller, SUPPLIER, "caller");
        assertEq(d.onBehalf, SUPPLIER, "onBehalf");
        assertEq(d.receiver, SUPPLIER, "receiver");
        assertEq(d.assets, 4e18, "assets");
        assertEq(d.shares, 4e18 * SharesMathLib.VIRTUAL_SHARES, "shares");
    }

    function testHookBorrow() public {
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

        controller.setRevertOn(ILidoLendMarketController.HookEvent.Borrow, false);
        uint256 count = controller.hookCount();
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 50e18, 0, BORROWER, BORROWER);

        _assertDispatched(count, ILidoLendMarketController.HookEvent.Borrow);
        ILidoLendMarketController.BorrowHookData memory d =
            abi.decode(controller.lastData(), (ILidoLendMarketController.BorrowHookData));
        assertEq(d.caller, BORROWER, "caller");
        assertEq(d.onBehalf, BORROWER, "onBehalf");
        assertEq(d.receiver, BORROWER, "receiver");
        assertEq(d.assets, 50e18, "assets");
        assertEq(d.shares, 50e18 * SharesMathLib.VIRTUAL_SHARES, "shares");
    }

    function testHookRepay() public {
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

        controller.setRevertOn(ILidoLendMarketController.HookEvent.Repay, false);
        uint256 count = controller.hookCount();
        vm.prank(BORROWER);
        morpho.repay(marketParams, 20e18, 0, BORROWER, hex"");

        _assertDispatched(count, ILidoLendMarketController.HookEvent.Repay);
        ILidoLendMarketController.RepayHookData memory d =
            abi.decode(controller.lastData(), (ILidoLendMarketController.RepayHookData));
        assertEq(d.caller, BORROWER, "caller");
        assertEq(d.onBehalf, BORROWER, "onBehalf");
        assertEq(d.assets, 20e18, "assets");
        assertEq(d.shares, 20e18 * SharesMathLib.VIRTUAL_SHARES, "shares");
    }

    function testHookSupplyCollateral() public {
        collateralToken.setBalance(BORROWER, 10e18);

        controller.setRevertOn(SUPPLY_COLLATERAL, true);
        uint256 collat = morpho.collateral(id, BORROWER);
        uint256 bal = collateralToken.balanceOf(BORROWER);
        uint256 morphoBal = collateralToken.balanceOf(address(morpho));

        vm.prank(BORROWER);
        vm.expectRevert(_blocked());
        morpho.supplyCollateral(marketParams, 10e18, BORROWER, hex"");

        assertEq(morpho.collateral(id, BORROWER), collat, "collateral unchanged");
        assertEq(collateralToken.balanceOf(BORROWER), bal, "borrower balance unchanged");
        assertEq(collateralToken.balanceOf(address(morpho)), morphoBal, "morpho balance unchanged");

        controller.setRevertOn(SUPPLY_COLLATERAL, false);
        uint256 count = controller.hookCount();
        vm.prank(BORROWER);
        morpho.supplyCollateral(marketParams, 10e18, BORROWER, hex"");

        _assertDispatched(count, SUPPLY_COLLATERAL);
        ILidoLendMarketController.SupplyCollateralHookData memory d =
            abi.decode(controller.lastData(), (ILidoLendMarketController.SupplyCollateralHookData));
        assertEq(d.caller, BORROWER, "caller");
        assertEq(d.onBehalf, BORROWER, "onBehalf");
        assertEq(d.assets, 10e18, "assets");
    }

    function testHookWithdrawCollateral() public {
        collateralToken.setBalance(BORROWER, 10e18);
        vm.prank(BORROWER);
        morpho.supplyCollateral(marketParams, 10e18, BORROWER, hex"");

        controller.setRevertOn(WITHDRAW_COLLATERAL, true);
        uint256 collat = morpho.collateral(id, BORROWER);
        uint256 bal = collateralToken.balanceOf(BORROWER);
        uint256 morphoBal = collateralToken.balanceOf(address(morpho));

        vm.prank(BORROWER);
        vm.expectRevert(_blocked());
        morpho.withdrawCollateral(marketParams, 4e18, BORROWER, BORROWER);

        assertEq(morpho.collateral(id, BORROWER), collat, "collateral unchanged");
        assertEq(collateralToken.balanceOf(BORROWER), bal, "borrower balance unchanged");
        assertEq(collateralToken.balanceOf(address(morpho)), morphoBal, "morpho balance unchanged");

        controller.setRevertOn(WITHDRAW_COLLATERAL, false);
        uint256 count = controller.hookCount();
        vm.prank(BORROWER);
        morpho.withdrawCollateral(marketParams, 4e18, BORROWER, BORROWER);

        _assertDispatched(count, WITHDRAW_COLLATERAL);
        ILidoLendMarketController.WithdrawCollateralHookData memory d =
            abi.decode(controller.lastData(), (ILidoLendMarketController.WithdrawCollateralHookData));
        assertEq(d.caller, BORROWER, "caller");
        assertEq(d.onBehalf, BORROWER, "onBehalf");
        assertEq(d.receiver, BORROWER, "receiver");
        assertEq(d.assets, 4e18, "assets");
    }

    function testHookLiquidate() public {
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

        // The payload carries the values the core resolved from the seized-assets input.
        uint256 expectedRepaidShares = uint256(10e18).mulDivUp(oracle.price(), ORACLE_PRICE_SCALE)
            .wDivUp(_liquidationIncentiveFactor(marketParams.lltv)).toSharesUp(tBA, morpho.totalBorrowShares(id));
        uint256 expectedRepaidAssets = expectedRepaidShares.toAssetsUp(tBA, morpho.totalBorrowShares(id));

        controller.setRevertOn(ILidoLendMarketController.HookEvent.Liquidate, false);
        uint256 count = controller.hookCount();
        vm.prank(LIQUIDATOR);
        morpho.liquidate(marketParams, BORROWER, 10e18, 0, hex"");

        _assertDispatched(count, ILidoLendMarketController.HookEvent.Liquidate);
        ILidoLendMarketController.LiquidateHookData memory d =
            abi.decode(controller.lastData(), (ILidoLendMarketController.LiquidateHookData));
        assertEq(d.caller, LIQUIDATOR, "caller");
        assertEq(d.borrower, BORROWER, "borrower");
        assertEq(d.seizedAssets, 10e18, "seizedAssets");
        assertEq(d.repaidAssets, expectedRepaidAssets, "repaidAssets resolved");
        assertEq(d.repaidShares, expectedRepaidShares, "repaidShares resolved");
    }

    function testHookAccrueInterest() public {
        controller.setRevertOn(ACCRUE_INTEREST, true);
        vm.warp(block.timestamp + 1 days);
        uint256 last = morpho.lastUpdate(id);
        uint256 tSA = morpho.totalSupplyAssets(id);
        uint256 tBA = morpho.totalBorrowAssets(id);

        vm.expectRevert(_blocked());
        morpho.accrueInterest(marketParams);

        assertEq(morpho.lastUpdate(id), last, "lastUpdate unchanged");
        assertEq(morpho.totalSupplyAssets(id), tSA, "total supply assets unchanged");
        assertEq(morpho.totalBorrowAssets(id), tBA, "total borrow assets unchanged");

        controller.setRevertOn(ACCRUE_INTEREST, false);
        uint256 count = controller.hookCount();
        morpho.accrueInterest(marketParams);

        _assertDispatched(count, ACCRUE_INTEREST);
        ILidoLendMarketController.AccrueInterestHookData memory d =
            abi.decode(controller.lastData(), (ILidoLendMarketController.AccrueInterestHookData));
        assertEq(d.caller, address(this), "caller");
    }

    /* HOOK EVENT ABI */

    // Controllers decode the hook payload per `HookEvent`, so the enum's numeric values are an ABI
    // surface: inserting or reordering members would silently re-route payload decoding downstream.
    function testHookEventEnumValuesAreStable() public {
        assertEq(uint8(ILidoLendMarketController.HookEvent.Supply), 0);
        assertEq(uint8(ILidoLendMarketController.HookEvent.Withdraw), 1);
        assertEq(uint8(ILidoLendMarketController.HookEvent.Borrow), 2);
        assertEq(uint8(ILidoLendMarketController.HookEvent.Repay), 3);
        assertEq(uint8(ILidoLendMarketController.HookEvent.SupplyCollateral), 4);
        assertEq(uint8(ILidoLendMarketController.HookEvent.WithdrawCollateral), 5);
        assertEq(uint8(ILidoLendMarketController.HookEvent.Liquidate), 6);
        assertEq(uint8(ILidoLendMarketController.HookEvent.AccrueInterest), 7);
        assertEq(uint8(ILidoLendMarketController.HookEvent.Settle), 8);
    }

    /* ACCRUAL ORDERING AND HOOK PRE-STATE (live IRM) */

    // supplyCollateral does NOT accrue before its hook → the hook sees a STALE lastUpdate and un-accrued totals.
    function testHookSupplyCollateralDoesNotAccrueBeforeHook() public {
        _setUpLiveMarket();
        uint256 lastBefore = morpho.lastUpdate(liveId);
        uint256 tBABefore = morpho.totalBorrowAssets(liveId);
        uint256 collateralBefore = morpho.collateral(liveId, BORROWER);

        vm.warp(block.timestamp + 365 days);
        collateralToken.setBalance(BORROWER, 1e18);
        vm.prank(BORROWER);
        morpho.supplyCollateral(liveParams, 1e18, BORROWER, hex"");

        assertTrue(probe.fired(SUPPLY_COLLATERAL), "hook fired");
        assertEq(probe.seenLastUpdate(SUPPLY_COLLATERAL), lastBefore, "hook saw the stale lastUpdate");
        assertEq(probe.seenTotalBorrowAssets(SUPPLY_COLLATERAL), tBABefore, "hook saw un-accrued borrow assets");
        assertEq(probe.seenCollateral(SUPPLY_COLLATERAL), collateralBefore, "hook saw the pre-deposit collateral");
        // supplyCollateral never accrues, so totals stay un-accrued through the whole call too.
        assertEq(morpho.totalBorrowAssets(liveId), tBABefore, "supplyCollateral left interest un-accrued");
        assertEq(morpho.lastUpdate(liveId), lastBefore, "lastUpdate never advanced");
    }

    // withdrawCollateral DOES accrue before its hook → the hook sees a FRESH lastUpdate and accrued totals.
    function testHookWithdrawCollateralAccruesBeforeHook() public {
        _setUpLiveMarket();

        vm.warp(block.timestamp + 365 days);
        (,, uint256 expTBA,) = morpho.expectedMarketBalances(liveParams);
        vm.prank(BORROWER);
        morpho.withdrawCollateral(liveParams, 1e18, BORROWER, BORROWER);

        assertTrue(probe.fired(WITHDRAW_COLLATERAL), "hook fired");
        assertEq(probe.seenLastUpdate(WITHDRAW_COLLATERAL), block.timestamp, "hook saw fresh lastUpdate");
        assertEq(probe.seenTotalBorrowAssets(WITHDRAW_COLLATERAL), expTBA, "hook saw the accrued borrow assets");
        assertEq(
            probe.seenCollateral(WITHDRAW_COLLATERAL),
            morpho.collateral(liveId, BORROWER) + 1e18,
            "hook saw the pre-withdraw collateral"
        );
    }

    // accrueInterest fires its hook BEFORE accruing → the hook sees the PRE-accrual lastUpdate and un-accrued totals.
    function testHookAccrueInterestFiresBeforeAccruing() public {
        _setUpLiveMarket();
        uint256 lastBefore = morpho.lastUpdate(liveId);
        uint256 tBABefore = morpho.totalBorrowAssets(liveId);

        vm.warp(block.timestamp + 365 days);
        (,, uint256 expTBA,) = morpho.expectedMarketBalances(liveParams);
        morpho.accrueInterest(liveParams);

        assertTrue(probe.fired(ACCRUE_INTEREST), "hook fired");
        assertEq(probe.seenLastUpdate(ACCRUE_INTEREST), lastBefore, "hook saw pre-accrual lastUpdate");
        assertEq(probe.seenTotalBorrowAssets(ACCRUE_INTEREST), tBABefore, "hook saw un-accrued borrow assets");
        assertEq(morpho.totalBorrowAssets(liveId), expTBA, "interest accrued after the hook");
    }

    // The Supply hook sees post-accrue, pre-supply totals: interest is realized, the incoming deposit
    // is not yet booked.
    function testHookSupplySeesPostAccruePreSupplyState() public {
        _setUpLiveMarket();

        vm.warp(block.timestamp + 365 days);
        (uint256 expTSA,,,) = morpho.expectedMarketBalances(liveParams);
        uint256 deposit = 10e18;
        loanToken.setBalance(address(this), deposit);
        morpho.supply(liveParams, deposit, 0, address(this), hex"");

        assertEq(
            probe.seenTotalSupplyAssets(ILidoLendMarketController.HookEvent.Supply),
            expTSA,
            "hook saw accrued totals without the incoming deposit"
        );
        assertEq(morpho.totalSupplyAssets(liveId), expTSA + deposit, "deposit booked after the hook");
    }

    // The Borrow hook sees the borrower's pre-borrow position: the new shares are not yet minted.
    function testHookBorrowSeesPreBorrowPosition() public {
        _setUpLiveMarket();
        uint256 sharesBefore = morpho.borrowShares(liveId, BORROWER);

        vm.prank(BORROWER);
        morpho.borrow(liveParams, 5e18, 0, BORROWER, BORROWER);

        assertEq(
            probe.seenBorrowShares(ILidoLendMarketController.HookEvent.Borrow),
            sharesBefore,
            "hook saw the pre-borrow shares"
        );
    }

    // The Liquidate hook sees the borrower's pre-seizure position: collateral and debt shares are
    // decremented only after it.
    function testHookLiquidateSeesPreSeizePosition() public {
        _setUpLiveMarket();
        uint256 sharesBefore = morpho.borrowShares(liveId, BORROWER);
        uint256 collateralBefore = morpho.collateral(liveId, BORROWER);

        oracle.setPrice(ORACLE_PRICE_SCALE / 10); // collateral value 100e18 < 80e18 / 0.55 → unhealthy
        loanToken.setBalance(LIQUIDATOR, 100e18);
        vm.prank(LIQUIDATOR);
        morpho.liquidate(liveParams, BORROWER, 10e18, 0, hex"");

        assertEq(
            probe.seenBorrowShares(ILidoLendMarketController.HookEvent.Liquidate),
            sharesBefore,
            "hook saw the pre-repay shares"
        );
        assertEq(
            probe.seenCollateral(ILidoLendMarketController.HookEvent.Liquidate),
            collateralBefore,
            "hook saw the pre-seizure collateral"
        );
    }

    // The Settle hook sees the borrower's pre-cut position: the payload carries the cut amounts, and a
    // controller re-reading the position from the core gets the state the cut applies to.
    function testHookSettleSeesPreCutPosition() public {
        _setUpLiveMarket();
        uint256 sharesBefore = morpho.borrowShares(liveId, BORROWER);
        uint256 collateralBefore = morpho.collateral(liveId, BORROWER);

        uint256 cut = 30e18; // above the 20e18 free liquidity, within the 80e18 debt
        (uint256 seized,,,) =
            _lido().settle(liveParams, cut * SharesMathLib.VIRTUAL_SHARES, 0, address(this), BORROWER, RECEIVER);

        assertEq(
            probe.seenBorrowShares(ILidoLendMarketController.HookEvent.Settle),
            sharesBefore,
            "hook saw the pre-cut shares"
        );
        assertEq(
            probe.seenCollateral(ILidoLendMarketController.HookEvent.Settle),
            collateralBefore,
            "hook saw the pre-cut collateral"
        );
        assertEq(morpho.collateral(liveId, BORROWER), collateralBefore - seized, "seizure applied after the hook");
    }
}
