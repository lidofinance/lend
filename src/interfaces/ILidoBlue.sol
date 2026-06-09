// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import {Id, IMorphoBase, IMorphoStaticTyping, MarketParams} from "./IMorpho.sol";

/// @title ILidoBlue
/// @author Lido Lending contributors. Forked from Morpho Blue by Morpho Labs.
/// @notice Full typed surface of the `LidoBlue` core: the upstream Morpho interface plus the fork-added
/// primitives. Consumers type the core through this single interface instead of rolling per-call shims.
/// @dev Extends `IMorphoStaticTyping`, not `IMorpho`: the core's public mapping getters (`position`, `market`,
/// `idToMarketParams`) are tuple-typed, so the core can only satisfy the static-typing variant. This mirrors
/// upstream `Morpho is IMorphoStaticTyping`. Where a library wants the struct-returning `IMorpho` (e.g.
/// `MorphoBalancesLib`), cast the same core address to `IMorpho`; both views are ABI-identical.
interface ILidoBlue is IMorphoStaticTyping {
    /// @notice Creates the market `marketParams`, atomically binding its `controller` and deleverage opt-in.
    /// @dev Fork-added overload; the single-argument `createMarket` keeps upstream behavior. The controller and
    /// deleverage opt-in cannot be changed after creation.
    /// @param marketParams The market to create.
    /// @param controller The controller to bind. Pass the zero address for ordinary Morpho behavior with no hooks.
    /// @param enableDeleverage Whether the `deleverage` primitive is enabled for this market.
    function createMarket(MarketParams memory marketParams, address controller, bool enableDeleverage) external;

    /// @notice Cancels `borrower`'s debt against `onBehalf`'s supply shares, seizing collateral to `receiver`.
    /// @dev Fork-added single-borrower primitive; enabled per market at creation. Callable only by `onBehalf` or
    /// an address authorized by `onBehalf`, and only when ordinary withdraw liquidity is insufficient to cover the
    /// cancelled debt. The bound controller's hook enforces borrower eligibility and the per-cut slice cap.
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

    /// @inheritdoc IMorphoBase
    /// @dev Warning: On a market with a controller, calls the controller's `Supply` hook before applying state changes;
    /// the hook may revert.
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external override returns (uint256 assetsSupplied, uint256 sharesSupplied);

    /// @inheritdoc IMorphoBase
    /// @dev Warning: On a market with a controller, calls the controller's `Withdraw` hook before applying state
    /// changes; the hook may revert.
    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external override returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

    /// @inheritdoc IMorphoBase
    /// @dev Warning: On a market with a controller, calls the controller's `Borrow` hook before applying state changes;
    /// the hook may revert.
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external override returns (uint256 assetsBorrowed, uint256 sharesBorrowed);

    /// @inheritdoc IMorphoBase
    /// @dev Warning: On a market with a controller, calls the controller's `Repay` hook before applying state changes;
    /// the hook may revert.
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external override returns (uint256 assetsRepaid, uint256 sharesRepaid);

    /// @inheritdoc IMorphoBase
    /// @dev Warning: On a market with a controller, calls the controller's `SupplyCollateral` hook before applying
    /// state changes; the hook may revert.
    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes memory data)
        external
        override;

    /// @inheritdoc IMorphoBase
    /// @dev Warning: On a market with a controller, calls the controller's `WithdrawCollateral` hook before applying
    /// state changes; the hook may revert.
    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external
        override;

    /// @inheritdoc IMorphoBase
    /// @dev Warning: On a market with a controller, calls the controller's `Liquidate` hook before applying state
    /// changes; the hook may revert.
    function liquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes memory data
    ) external override returns (uint256, uint256);

    /// @inheritdoc IMorphoBase
    /// @dev Warning: On a market with a controller, calls the controller's `AccrueInterest` hook before applying state
    /// changes; the hook may revert.
    function accrueInterest(MarketParams memory marketParams) external override;

    /// @notice The controller bound to the market corresponding to `id`. Zero address means no controller.
    /// @dev Set only at market creation; immutable thereafter.
    function marketController(Id id) external view returns (address);

    /// @notice Whether the `deleverage` primitive is enabled for the market corresponding to `id`.
    /// @dev Set only at market creation; immutable thereafter.
    function deleverageEnabled(Id id) external view returns (bool);
}
