// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {Id, IMorphoBase, IMorphoStaticTyping, IMorpho, MarketParams} from "./IMorpho.sol";

/// @dev This interface is used for factorizing ILidoLendStaticTyping and ILidoLend.
/// @dev Consider using the ILidoLend interface instead of this one.
interface ILidoLendBase is IMorphoBase {
    /// @notice Whether initialization has been consumed in this contract's storage context.
    function isInitialized() external view returns (bool);

    /// @notice Initializes the contract, setting `newOwner` as `owner`.
    /// @dev Can only be called once. The implementation contract cannot be initialized.
    /// @dev Warning: This function has no caller restriction. A proxy must invoke it atomically during deployment;
    /// otherwise any account can initialize the proxy and become its owner.
    /// @param newOwner The new owner of the contract.
    function initialize(address newOwner) external;

    /// @notice Creates the market `marketParams` with `controller` bound and, if `enableSettlement`, `settle`
    /// enabled.
    /// @dev Warning: This function is `onlyOwner`, and the single-argument `createMarket` is the only way to
    /// create a market without a controller.
    /// @dev `controller` must implement `ILidoLendMarketController` and return the new market id from `marketId()`.
    /// @dev The dependency assumptions documented on `IMorphoBase.createMarket` also apply to this overload.
    /// @dev The current implementation exposes no setter for the controller or settlement flag. A core upgrade can
    /// change either value.
    /// @param marketParams The market to create.
    /// @param controller The non-zero controller to bind to the market.
    /// @param enableSettlement Whether `settle` is enabled on the market.
    function createMarket(MarketParams memory marketParams, address controller, bool enableSettlement) external;

    /// @notice Cancels `borrower`'s debt shares against `onBehalf`'s supply shares and seizes the corresponding
    /// collateral to `receiver`.
    /// @dev Cancels exactly `borrowShares` and derives the debt assets and supply-share burn with upward rounding.
    /// @dev The collateral output first values the canceled debt shares with downward rounding and then converts that
    /// loan-token amount to collateral with another downward rounding. The first difference is at most one raw
    /// loan-token unit. The second is less than one raw collateral-token unit, whose loan-token value is not generally
    /// bounded by one raw loan-token unit.
    /// @dev A settlement whose calculated collateral output is zero reverts.
    /// @dev Passing the borrower's entire debt-share balance removes it exactly if all derived amount guards and the
    /// controller hook pass.
    /// @dev `msg.sender` must be authorized to manage `onBehalf`'s positions.
    /// @dev Settlement must be enabled on the market.
    /// @dev The derived supply-share burn cannot exceed `onBehalf`'s owned supply shares.
    /// @dev Warning: This function calls the controller's `Settle` hook after interest accrual and before the
    /// settlement-specific state changes. It reverts when called from any controller hook, and the controller may
    /// revert to reject the settlement.
    /// @param marketParams The market to settle on.
    /// @param borrowShares The exact amount of `borrower`'s debt shares to cancel.
    /// @param onBehalf The address of the owner of the supply position.
    /// @param borrower The address of the owner of the debt position.
    /// @param receiver The address that will receive the seized collateral.
    /// @return seizedAssets The collateral seized and sent to `receiver`, priced from the shares rounded down.
    /// @return borrowAssetsCanceled The debt canceled, in loan-token assets, priced from the shares rounded up. This
    /// may exceed the market's pre-settlement `totalBorrowAssets` by one raw unit; the total is floored at zero.
    /// @return borrowSharesCanceled The count of `borrower`'s debt shares canceled.
    /// @return supplySharesBurned The amount of `onBehalf`'s supply shares burned.
    function settle(
        MarketParams memory marketParams,
        uint256 borrowShares,
        address onBehalf,
        address borrower,
        address receiver
    )
        external
        returns (
            uint256 seizedAssets,
            uint256 borrowAssetsCanceled,
            uint256 borrowSharesCanceled,
            uint256 supplySharesBurned
        );

    /// @notice The controller of the market corresponding to `id`. Zero if the market has no controller.
    /// @dev No function in the current implementation changes this value after market creation.
    function marketController(Id id) external view returns (address);

    /// @notice Whether `settle` is enabled on the market corresponding to `id`.
    /// @dev No function in the current implementation changes this value after market creation.
    function isSettlementEnabled(Id id) external view returns (bool);
}

/// @dev This interface is inherited by LidoLend so that function signatures are checked by the compiler.
/// @dev Consider using the ILidoLend interface instead of this one.
interface ILidoLendStaticTyping is ILidoLendBase, IMorphoStaticTyping {}

/// @title ILidoLend
/// @author Lido.
/// @dev Use this interface for LidoLend to have access to all the functions with the appropriate function
/// signatures.
interface ILidoLend is ILidoLendBase, IMorpho {}
