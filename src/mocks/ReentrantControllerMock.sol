// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Id} from "../interfaces/IMorpho.sol";
import {ILidoLendMarketController} from "../interfaces/ILidoLendMarketController.sol";

/// @title ReentrantControllerMock
/// @notice Adversarial controller for reentrancy tests: on its first hook dispatch it reenters the
///         core with a preset call (`arm`), exercising the window where `_hook` runs before the
///         calling function has written its state. Single-shot to avoid unbounded recursion; bubbles
///         the reentrant revert so the test sees the real failure.
contract ReentrantControllerMock is ILidoLendMarketController {
    bytes32 internal immutable _marketId;
    address public immutable core;

    bytes public reentryCall;
    bool internal _entered;

    constructor(Id marketId, address core_) {
        _marketId = Id.unwrap(marketId);
        core = core_;
    }

    function arm(bytes calldata data) external {
        reentryCall = data;
    }

    function marketId() external view returns (Id) {
        return Id.wrap(_marketId);
    }

    /// @dev Accepts flash loans, so an armed `flashLoan` reentry is valid on its own (repayment
    ///      is covered by the test's blanket approval).
    function onMorphoFlashLoan(uint256, bytes calldata) external {}

    function on(Id, HookEvent, bytes calldata) external {
        if (reentryCall.length == 0 || _entered) return;
        _entered = true;
        (bool ok, bytes memory ret) = core.call(reentryCall);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
