// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import {Id, IMorphoStaticTyping, MarketParams} from "./IMorpho.sol";

/// @title ILidoLend
/// @author Lido.
/// @notice Typed surface of the `LidoLend` core: the upstream Morpho interface plus the members added by the fork.
/// This interface declares only the fork-added members. The fork-behavior annotations on inherited members live
/// in place in `IMorpho.sol` (look for the `Warning` tags).
/// @dev Extends `IMorphoStaticTyping`, not `IMorpho`: the core's public mapping getters (`position`, `market`,
/// `idToMarketParams`) are tuple-typed, so the core can only satisfy the static-typing variant. This mirrors
/// upstream `Morpho is IMorphoStaticTyping`. Where a library wants the struct-returning `IMorpho` (e.g.
/// `MorphoBalancesLib`), cast the same core address to `IMorpho`, and both views are ABI-identical.
interface ILidoLend is IMorphoStaticTyping {
    /// @notice Whether the contract is initialized.
    /// @dev The implementation is petrified to `true` by its constructor. A proxy starts at `false`
    /// and flips on its one-shot `initialize` call.
    function isInitialized() external view returns (bool);

    /// @notice One-shot initializer setting `newOwner` as `owner`. Called by the proxy at deploy time.
    /// @dev Fork-added for the upgradeable-proxy deployment: the implementation is petrified by its
    /// constructor, so only a proxy's storage can be initialized, and only once.
    /// @param newOwner The new owner of the contract.
    function initialize(address newOwner) external;

    /// @notice Creates the market `marketParams` as a controlled market, binding `controller` and the
    /// `settle` opt-in.
    /// @dev Fork-added overload. Like the single-argument `createMarket` it is `onlyOwner`, and that single-argument
    /// call is the only way to create a market without a controller. The controller and `settle` opt-in cannot be
    /// changed after creation.
    /// @param marketParams The market to create.
    /// @param controller The controller to bind. Must be non-zero and built for this market.
    /// @param enableSettlement Whether `settle` is enabled for this market.
    function createMarket(MarketParams memory marketParams, address controller, bool enableSettlement) external;

    /// @notice Cancels `borrower`'s debt against `onBehalf`'s supply shares, seizing collateral to `receiver`.
    /// @dev Fork-added single-borrower primitive, enabled per market at creation. One of `supplyAssets` or
    /// `supplyShares` must be zero, and the loan-asset value of the burned supply position is the borrower debt
    /// canceled. Callable only by `onBehalf` or an address authorized by `onBehalf`, and only when ordinary
    /// withdraw liquidity is insufficient to cover the canceled debt. The bound controller's `Settle`
    /// hook enforces borrower eligibility and the per-cut slice cap, and may revert. Reverts while another action's
    /// controller hook is executing.
    /// @param marketParams The market to settle on.
    /// @param supplyAssets The loan-asset value of `onBehalf`'s supply position to settle (and debt to cancel).
    /// @param supplyShares The amount of supply shares to burn from `onBehalf`.
    /// @param onBehalf The address whose supply shares are burned.
    /// @param borrower The borrower whose debt is canceled and collateral seized.
    /// @param receiver The address that receives the seized collateral.
    /// @return collateralSeized The collateral-token amount seized and sent to `receiver`.
    /// @return debtCanceled The loan-token amount of `borrower` debt canceled (equals the settled supply value at par,
    /// not a `borrowShares` count).
    function settle(
        MarketParams memory marketParams,
        uint256 supplyAssets,
        uint256 supplyShares,
        address onBehalf,
        address borrower,
        address receiver
    ) external returns (uint256 collateralSeized, uint256 debtCanceled);

    /// @notice The controller bound to the market corresponding to `id`. Zero address means no controller.
    /// @dev Set only at market creation, immutable thereafter.
    function marketController(Id id) external view returns (address);

    /// @notice Whether `settle` is enabled for the market corresponding to `id`.
    /// @dev Set only at market creation, immutable thereafter.
    function isSettlementEnabled(Id id) external view returns (bool);
}
