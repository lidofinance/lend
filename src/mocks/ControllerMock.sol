// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Id} from "../interfaces/IMorpho.sol";
import {ILidoBlueMarketController} from "../interfaces/ILidoBlueMarketController.sol";

/// @title ControllerMock
/// @notice Permissive market controller for tests. Satisfies the core's binding check
///         (`MARKET_ID`) and records every hook dispatch (event + payload) so tests can assert the
///         core fired it with the right data. By default `on` never reverts, exercising the happy
///         path without policy; `setRevertOn(event, true)` makes it block that specific hook so tests
///         can exercise the per-action gate.
/// @dev Stores the bound id as `bytes32` immutable to avoid relying on user-defined-value-type
///      immutables; wraps back to `Id` in the getter.
contract ControllerMock is ILidoBlueMarketController {
    bytes32 internal immutable _marketId;

    uint256 public hookCount;
    HookEvent public lastEvent;
    bytes public lastData;
    mapping(uint8 => uint256) public eventCount;

    mapping(uint8 => bool) public revertOn;

    constructor(Id marketId) {
        _marketId = Id.unwrap(marketId);
    }

    function setRevertOn(HookEvent hookEvent, bool value) external {
        revertOn[uint8(hookEvent)] = value;
    }

    function MARKET_ID() external view returns (Id) {
        return Id.wrap(_marketId);
    }

    function nextDeleverageCut() external pure returns (address, uint256) {
        return (address(0), 0);
    }

    function allowedSliceFor(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function on(Id, HookEvent hookEvent, bytes calldata data) external {
        if (revertOn[uint8(hookEvent)]) revert("controller: blocked");
        hookCount++;
        lastEvent = hookEvent;
        lastData = data;
        eventCount[uint8(hookEvent)]++;
    }
}
