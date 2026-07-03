// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Id} from "../interfaces/IMorpho.sol";
import {ILidoLendMarketController} from "../interfaces/ILidoLendMarketController.sol";

/// @title ControllerMock
/// @notice Permissive controller recording every hook dispatch; `setRevertOn(event, true)` makes it
///         block that specific hook.
contract ControllerMock is ILidoLendMarketController {
    Id internal immutable _marketId;

    Id public lastId;
    bytes public lastData;
    uint256 public hookCount;
    HookEvent public lastEvent;

    mapping(HookEvent => uint256) public eventCount;
    mapping(HookEvent => bool) public revertOn;

    constructor(Id marketId_) {
        _marketId = marketId_;
    }

    function setRevertOn(HookEvent hookEvent, bool value) external {
        revertOn[hookEvent] = value;
    }

    function marketId() external view returns (Id) {
        return _marketId;
    }

    function on(Id id, HookEvent hookEvent, bytes calldata data) external {
        if (revertOn[hookEvent]) revert("blocked by controller");
        hookCount++;
        lastId = id;
        lastEvent = hookEvent;
        lastData = data;
        eventCount[hookEvent]++;
    }
}
