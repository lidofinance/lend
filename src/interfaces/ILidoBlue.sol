// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import {Id, IMorphoStaticTyping, MarketParams} from "./IMorpho.sol";

/// @title ILidoBlue
/// @author Lido.
/// @notice Typed surface of the `LidoBlue` core: the upstream Morpho interface plus the members added by the fork.
/// This interface declares only the fork-added members; the fork-behavior annotations on inherited members live in
/// place in `IMorpho.sol` (look for the `Warning` tags).
/// @dev Extends `IMorphoStaticTyping`, not `IMorpho`: the core's public mapping getters (`position`, `market`,
/// `idToMarketParams`) are tuple-typed, so the core can only satisfy the static-typing variant. This mirrors
/// upstream `Morpho is IMorphoStaticTyping`. Where a library wants the struct-returning `IMorpho` (e.g.
/// `MorphoBalancesLib`), cast the same core address to `IMorpho`; both views are ABI-identical.
interface ILidoBlue is IMorphoStaticTyping {
    /// @notice One-shot initializer setting `newOwner` as `owner`. Called by the proxy at deploy time.
    /// @dev Fork-added for the upgradeable-proxy deployment: the implementation is petrified by its
    /// constructor, so only a proxy's storage can be initialized, and only once.
    /// @param newOwner The new owner of the contract.
    function initialize(address newOwner) external;

    /// @notice Creates the market `marketParams` as a controlled market, binding `controller` and the deleverage
    /// opt-in.
    /// @dev Fork-added overload; `onlyOwner` like the single-argument `createMarket`, which is the only way to
    /// create a market without a controller. The controller and deleverage opt-in cannot be changed after creation.
    /// @param marketParams The market to create.
    /// @param controller The controller to bind; must be non-zero and built for this market.
    /// @param enableDeleverage Whether the `deleverage` primitive is enabled for this market.
    function createMarket(MarketParams memory marketParams, address controller, bool enableDeleverage) external;

    /// @notice Cancels `borrower`'s debt against `onBehalf`'s supply shares, seizing collateral to `receiver`.
    /// @dev Fork-added single-borrower primitive; enabled per market at creation. Callable only by `onBehalf` or
    /// an address authorized by `onBehalf`, and only when ordinary withdraw liquidity is insufficient to cover the
    /// cancelled debt. The bound controller's `Deleverage` hook enforces borrower eligibility and the per-cut
    /// slice cap, and may revert. Reverts while another action's controller hook is executing.
    /// @param marketParams The market to deleverage on.
    /// @param supplyShares The amount of supply shares to burn from `onBehalf`.
    /// @param borrower The borrower whose debt is cancelled and collateral seized.
    /// @param onBehalf The address whose supply shares are burned.
    /// @param receiver The address that receives the seized collateral.
    /// @return collateralSeized The amount of collateral seized.
    /// @return debtCanceled The amount of borrower debt cancelled.
    function deleverage(
        MarketParams memory marketParams,
        uint256 supplyShares,
        address borrower,
        address onBehalf,
        address receiver
    ) external returns (uint256 collateralSeized, uint256 debtCanceled);

    /// @notice The controller bound to the market corresponding to `id`. Zero address means no controller.
    /// @dev Set only at market creation; immutable thereafter.
    function marketController(Id id) external view returns (address);

    /// @notice Whether the `deleverage` primitive is enabled for the market corresponding to `id`.
    /// @dev Set only at market creation; immutable thereafter.
    function deleverageEnabled(Id id) external view returns (bool);
}
