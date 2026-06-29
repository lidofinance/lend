// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {
    Id,
    IMorphoStaticTyping,
    IMorphoBase,
    MarketParams,
    Position,
    Market,
    Authorization,
    Signature
} from "./interfaces/IMorpho.sol";
import {
    IMorphoLiquidateCallback,
    IMorphoRepayCallback,
    IMorphoSupplyCallback,
    IMorphoSupplyCollateralCallback,
    IMorphoFlashLoanCallback
} from "./interfaces/IMorphoCallbacks.sol";
import {IIrm} from "./interfaces/IIrm.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IOracle} from "./interfaces/IOracle.sol";

import "./libraries/ConstantsLib.sol";
import {UtilsLib} from "./libraries/UtilsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {MathLib, WAD} from "./libraries/MathLib.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";
import {MarketParamsLib} from "./libraries/MarketParamsLib.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";

import {ILidoLendMarketController} from "./interfaces/ILidoLendMarketController.sol";
import {ILidoLendBase, ILidoLendStaticTyping} from "./interfaces/ILidoLend.sol";

/// @title LidoLend
/// @author Morpho Labs. Modified by Lido.
/// @notice Morpho Blue fork core with optional per-market controllers.
/// @dev `Position`, `Market`, `MarketParams`, and market id derivation stay upstream-shaped.
///      Optional per-market controllers can enforce additional policy through action hooks. The
///      `settle` extension is enabled per market at creation, and only on a market that has a
///      controller, so the controller's policy can govern who may be settled and by how much.
contract LidoLend is ILidoLendStaticTyping {
    using MathLib for uint128;
    using MathLib for uint256;
    using UtilsLib for uint256;
    using SharesMathLib for uint256;
    using SafeTransferLib for IERC20;
    using MarketParamsLib for MarketParams;

    /* DOMAIN SEPARATOR */

    /// @inheritdoc IMorphoBase
    /// @dev Upstream declares this as an immutable here, computed once in the constructor. The fork
    ///      recomputes it from `address(this)` on every call so it resolves to the proxy address
    ///      under delegatecall, instead of being baked into the implementation's bytecode.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(this)));
    }

    /* STORAGE */

    /// @inheritdoc IMorphoBase
    address public owner;
    /// @inheritdoc IMorphoBase
    address public feeRecipient;
    /// @inheritdoc IMorphoStaticTyping
    mapping(Id => mapping(address => Position)) public position;
    /// @inheritdoc IMorphoStaticTyping
    mapping(Id => Market) public market;
    /// @inheritdoc IMorphoBase
    mapping(address => bool) public isIrmEnabled;
    /// @inheritdoc IMorphoBase
    mapping(uint256 => bool) public isLltvEnabled;
    /// @inheritdoc IMorphoBase
    mapping(address => mapping(address => bool)) public isAuthorized;
    /// @inheritdoc IMorphoBase
    mapping(address => uint256) public nonce;
    /// @inheritdoc IMorphoStaticTyping
    mapping(Id => MarketParams) public idToMarketParams;

    /* FORK STORAGE */

    /// @inheritdoc ILidoLendBase
    mapping(Id => address) public marketController;
    /// @inheritdoc ILidoLendBase
    mapping(Id => bool) public isSettlementEnabled;
    /// @inheritdoc ILidoLendBase
    bool public isInitialized;

    /// @dev Reentrancy lock held while a controller hook executes. Transient: occupies no
    ///      persistent slot, so the upgrade-safe layout is unaffected.
    bool internal transient _hookInProgress;

    /* INITIALIZER */

    /// @dev Petrifies the implementation, so only a proxy can call `initialize`.
    constructor() {
        isInitialized = true;
    }

    /// @inheritdoc ILidoLendBase
    function initialize(address newOwner) external {
        require(!isInitialized, ErrorsLib.ALREADY_INITIALIZED);
        require(newOwner != address(0), ErrorsLib.ZERO_ADDRESS);
        isInitialized = true;
        owner = newOwner;
        emit EventsLib.SetOwner(newOwner);
    }

    /* MODIFIERS */

    /// @dev Reverts if the caller is not the owner.
    modifier onlyOwner() {
        require(msg.sender == owner, ErrorsLib.NOT_OWNER);
        _;
    }

    /* ONLY OWNER FUNCTIONS */

    /// @inheritdoc IMorphoBase
    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != owner, ErrorsLib.ALREADY_SET);

        owner = newOwner;

        emit EventsLib.SetOwner(newOwner);
    }

    /// @inheritdoc IMorphoBase
    function setFee(MarketParams memory marketParams, uint256 newFee) external onlyOwner {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(newFee != market[id].fee, ErrorsLib.ALREADY_SET);
        require(newFee <= MAX_FEE, ErrorsLib.MAX_FEE_EXCEEDED);

        // Accrue interest using the previous fee set before changing it.
        _accrueInterest(marketParams, id);

        // Safe "unchecked" cast.
        market[id].fee = uint128(newFee);

        emit EventsLib.SetFee(id, newFee);
    }

    /// @inheritdoc IMorphoBase
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        require(newFeeRecipient != feeRecipient, ErrorsLib.ALREADY_SET);

        feeRecipient = newFeeRecipient;

        emit EventsLib.SetFeeRecipient(newFeeRecipient);
    }

    /* MARKET CREATION */

    /// @inheritdoc IMorphoBase
    function createMarket(MarketParams memory marketParams) external onlyOwner {
        _createMarket(marketParams, address(0), false);
    }

    /// @inheritdoc ILidoLendBase
    function createMarket(MarketParams memory marketParams, address controller, bool enableSettlement)
        external
        onlyOwner
    {
        require(controller != address(0), ErrorsLib.ZERO_ADDRESS);
        _createMarket(marketParams, controller, enableSettlement);
    }

    /// @dev Implements both `createMarket` overloads. The `controller` and settlement opt-in cannot be
    ///      changed after creation. Marks the market's `irm` and `lltv` as enabled on first use: the
    ///      standalone `enableIrm`/`enableLltv` are removed in this fork since `createMarket` is `onlyOwner`.
    function _createMarket(MarketParams memory marketParams, address controller, bool enableSettlement) internal {
        Id id = marketParams.id();
        require(marketParams.lltv < WAD, ErrorsLib.MAX_LLTV_EXCEEDED);
        require(market[id].lastUpdate == 0, ErrorsLib.MARKET_ALREADY_CREATED);

        if (!isIrmEnabled[marketParams.irm]) {
            isIrmEnabled[marketParams.irm] = true;
            emit EventsLib.EnableIrm(marketParams.irm);
        }
        if (!isLltvEnabled[marketParams.lltv]) {
            isLltvEnabled[marketParams.lltv] = true;
            emit EventsLib.EnableLltv(marketParams.lltv);
        }

        // Safe "unchecked" cast.
        market[id].lastUpdate = uint128(block.timestamp);
        idToMarketParams[id] = marketParams;

        if (controller != address(0)) {
            require(
                Id.unwrap(ILidoLendMarketController(controller).marketId()) == Id.unwrap(id),
                ErrorsLib.CONTROLLER_MISMATCH
            );
            marketController[id] = controller;
            emit EventsLib.SetMarketController(id, controller);

            if (enableSettlement) {
                isSettlementEnabled[id] = true;
                emit EventsLib.EnableSettlement(id);
            }
        }

        emit EventsLib.CreateMarket(id, marketParams);

        // Call to initialize the IRM in case it is stateful.
        if (marketParams.irm != address(0)) IIrm(marketParams.irm).borrowRate(marketParams, market[id]);
    }

    /* SUPPLY MANAGEMENT */

    /// @inheritdoc IMorphoBase
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
        require(onBehalf != address(0), ErrorsLib.ZERO_ADDRESS);

        _accrueInterest(marketParams, id);

        if (assets > 0) shares = assets.toSharesDown(market[id].totalSupplyAssets, market[id].totalSupplyShares);
        else assets = shares.toAssetsUp(market[id].totalSupplyAssets, market[id].totalSupplyShares);

        _hook(
            id,
            ILidoLendMarketController.HookEvent.Supply,
            abi.encode(
                ILidoLendMarketController.SupplyHookData({
                    caller: msg.sender, onBehalf: onBehalf, assets: assets, shares: shares
                })
            )
        );

        position[id][onBehalf].supplyShares += shares;
        market[id].totalSupplyShares += shares.toUint128();
        market[id].totalSupplyAssets += assets.toUint128();

        emit EventsLib.Supply(id, msg.sender, onBehalf, assets, shares);

        if (data.length > 0) IMorphoSupplyCallback(msg.sender).onMorphoSupply(assets, data);

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        return (assets, shares);
    }

    /// @inheritdoc IMorphoBase
    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        // No need to verify that onBehalf != address(0) thanks to the following authorization check.
        require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

        _accrueInterest(marketParams, id);

        if (assets > 0) shares = assets.toSharesUp(market[id].totalSupplyAssets, market[id].totalSupplyShares);
        else assets = shares.toAssetsDown(market[id].totalSupplyAssets, market[id].totalSupplyShares);

        _hook(
            id,
            ILidoLendMarketController.HookEvent.Withdraw,
            abi.encode(
                ILidoLendMarketController.WithdrawHookData({
                    caller: msg.sender, onBehalf: onBehalf, receiver: receiver, assets: assets, shares: shares
                })
            )
        );

        position[id][onBehalf].supplyShares -= shares;
        market[id].totalSupplyShares -= shares.toUint128();
        market[id].totalSupplyAssets -= assets.toUint128();

        require(market[id].totalBorrowAssets <= market[id].totalSupplyAssets, ErrorsLib.INSUFFICIENT_LIQUIDITY);

        emit EventsLib.Withdraw(id, msg.sender, onBehalf, receiver, assets, shares);

        IERC20(marketParams.loanToken).safeTransfer(receiver, assets);

        return (assets, shares);
    }

    /* BORROW MANAGEMENT */

    /// @inheritdoc IMorphoBase
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        // No need to verify that onBehalf != address(0) thanks to the following authorization check.
        require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

        _accrueInterest(marketParams, id);

        if (assets > 0) shares = assets.toSharesUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);
        else assets = shares.toAssetsDown(market[id].totalBorrowAssets, market[id].totalBorrowShares);

        _hook(
            id,
            ILidoLendMarketController.HookEvent.Borrow,
            abi.encode(
                ILidoLendMarketController.BorrowHookData({
                    caller: msg.sender, onBehalf: onBehalf, receiver: receiver, assets: assets, shares: shares
                })
            )
        );

        position[id][onBehalf].borrowShares += shares.toUint128();
        market[id].totalBorrowShares += shares.toUint128();
        market[id].totalBorrowAssets += assets.toUint128();

        require(_isHealthy(marketParams, id, onBehalf), ErrorsLib.INSUFFICIENT_COLLATERAL);
        require(market[id].totalBorrowAssets <= market[id].totalSupplyAssets, ErrorsLib.INSUFFICIENT_LIQUIDITY);

        emit EventsLib.Borrow(id, msg.sender, onBehalf, receiver, assets, shares);

        IERC20(marketParams.loanToken).safeTransfer(receiver, assets);

        return (assets, shares);
    }

    /// @inheritdoc IMorphoBase
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
        require(onBehalf != address(0), ErrorsLib.ZERO_ADDRESS);

        _accrueInterest(marketParams, id);

        if (assets > 0) shares = assets.toSharesDown(market[id].totalBorrowAssets, market[id].totalBorrowShares);
        else assets = shares.toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);

        _hook(
            id,
            ILidoLendMarketController.HookEvent.Repay,
            abi.encode(
                ILidoLendMarketController.RepayHookData({
                    caller: msg.sender, onBehalf: onBehalf, assets: assets, shares: shares
                })
            )
        );

        position[id][onBehalf].borrowShares -= shares.toUint128();
        market[id].totalBorrowShares -= shares.toUint128();
        market[id].totalBorrowAssets = UtilsLib.zeroFloorSub(market[id].totalBorrowAssets, assets).toUint128();

        // `assets` may be greater than `totalBorrowAssets` by 1.
        emit EventsLib.Repay(id, msg.sender, onBehalf, assets, shares);

        if (data.length > 0) IMorphoRepayCallback(msg.sender).onMorphoRepay(assets, data);

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        return (assets, shares);
    }

    /* COLLATERAL MANAGEMENT */

    /// @inheritdoc IMorphoBase
    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes calldata data)
        external
    {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(assets != 0, ErrorsLib.ZERO_ASSETS);
        require(onBehalf != address(0), ErrorsLib.ZERO_ADDRESS);

        // Don't accrue interest because it's not required and it saves gas.

        _hook(
            id,
            ILidoLendMarketController.HookEvent.SupplyCollateral,
            abi.encode(
                ILidoLendMarketController.SupplyCollateralHookData({
                    caller: msg.sender, onBehalf: onBehalf, assets: assets
                })
            )
        );
        position[id][onBehalf].collateral += assets.toUint128();

        emit EventsLib.SupplyCollateral(id, msg.sender, onBehalf, assets);

        if (data.length > 0) IMorphoSupplyCollateralCallback(msg.sender).onMorphoSupplyCollateral(assets, data);

        IERC20(marketParams.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    /// @inheritdoc IMorphoBase
    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external
    {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(assets != 0, ErrorsLib.ZERO_ASSETS);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        // No need to verify that onBehalf != address(0) thanks to the following authorization check.
        require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

        _accrueInterest(marketParams, id);

        _hook(
            id,
            ILidoLendMarketController.HookEvent.WithdrawCollateral,
            abi.encode(
                ILidoLendMarketController.WithdrawCollateralHookData({
                    caller: msg.sender, onBehalf: onBehalf, receiver: receiver, assets: assets
                })
            )
        );
        position[id][onBehalf].collateral -= assets.toUint128();

        require(_isHealthy(marketParams, id, onBehalf), ErrorsLib.INSUFFICIENT_COLLATERAL);

        emit EventsLib.WithdrawCollateral(id, msg.sender, onBehalf, receiver, assets);

        IERC20(marketParams.collateralToken).safeTransfer(receiver, assets);
    }

    /* SETTLEMENT */

    /// @inheritdoc ILidoLendBase
    function settle(
        MarketParams memory marketParams,
        uint256 supplyAssets,
        uint256 supplyShares,
        address onBehalf,
        address borrower,
        address receiver
    ) external returns (uint256 seizedAssets, uint256 borrowAssetsCanceled) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(isSettlementEnabled[id], ErrorsLib.SETTLEMENT_DISABLED);
        require(UtilsLib.exactlyOneZero(supplyAssets, supplyShares), ErrorsLib.INCONSISTENT_INPUT);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

        _accrueInterest(marketParams, id);

        if (supplyAssets > 0) {
            supplyShares = supplyAssets.toSharesUp(market[id].totalSupplyAssets, market[id].totalSupplyShares);
        } else {
            supplyAssets = supplyShares.toAssetsDown(market[id].totalSupplyAssets, market[id].totalSupplyShares);
        }

        // The settled supply value cancels an equal amount of borrower debt (par, no incentive).
        borrowAssetsCanceled = supplyAssets;
        // Settle may only cover onBehalf's own supply beyond the freely-withdrawable liquidity; the
        // liquid part must be redeemed normally rather than settled.
        require(borrowAssetsCanceled <= _settleableSupply(id, onBehalf), ErrorsLib.SETTLEMENT_LIQUIDITY_AVAILABLE);

        uint256 collateralPrice = IOracle(marketParams.oracle).price();
        uint256 borrowerRawCollateral = position[id][borrower].collateral;
        require(position[id][borrower].borrowShares != 0, ErrorsLib.SETTLEMENT_NO_DEBT);

        seizedAssets = borrowAssetsCanceled.mulDivDown(ORACLE_PRICE_SCALE, collateralPrice);
        require(seizedAssets != 0, ErrorsLib.SETTLEMENT_SLICE_TOO_SMALL);
        require(seizedAssets <= borrowerRawCollateral, ErrorsLib.SETTLEMENT_EXCEEDS_COLLATERAL);

        uint256 borrowSharesToBurn =
            borrowAssetsCanceled.toSharesUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);
        // require(borrowSharesToBurn <= position[id][borrower].borrowShares, ErrorsLib.SETTLEMENT_EXCEEDS_DEBT);

        _hook(
            id,
            ILidoLendMarketController.HookEvent.Settle,
            abi.encode(
                ILidoLendMarketController.SettleHookData({
                    caller: msg.sender,
                    onBehalf: onBehalf,
                    borrower: borrower,
                    receiver: receiver,
                    supplySharesBurned: supplyShares,
                    borrowAssetsCanceled: borrowAssetsCanceled,
                    borrowSharesCanceled: borrowSharesToBurn,
                    seizedAssets: seizedAssets
                })
            )
        );

        position[id][onBehalf].supplyShares -= supplyShares;
        market[id].totalSupplyShares -= supplyShares.toUint128();
        market[id].totalSupplyAssets = (market[id].totalSupplyAssets - borrowAssetsCanceled).toUint128();

        position[id][borrower].borrowShares -= borrowSharesToBurn.toUint128();
        market[id].totalBorrowShares -= borrowSharesToBurn.toUint128();
        market[id].totalBorrowAssets = (market[id].totalBorrowAssets - borrowAssetsCanceled).toUint128();

        position[id][borrower].collateral -= seizedAssets.toUint128();

        emit EventsLib.Settle(
            id, msg.sender, onBehalf, borrower, supplyShares, borrowAssetsCanceled, borrowSharesToBurn, seizedAssets
        );

        IERC20(marketParams.collateralToken).safeTransfer(receiver, seizedAssets);
    }

    /* LIQUIDATION */

    /// @inheritdoc IMorphoBase
    function liquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(seizedAssets, repaidShares), ErrorsLib.INCONSISTENT_INPUT);

        _accrueInterest(marketParams, id);

        {
            uint256 collateralPrice = IOracle(marketParams.oracle).price();

            require(!_isHealthy(marketParams, id, borrower, collateralPrice), ErrorsLib.HEALTHY_POSITION);

            // The liquidation incentive factor is min(maxLiquidationIncentiveFactor, 1/(1 - cursor*(1 - lltv))).
            uint256 liquidationIncentiveFactor = UtilsLib.min(
                MAX_LIQUIDATION_INCENTIVE_FACTOR,
                WAD.wDivDown(WAD - LIQUIDATION_CURSOR.wMulDown(WAD - marketParams.lltv))
            );

            if (seizedAssets > 0) {
                uint256 seizedAssetsQuoted = seizedAssets.mulDivUp(collateralPrice, ORACLE_PRICE_SCALE);

                repaidShares = seizedAssetsQuoted.wDivUp(liquidationIncentiveFactor)
                    .toSharesUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);
            } else {
                seizedAssets = repaidShares.toAssetsDown(market[id].totalBorrowAssets, market[id].totalBorrowShares)
                    .wMulDown(liquidationIncentiveFactor).mulDivDown(ORACLE_PRICE_SCALE, collateralPrice);
            }
        }
        uint256 repaidAssets = repaidShares.toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);

        _hook(
            id,
            ILidoLendMarketController.HookEvent.Liquidate,
            abi.encode(
                ILidoLendMarketController.LiquidateHookData({
                    caller: msg.sender,
                    borrower: borrower,
                    seizedAssets: seizedAssets,
                    repaidAssets: repaidAssets,
                    repaidShares: repaidShares
                })
            )
        );

        position[id][borrower].borrowShares -= repaidShares.toUint128();
        market[id].totalBorrowShares -= repaidShares.toUint128();
        market[id].totalBorrowAssets = UtilsLib.zeroFloorSub(market[id].totalBorrowAssets, repaidAssets).toUint128();

        position[id][borrower].collateral -= seizedAssets.toUint128();

        uint256 badDebtShares;
        uint256 badDebtAssets;
        if (position[id][borrower].collateral == 0) {
            badDebtShares = position[id][borrower].borrowShares;
            badDebtAssets = UtilsLib.min(
                market[id].totalBorrowAssets,
                badDebtShares.toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares)
            );

            market[id].totalBorrowAssets -= badDebtAssets.toUint128();
            market[id].totalSupplyAssets -= badDebtAssets.toUint128();
            market[id].totalBorrowShares -= badDebtShares.toUint128();
            position[id][borrower].borrowShares = 0;
        }

        // `repaidAssets` may be greater than `totalBorrowAssets` by 1.
        emit EventsLib.Liquidate(
            id, msg.sender, borrower, repaidAssets, repaidShares, seizedAssets, badDebtAssets, badDebtShares
        );

        IERC20(marketParams.collateralToken).safeTransfer(msg.sender, seizedAssets);

        if (data.length > 0) IMorphoLiquidateCallback(msg.sender).onMorphoLiquidate(repaidAssets, data);

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), repaidAssets);

        return (seizedAssets, repaidAssets);
    }

    /* FLASH LOANS */

    /// @inheritdoc IMorphoBase
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        require(assets != 0, ErrorsLib.ZERO_ASSETS);

        emit EventsLib.FlashLoan(msg.sender, token, assets);

        IERC20(token).safeTransfer(msg.sender, assets);

        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);

        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
    }

    /* AUTHORIZATION */

    /// @inheritdoc IMorphoBase
    function setAuthorization(address authorized, bool newIsAuthorized) external {
        require(newIsAuthorized != isAuthorized[msg.sender][authorized], ErrorsLib.ALREADY_SET);

        isAuthorized[msg.sender][authorized] = newIsAuthorized;

        emit EventsLib.SetAuthorization(msg.sender, msg.sender, authorized, newIsAuthorized);
    }

    /// @inheritdoc IMorphoBase
    function setAuthorizationWithSig(Authorization memory authorization, Signature calldata signature) external {
        /// Do not check whether authorization is already set because the nonce increment is a desired side effect.
        require(block.timestamp <= authorization.deadline, ErrorsLib.SIGNATURE_EXPIRED);
        require(authorization.nonce == nonce[authorization.authorizer]++, ErrorsLib.INVALID_NONCE);

        bytes32 hashStruct = keccak256(abi.encode(AUTHORIZATION_TYPEHASH, authorization));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", DOMAIN_SEPARATOR(), hashStruct));
        address signatory = ecrecover(digest, signature.v, signature.r, signature.s);

        require(signatory != address(0) && authorization.authorizer == signatory, ErrorsLib.INVALID_SIGNATURE);

        emit EventsLib.IncrementNonce(msg.sender, authorization.authorizer, authorization.nonce);

        isAuthorized[authorization.authorizer][authorization.authorized] = authorization.isAuthorized;

        emit EventsLib.SetAuthorization(
            msg.sender, authorization.authorizer, authorization.authorized, authorization.isAuthorized
        );
    }

    /// @dev Returns whether the sender is authorized to manage `onBehalf`'s positions.
    function _isSenderAuthorized(address onBehalf) internal view returns (bool) {
        return msg.sender == onBehalf || isAuthorized[onBehalf][msg.sender];
    }

    /* INTEREST MANAGEMENT */

    /// @inheritdoc IMorphoBase
    function accrueInterest(MarketParams memory marketParams) external {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);

        _hook(
            id,
            ILidoLendMarketController.HookEvent.AccrueInterest,
            abi.encode(ILidoLendMarketController.AccrueInterestHookData({caller: msg.sender}))
        );

        _accrueInterest(marketParams, id);
    }

    /// @dev Accrues interest for the given market `marketParams`.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    function _accrueInterest(MarketParams memory marketParams, Id id) internal {
        uint256 elapsed = block.timestamp - market[id].lastUpdate;
        if (elapsed == 0) return;

        if (marketParams.irm != address(0)) {
            uint256 borrowRate = IIrm(marketParams.irm).borrowRate(marketParams, market[id]);
            uint256 interest = market[id].totalBorrowAssets.wMulDown(borrowRate.wTaylorCompounded(elapsed));
            market[id].totalBorrowAssets += interest.toUint128();
            market[id].totalSupplyAssets += interest.toUint128();

            uint256 feeShares;
            if (market[id].fee != 0) {
                uint256 feeAmount = interest.wMulDown(market[id].fee);
                // The fee amount is subtracted from the total supply in this calculation to compensate for the fact
                // that total supply is already increased by the full interest (including the fee amount).
                feeShares =
                    feeAmount.toSharesDown(market[id].totalSupplyAssets - feeAmount, market[id].totalSupplyShares);
                position[id][feeRecipient].supplyShares += feeShares;
                market[id].totalSupplyShares += feeShares.toUint128();
            }

            emit EventsLib.AccrueInterest(id, borrowRate, interest, feeShares);
        }

        // Safe "unchecked" cast.
        market[id].lastUpdate = uint128(block.timestamp);
    }

    /* HEALTH CHECK */

    /// @dev Returns whether the position of `borrower` in the given market `marketParams` is healthy.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    function _isHealthy(MarketParams memory marketParams, Id id, address borrower) internal view returns (bool) {
        if (position[id][borrower].borrowShares == 0) return true;

        uint256 collateralPrice = IOracle(marketParams.oracle).price();

        return _isHealthy(marketParams, id, borrower, collateralPrice);
    }

    /// @dev Returns whether the position of `borrower` in the given market `marketParams` with the given
    /// `collateralPrice` is healthy.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    /// @dev Rounds in favor of the protocol, so one might not be able to borrow exactly `maxBorrow` but one unit less.
    function _isHealthy(MarketParams memory marketParams, Id id, address borrower, uint256 collateralPrice)
        internal
        view
        returns (bool)
    {
        uint256 borrowed = uint256(position[id][borrower].borrowShares)
            .toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);
        uint256 maxBorrow = uint256(position[id][borrower].collateral).mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)
            .wMulDown(marketParams.lltv);

        return maxBorrow >= borrowed;
    }

    /* CONTROLLER HELPERS */

    /// @dev Single strict-callback dispatch into the controller. ABI-encoded payloads keep the
    ///      core fork surface minimal, and the controller decodes per-event in its `on()` handler.
    /// @dev Doubles as the reentrancy gate: while any controller hook is in flight, re-entering any action
    ///      reverts — including actions on markets with no controller. The lock is released before the calling
    ///      function writes state and runs Morpho callbacks.
    function _hook(Id id, ILidoLendMarketController.HookEvent e, bytes memory data) internal {
        require(!_hookInProgress, ErrorsLib.HOOK_REENTRANCY);
        address controller = marketController[id];
        if (controller != address(0)) {
            _hookInProgress = true;
            ILidoLendMarketController(controller).on(id, e, data);
            _hookInProgress = false;
        }
    }

    /// @dev Returns the market's loan assets not currently borrowed. Does not include interest accrued
    ///      since the last update.
    function _availableLiquidity(Id id) internal view returns (uint256) {
        if (market[id].totalSupplyAssets <= market[id].totalBorrowAssets) return 0;
        return uint256(market[id].totalSupplyAssets) - uint256(market[id].totalBorrowAssets);
    }

    /// @dev The portion of `onBehalf`'s supply that exceeds the market's freely-withdrawable liquidity,
    ///      i.e. the most a settle may cancel. Saturating: 0 when the supply is fully covered by liquidity.
    function _settleableSupply(Id id, address onBehalf) internal view returns (uint256) {
        uint256 availableLiquidity = _availableLiquidity(id);
        uint256 onBehalfSupplyAssets = position[id][onBehalf].supplyShares
        .toAssetsDown(market[id].totalSupplyAssets, market[id].totalSupplyShares);
        return onBehalfSupplyAssets > availableLiquidity ? onBehalfSupplyAssets - availableLiquidity : 0;
    }

    /* STORAGE VIEW */

    /// @inheritdoc IMorphoBase
    function extSloads(bytes32[] calldata slots) external view returns (bytes32[] memory res) {
        uint256 nSlots = slots.length;

        res = new bytes32[](nSlots);

        for (uint256 i; i < nSlots;) {
            bytes32 slot = slots[i++];

            assembly ("memory-safe") {
                mstore(add(res, mul(i, 32)), sload(slot))
            }
        }
    }
}
