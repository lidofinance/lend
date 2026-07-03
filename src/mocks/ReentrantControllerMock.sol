// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Id} from "../interfaces/IMorpho.sol";
import {ILidoLendMarketController} from "../interfaces/ILidoLendMarketController.sol";

/// @title ReentrantControllerMock
/// @notice Adversarial controller that reenters the core from its hook with a preset call (`arm`),
///         bubbling the reentrant revert so the test sees the real failure. Guarded against
///         unbounded recursion should the core's lock fail.
contract ReentrantControllerMock is ILidoLendMarketController {
    Id internal immutable _marketId;
    address public immutable core;

    bytes public reentryCall;
    bool internal _entered;

    constructor(Id marketId_, address core_) {
        _marketId = marketId_;
        core = core_;
    }

    function arm(bytes calldata data) external {
        reentryCall = data;
    }

    function marketId() external view returns (Id) {
        return _marketId;
    }

    /// @dev Accepts flash loans, so an armed `flashLoan` reentry is valid on its own (repayment is
    ///      the caller's concern).
    function onMorphoFlashLoan(uint256, bytes calldata) external {}

    function on(Id, HookEvent, bytes calldata) external {
        if (reentryCall.length == 0 || _entered) return;
        _entered = true;
        (bool ok, bytes memory ret) = core.call(reentryCall);
        _entered = false;
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
