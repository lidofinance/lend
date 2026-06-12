// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Id, IMorpho} from "../interfaces/IMorpho.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {ILidoBlueMarketController} from "../interfaces/ILidoBlueMarketController.sol";

import "../libraries/ConstantsLib.sol";
import {MorphoLib} from "../libraries/periphery/MorphoLib.sol";
import {SharesMathLib} from "../libraries/SharesMathLib.sol";
import {MathLib} from "../libraries/MathLib.sol";

/// @title EnforcingControllerMock
/// @notice Controller that permits a `redeemCollateral` cut only if the borrower stays solvent afterwards
///         (post-cut collateral value >= post-cut debt). This encodes the guarantee the real
///         `LidoMarketController` must provide, so the invariant suite can assert "core + a
///         solvency-enforcing controller never creates bad debt". All other hooks are permissive.
contract EnforcingControllerMock is ILidoBlueMarketController {
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MathLib for uint256;

    bytes32 internal immutable _marketId;
    IMorpho internal immutable _morpho;
    IOracle internal immutable _oracle;

    constructor(Id marketId, address morpho_, address oracle_) {
        _marketId = Id.unwrap(marketId);
        _morpho = IMorpho(morpho_);
        _oracle = IOracle(oracle_);
    }

    function marketId() external view returns (Id) {
        return Id.wrap(_marketId);
    }

    function on(Id id, HookEvent hookEvent, bytes calldata data) external view {
        if (hookEvent != HookEvent.Deleverage) return;

        ILidoBlueMarketController.DeleverageHookData memory d =
            abi.decode(data, (ILidoBlueMarketController.DeleverageHookData));

        // The hook fires before the core writes state, so these reads are the pre-cut position.
        // The core has already checked collateralSeized <= collateral and the burn <= debt.
        uint256 collateral = _morpho.collateral(id, d.borrower);
        uint256 debt = _morpho.borrowShares(id, d.borrower)
            .toAssetsUp(_morpho.totalBorrowAssets(id), _morpho.totalBorrowShares(id));

        uint256 postCollateralValue = (collateral - d.collateralSeized).mulDivDown(_oracle.price(), ORACLE_PRICE_SCALE);
        uint256 postDebt = debt > d.assetsToCancel ? debt - d.assetsToCancel : 0;

        require(postCollateralValue >= postDebt, "controller: would be insolvent");
    }
}
