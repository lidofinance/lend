// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import {Id} from "./IMorpho.sol";

/// @title ILidoBlueMarketController
/// @author Lido Lending contributors. Forked from Morpho Blue by Morpho Labs.
/// @notice The market controller's interface. The core dispatches every action through a single
/// `on(id, e, data)` entrypoint (HookEvent order and struct layouts must match the core so the abi-encoded
/// hook payloads stay compatible). It also declares read views (`nextDeleverageCut`, `allowedSliceFor`) for
/// consumers that drive deleverage.
interface ILidoBlueMarketController {
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
    function MARKET_ID() external view returns (Id);

    /// @notice The next borrower the controller designates as eligible for a deleverage cut, and the maximum
    /// loan-asset slice allowed against it. `borrower` is the zero address when no borrower is eligible.
    function nextDeleverageCut() external view returns (address borrower, uint256 sliceAssets);

    /// @notice Maximum loan-asset slice the policy allows for a single deleverage cut against `borrower`.
    function allowedSliceFor(address borrower) external view returns (uint256);

    /// @notice Strict action callback. Reverts to abort the calling action.
    function on(Id id, HookEvent hookEvent, bytes calldata data) external;
}
