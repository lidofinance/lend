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
/// @notice The LidoLend contract: a Morpho Blue fork with per-market controller hooks and a `settle`
///         primitive.
contract LidoLend is ILidoLendStaticTyping {
    using MathLib for uint128;
    using MathLib for uint256;
    using UtilsLib for uint256;
    using SharesMathLib for uint256;
    using SafeTransferLib for IERC20;
    using MarketParamsLib for MarketParams;

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
    /// @inheritdoc ILidoLendBase
    mapping(Id => address) public marketController;
    /// @inheritdoc ILidoLendBase
    mapping(Id => bool) public isSettlementEnabled;
    /// @inheritdoc ILidoLendBase
    bool public isInitialized;

    /// @dev Reentrancy lock held while a controller hook executes.
    bool internal transient _hookInProgress;

    /* INITIALIZER */

    /// @dev Locks the implementation contract when it is deployed, preventing it from being initialized.
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

    /// @dev Creates the market `marketParams`, binding `controller` and the settlement opt-in.
    /// @dev Assumes that `enableSettlement` is true only when `controller` is non-zero: settlement
    ///      cannot be enabled on a market without a controller.
    function _createMarket(MarketParams memory marketParams, address controller, bool enableSettlement) internal {
        Id id = marketParams.id();
        require(marketParams.lltv < WAD, ErrorsLib.MAX_LLTV_EXCEEDED);
        require(market[id].lastUpdate == 0, ErrorsLib.MARKET_ALREADY_CREATED);

        // Emitted first, so the market's configuration events below follow its creation event. A
        // revert further down (the controller check) rolls the event back with everything else.
        emit EventsLib.CreateMarket(id, marketParams);

        // The one external call (`marketId()`) runs before any state is written, so reentering from
        // the controller cannot observe a half-created market.
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
        uint256 supplyShares,
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
        )
    {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(isSettlementEnabled[id], ErrorsLib.SETTLEMENT_DISABLED);
        require(UtilsLib.exactlyOneZero(supplyShares, borrowShares), ErrorsLib.INCONSISTENT_INPUT);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

        _accrueInterest(marketParams, id);

        if (supplyShares > 0) {
            // Supply-anchored: burn `onBehalf`'s exact supply shares, derive the rest. `toAssetsDown` cancels
            // a hair LESS debt than that supply is worth (`onBehalf` eats the wei). `toSharesUp` burns a hair
            // MORE borrow shares than par (remaining borrowers owe the wei).
            supplySharesBurned = supplyShares;
            borrowAssetsCanceled =
                supplySharesBurned.toAssetsDown(market[id].totalSupplyAssets, market[id].totalSupplyShares);
            borrowSharesCanceled =
                borrowAssetsCanceled.toSharesUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);
        } else {
            // Borrow-anchored: burn the borrower's exact debt shares, derive the rest (whole holding closes
            // to zero). `toAssetsUp` cancels a hair MORE debt than par (this borrower's collateral covers it, and
            // others owe one wei less). `toSharesUp` burns a hair MORE supply (`onBehalf` eats the wei).
            borrowSharesCanceled = borrowShares;
            borrowAssetsCanceled = borrowShares.toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);
            supplySharesBurned =
                borrowAssetsCanceled.toSharesUp(market[id].totalSupplyAssets, market[id].totalSupplyShares);
        }

        require(borrowSharesCanceled <= position[id][borrower].borrowShares, ErrorsLib.SETTLEMENT_EXCEEDS_DEBT);

        require(supplySharesBurned <= position[id][onBehalf].supplyShares, ErrorsLib.SETTLEMENT_EXCEEDS_SUPPLY);

        uint256 collateralPrice = IOracle(marketParams.oracle).price();
        seizedAssets = borrowAssetsCanceled.mulDivDown(ORACLE_PRICE_SCALE, collateralPrice);
        require(seizedAssets != 0, ErrorsLib.SETTLEMENT_SLICE_TOO_SMALL);
        require(seizedAssets <= position[id][borrower].collateral, ErrorsLib.SETTLEMENT_EXCEEDS_COLLATERAL);

        _hook(
            id,
            ILidoLendMarketController.HookEvent.Settle,
            abi.encode(
                ILidoLendMarketController.SettleHookData({
                    caller: msg.sender,
                    onBehalf: onBehalf,
                    borrower: borrower,
                    receiver: receiver,
                    supplySharesBurned: supplySharesBurned,
                    borrowAssetsCanceled: borrowAssetsCanceled,
                    borrowSharesCanceled: borrowSharesCanceled,
                    seizedAssets: seizedAssets
                })
            )
        );

        position[id][onBehalf].supplyShares -= supplySharesBurned;
        market[id].totalSupplyShares -= supplySharesBurned.toUint128();
        market[id].totalSupplyAssets -= borrowAssetsCanceled.toUint128();

        position[id][borrower].borrowShares -= borrowSharesCanceled.toUint128();
        market[id].totalBorrowShares -= borrowSharesCanceled.toUint128();
        market[id].totalBorrowAssets -= borrowAssetsCanceled.toUint128();

        position[id][borrower].collateral -= seizedAssets.toUint128();

        emit EventsLib.Settle(
            id,
            msg.sender,
            onBehalf,
            borrower,
            receiver,
            supplySharesBurned,
            borrowAssetsCanceled,
            borrowSharesCanceled,
            seizedAssets
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
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(this)));
    }

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

    /// @dev Reentrancy gate: while a hook is in flight, every hooked action reverts — including actions
    ///      on markets with no controller.
    function _hook(Id id, ILidoLendMarketController.HookEvent hookEvent, bytes memory data) internal {
        require(!_hookInProgress, ErrorsLib.HOOK_REENTRANCY);
        address controller = marketController[id];
        if (controller != address(0)) {
            _hookInProgress = true;
            ILidoLendMarketController(controller).on(id, hookEvent, data);
            _hookInProgress = false;
        }
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
