// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import {Id} from "./IMorpho.sol";

/// @title ILidoLendMarketController
/// @author Lido.
/// @notice The market controller's interface — the full coupling between the core and a controller:
/// `marketId()`, checked when the controller is bound at market creation, and the `on(id, e, data)` hook
/// entrypoint, through which the core dispatches every action (HookEvent order and struct layouts must
/// match the core so the abi-encoded hook payloads stay compatible).
interface ILidoLendMarketController {
    enum HookEvent {
        Supply,
        Withdraw,
        Borrow,
        Repay,
        SupplyCollateral,
        WithdrawCollateral,
        Liquidate,
        AccrueInterest,
        Deleverage
    }

    struct SupplyHookData {
        address caller;
        address onBehalf;
        uint256 assets;
        uint256 shares;
    }

    struct WithdrawHookData {
        address caller;
        address onBehalf;
        address receiver;
        uint256 assets;
        uint256 shares;
    }

    struct AccrueInterestHookData {
        address caller;
    }

    struct SupplyCollateralHookData {
        address caller;
        address onBehalf;
        uint256 assets;
    }

    struct BorrowHookData {
        address caller;
        address onBehalf;
        address receiver;
        uint256 assets;
        uint256 shares;
    }

    struct WithdrawCollateralHookData {
        address caller;
        address onBehalf;
        address receiver;
        uint256 assets;
    }

    struct RepayHookData {
        address caller;
        address onBehalf;
        uint256 assets;
        uint256 shares;
    }

    struct LiquidateHookData {
        address caller;
        address borrower;
        uint256 seizedAssets;
        uint256 repaidShares;
    }

    struct DeleverageHookData {
        address caller;
        address onBehalf;
        address borrower;
        address receiver;
        uint256 assetsToCancel; // computed in core (debtCanceled)
        uint256 collateralSeized; // computed in core; controller debits buckets by exactly this (lockstep with raw)
    }

    /// @notice The single market id this controller manages. Checked at market binding.
    function marketId() external view returns (Id);

    /// @notice Strict action callback. Reverts to abort the calling action.
    function on(Id id, HookEvent hookEvent, bytes calldata data) external;
}
