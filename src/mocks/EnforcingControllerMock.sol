// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Id, IMorpho} from "../interfaces/IMorpho.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {ILidoLendMarketController} from "../interfaces/ILidoLendMarketController.sol";

import "../libraries/ConstantsLib.sol";
import {MorphoLib} from "../libraries/periphery/MorphoLib.sol";
import {SharesMathLib} from "../libraries/SharesMathLib.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {UtilsLib} from "../libraries/UtilsLib.sol";

/// @title EnforcingControllerMock
/// @notice Test controller that permits `settle` only if the borrower remains solvent afterwards.
/// @dev This is one test policy, not a requirement imposed on production controllers by the core.
contract EnforcingControllerMock is ILidoLendMarketController {
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MathLib for uint256;

    Id internal immutable _marketId;
    IMorpho internal immutable _core;
    IOracle internal immutable _oracle;

    constructor(Id marketId_, address core_, address oracle_) {
        _marketId = marketId_;
        _core = IMorpho(core_);
        _oracle = IOracle(oracle_);
    }

    function marketId() external view returns (Id) {
        return _marketId;
    }

    function on(Id id, HookEvent hookEvent, bytes calldata data) external view {
        if (hookEvent != HookEvent.Settle) return;

        ILidoLendMarketController.SettleHookData memory d = abi.decode(data, (ILidoLendMarketController.SettleHookData));

        // The hook runs before settlement-specific writes, so these reads are the pre-settlement position.
        // The core has already checked seizedAssets <= collateral and borrowSharesCanceled <= debt shares.
        uint256 postCollateral = _core.collateral(id, d.borrower) - d.seizedAssets;
        // `borrowAssetsCanceled` may exceed `totalBorrowAssets` by 1, so mirror the core's zero floor.
        uint256 postTotalBorrowAssets = UtilsLib.zeroFloorSub(_core.totalBorrowAssets(id), d.borrowAssetsCanceled);
        uint256 postDebt = (_core.borrowShares(id, d.borrower) - d.borrowSharesCanceled)
        .toAssetsUp(postTotalBorrowAssets, _core.totalBorrowShares(id) - d.borrowSharesCanceled);

        uint256 postCollateralValue = postCollateral.mulDivDown(_oracle.price(), ORACLE_PRICE_SCALE);
        require(postCollateralValue >= postDebt, "borrower would be insolvent");
    }
}
