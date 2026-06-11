// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title LidoBlueErrorsLib
/// @author Lido Lending contributors
/// @notice Library exposing the error messages added by the LidoBlue fork.
library LidoBlueErrorsLib {
    /// @notice Thrown when a controller is bound whose `MARKET_ID` does not match the market.
    string internal constant CONTROLLER_MISMATCH = "controller mismatch";

    /// @notice Thrown when `deleverage` is called on a market that did not opt into it.
    string internal constant DELEVERAGE_DISABLED = "deleverage disabled";

    /// @notice Thrown when `deleverage` is called with zero supply shares.
    string internal constant ZERO_SHARES = "zero shares";

    /// @notice Thrown when `deleverage` is called while ordinary withdraw liquidity still covers the amount.
    string internal constant DELEVERAGE_LIQUIDITY_AVAILABLE = "ordinary liquidity available";

    /// @notice Thrown when the borrower has no debt to deleverage.
    string internal constant DELEVERAGE_NO_DEBT = "borrower has no debt";

    /// @notice Thrown when the deleverage slice is too small to seize any collateral (rounds to zero).
    string internal constant DELEVERAGE_SLICE_TOO_SMALL = "deleverage slice too small";

    /// @notice Thrown when the deleverage slice would seize more than the borrower's collateral.
    string internal constant DELEVERAGE_EXCEEDS_COLLATERAL = "deleverage exceeds collateral";

    /// @notice Thrown when the deleverage slice would cancel more than the borrower's debt.
    string internal constant DELEVERAGE_EXCEEDS_DEBT = "deleverage exceeds debt";

    /// @notice Thrown when deleverage is enabled or invoked without a controller.
    string internal constant DELEVERAGE_REQUIRES_CONTROLLER = "deleverage requires controller";

    /// @notice Thrown when `initialize` is called after the contract is already initialized.
    string internal constant ALREADY_INITIALIZED = "already initialized";

    /// @notice Thrown when a locked entrypoint is reentered while a controller hook is executing.
    string internal constant HOOK_REENTRANCY = "hook reentrancy";
}
