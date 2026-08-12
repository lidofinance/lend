// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title TestProxy
/// @notice Minimal delegatecall proxy used only by the test suite to deploy the locked
///         `LidoLend` implementation behind a proxy. The constructor runs `initData`
///         against `impl` in the proxy's own storage context, so the implementation's locked
///         `isInitialized` flag reads `false` here and `initialize` succeeds. All other calls are
///         forwarded to `impl`.
/// @dev Not a production proxy: it has no admin or upgrade path. `impl` is `immutable`, so it lives in
///      bytecode and never collides with the core's storage layout, which starts at slot 0.
contract TestProxy {
    address internal immutable _impl;

    constructor(address impl, bytes memory initData) {
        _impl = impl;
        if (initData.length > 0) {
            (bool ok, bytes memory ret) = impl.delegatecall(initData);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }

    fallback() external payable {
        address impl = _impl;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
