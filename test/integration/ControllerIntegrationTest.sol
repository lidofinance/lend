// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTestWithController.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {EventsLib} from "../../src/libraries/EventsLib.sol";

/// @dev Tests that verify controller binding at market creation: bound state, binding events, and the
///      zero-controller / id-mismatch reverts. Hook dispatch and payloads live in HooksIntegrationTest.
contract ControllerIntegrationTest is BaseTestWithController {
    using MarketParamsLib for MarketParams;

    // Creation binds the controller and the settlement opt-in and emits both binding events. The setUp
    // market pins the resulting state, a fresh market pins the events and lands in the same state.
    function testCreateMarketBindsControllerAndEmitsEvents() public {
        assertEq(_lido().marketController(id), address(controller), "controller bound");
        assertTrue(_lido().isSettlementEnabled(id), "settlement enabled");

        MarketParams memory params = marketParams;
        params.oracle = makeAddr("BindingOracle"); // fresh id
        Id newId = params.id();
        ControllerMock c = new ControllerMock(newId);

        vm.expectEmit(true, true, false, false, address(morpho));
        emit EventsLib.SetMarketController(newId, address(c));
        vm.expectEmit(true, false, false, false, address(morpho));
        emit EventsLib.EnableSettlement(newId);

        vm.prank(OWNER);
        _lido().createMarket(params, address(c), true);

        assertEq(_lido().marketController(newId), address(c), "fresh controller bound");
        assertTrue(_lido().isSettlementEnabled(newId), "fresh settlement enabled");
    }

    function testCreateMarketWithoutSettlementSkipsEnableEvent() public {
        MarketParams memory params = marketParams;
        params.oracle = makeAddr("NoSettleOracle"); // fresh id
        Id newId = params.id();
        ControllerMock c = new ControllerMock(newId);

        vm.recordLogs();
        vm.prank(OWNER);
        _lido().createMarket(params, address(c), false);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 enableSig = keccak256("EnableSettlement(bytes32)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != enableSig, "EnableSettlement must not be emitted");
        }

        assertEq(_lido().marketController(newId), address(c), "controller bound");
        assertFalse(_lido().isSettlementEnabled(newId), "settlement disabled");
    }

    /// @notice The three-argument `createMarket` creates a controlled market: a zero controller is rejected
    ///         regardless of the settlement flag (plain markets come from the one-argument call).
    function testCreateMarketRevertsOnZeroController(bool enableSettlement) public {
        MarketParams memory params = marketParams; // enabled irm/lltv; fresh oracle => uncreated id
        params.oracle = makeAddr("FreshOracle");

        vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
        vm.prank(OWNER);
        _lido().createMarket(params, address(0), enableSettlement);
    }

    /// @notice A controller may only be bound to the market whose id it declares via `marketId`.
    function testCreateMarketRevertsOnControllerMismatch() public {
        MarketParams memory params = marketParams; // distinct id from the controlled market
        params.oracle = makeAddr("FreshOracle");

        // `controller` is bound to `id`, not to `params.id()`.
        vm.expectRevert(bytes(ErrorsLib.CONTROLLER_MISMATCH));
        vm.prank(OWNER);
        _lido().createMarket(params, address(controller), false);
    }
}
