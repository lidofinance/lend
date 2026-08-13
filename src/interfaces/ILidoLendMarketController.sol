// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {Id} from "./IMorpho.sol";

/// @title ILidoLendMarketController
/// @author Lido.
/// @notice Interface that the controller of a market must implement.
interface ILidoLendMarketController {
    /// @notice The action being dispatched to the controller.
    enum HookEvent {
        Supply,
        Withdraw,
        Borrow,
        Repay,
        SupplyCollateral,
        WithdrawCollateral,
        Liquidate,
        AccrueInterest,
        Settle
    }

    /// @notice Payload for the `Supply` hook.
    /// @param caller The supply call's msg.sender.
    /// @param onBehalf The address whose supply position grows.
    /// @param assets The loan-token amount supplied, after resolution.
    /// @param shares The supply shares minted, after resolution.
    struct SupplyHookData {
        address caller;
        address onBehalf;
        uint256 assets;
        uint256 shares;
    }

    /// @notice Payload for the `Withdraw` hook.
    /// @param caller The withdraw call's msg.sender.
    /// @param onBehalf The address whose supply position shrinks.
    /// @param receiver The address receiving the withdrawn loan tokens.
    /// @param assets The loan-token amount withdrawn, after resolution.
    /// @param shares The supply shares burned, after resolution.
    struct WithdrawHookData {
        address caller;
        address onBehalf;
        address receiver;
        uint256 assets;
        uint256 shares;
    }

    /// @notice Payload for the `AccrueInterest` hook.
    /// @param caller The accrueInterest call's msg.sender.
    struct AccrueInterestHookData {
        address caller;
    }

    /// @notice Payload for the `SupplyCollateral` hook.
    /// @param caller The supplyCollateral call's msg.sender.
    /// @param onBehalf The address whose collateral grows.
    /// @param assets The collateral-token amount supplied.
    struct SupplyCollateralHookData {
        address caller;
        address onBehalf;
        uint256 assets;
    }

    /// @notice Payload for the `Borrow` hook.
    /// @param caller The borrow call's msg.sender.
    /// @param onBehalf The address whose borrow position grows.
    /// @param receiver The address receiving the borrowed loan tokens.
    /// @param assets The loan-token amount borrowed, after resolution.
    /// @param shares The borrow shares minted, after resolution.
    struct BorrowHookData {
        address caller;
        address onBehalf;
        address receiver;
        uint256 assets;
        uint256 shares;
    }

    /// @notice Payload for the `WithdrawCollateral` hook.
    /// @param caller The withdrawCollateral call's msg.sender.
    /// @param onBehalf The address whose collateral shrinks.
    /// @param receiver The address receiving the collateral.
    /// @param assets The collateral-token amount withdrawn.
    struct WithdrawCollateralHookData {
        address caller;
        address onBehalf;
        address receiver;
        uint256 assets;
    }

    /// @notice Payload for the `Repay` hook.
    /// @param caller The repay call's msg.sender.
    /// @param onBehalf The address whose borrow position shrinks.
    /// @param assets The loan-token amount repaid, after resolution.
    /// @param shares The borrow shares burned, after resolution.
    struct RepayHookData {
        address caller;
        address onBehalf;
        uint256 assets;
        uint256 shares;
    }

    /// @notice Payload for the `Liquidate` hook.
    /// @param caller The liquidator, and the address the seized collateral goes to.
    /// @param borrower The position being liquidated.
    /// @param seizedAssets The collateral-token amount seized, after resolution.
    /// @param repaidAssets The loan-token debt repaid, after resolution.
    /// @param repaidShares The borrow shares repaid, after resolution.
    struct LiquidateHookData {
        address caller;
        address borrower;
        uint256 seizedAssets;
        uint256 repaidAssets;
        uint256 repaidShares;
    }

    /// @notice Payload for the `Settle` hook.
    /// @dev Warning: `borrowAssetsCanceled` can exceed the market's `totalBorrowAssets` by one raw loan-token unit.
    /// The core floors the new total at zero, so a controller reconstructing post-settlement state must do the same.
    /// @dev Warning: `seizedAssets` applies two downward roundings: debt-share valuation and loan-to-collateral
    /// conversion. Only the first difference is bounded by one raw loan-token unit. The second is less than one raw
    /// collateral-token unit, whose loan-token value depends on token decimals and the oracle price.
    /// @param caller The settle call's msg.sender.
    /// @param onBehalf The address whose supply shares are burned.
    /// @param borrower The address whose debt is canceled and collateral seized.
    /// @param receiver The address receiving the seized collateral.
    /// @param supplySharesBurned The supply shares burned from onBehalf, after resolution.
    /// @param borrowAssetsCanceled The loan-token debt canceled, computed by pricing the canceled shares up.
    /// @param borrowSharesCanceled The borrow shares burned from borrower, computed in core.
    /// @param seizedAssets The collateral-token amount seized, computed by pricing the canceled shares down and then
    /// converting the result to collateral with downward rounding.
    struct SettleHookData {
        address caller;
        address onBehalf;
        address borrower;
        address receiver;
        uint256 supplySharesBurned;
        uint256 borrowAssetsCanceled;
        uint256 borrowSharesCanceled;
        uint256 seizedAssets;
    }

    /// @notice The market id reported by this controller when it is bound.
    /// @dev The core checks this value during market creation. It does not revalidate it on hooks or prevent a mutable
    /// controller from being bound to more than one market.
    function marketId() external view returns (Id);

    /// @notice Called by the core on each action listed in `HookEvent`, before the requested action's own state
    /// changes.
    /// @dev Most actions accrue interest before this call, so the hook can observe accrual writes. `AccrueInterest`
    /// dispatches before accrual, and `SupplyCollateral` does not accrue.
    /// @dev This interface does not authenticate the caller. A production controller that trusts the payload or changes
    /// state must require `msg.sender` to be the expected core contract.
    /// @param id The id of the market the action is performed on.
    /// @param hookEvent The action being performed.
    /// @param data The abi-encoded hook payload: the `HookData` struct corresponding to `hookEvent`.
    function on(Id id, HookEvent hookEvent, bytes calldata data) external;
}
