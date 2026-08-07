// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {Id, IMorphoBase, IMorphoStaticTyping, IMorpho, MarketParams} from "./IMorpho.sol";

/// @dev This interface is used for factorizing ILidoLendStaticTyping and ILidoLend.
/// @dev Consider using the ILidoLend interface instead of this one.
interface ILidoLendBase is IMorphoBase {
    /// @notice Whether the contract is initialized.
    function isInitialized() external view returns (bool);

    /// @notice Initializes the contract, setting `newOwner` as `owner`.
    /// @dev Can only be called once. The implementation contract cannot be initialized.
    /// @param newOwner The new owner of the contract.
    function initialize(address newOwner) external;

    /// @notice Creates the market `marketParams` with `controller` bound and, if `enableSettlement`, `settle`
    /// enabled.
    /// @dev Warning: This function is `onlyOwner`, and the single-argument `createMarket` is the only way to
    /// create a market without a controller.
    /// @dev The controller and the settlement flag cannot be changed after creation.
    /// @param marketParams The market to create.
    /// @param controller The controller of the market. Must be non-zero.
    /// @param enableSettlement Whether `settle` is enabled on the market.
    function createMarket(MarketParams memory marketParams, address controller, bool enableSettlement) external;

    /// @notice Cancels `borrower`'s debt shares against `onBehalf`'s supply shares and seizes the corresponding
    /// collateral to `receiver`.
    /// @dev Cancels exactly `borrowShares` and derives the debt assets and the supply-share burn with upward rounding.
    /// @dev The seizure prices the same shares with downward rounding, so `onBehalf` bears the gap between the two
    /// valuations, which is at most one loan-asset unit.
    /// @dev A cut that buys less than one collateral unit at the oracle price seizes nothing and reverts.
    /// @dev Passing the borrower's entire share balance closes the debt position to zero, unless that balance itself
    /// falls under that floor.
    /// @dev `msg.sender` must be authorized to manage `onBehalf`'s positions.
    /// @dev Settlement must be enabled on the market.
    /// @dev The derived supply-share burn cannot exceed `onBehalf`'s owned supply shares.
    /// @dev Warning: This function calls the controller's `Settle` hook after interest accrual and before
    /// applying the state changes, and reverts when reentered from a controller hook. The hook itself may
    /// revert.
    /// @param marketParams The market to settle on.
    /// @param borrowShares The exact amount of `borrower`'s debt shares to cancel.
    /// @param onBehalf The address of the owner of the supply position.
    /// @param borrower The address of the owner of the debt position.
    /// @param receiver The address that will receive the seized collateral.
    /// @return seizedAssets The collateral seized and sent to `receiver`, priced from the shares rounded down.
    /// @return borrowAssetsCanceled The debt canceled, in loan-token assets, priced from the shares rounded up.
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
    /// @dev Cannot be changed after market creation.
    function marketController(Id id) external view returns (address);

    /// @notice Whether `settle` is enabled on the market corresponding to `id`.
    /// @dev Cannot be changed after market creation.
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
