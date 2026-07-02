// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Id, IMorpho} from "../interfaces/IMorpho.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {ILidoLendMarketController} from "../interfaces/ILidoLendMarketController.sol";

import "../libraries/ConstantsLib.sol";
import {MorphoLib} from "../libraries/periphery/MorphoLib.sol";
import {SharesMathLib} from "../libraries/SharesMathLib.sol";
import {MathLib} from "../libraries/MathLib.sol";

/// @title EnforcingControllerMock
/// @notice Controller that permits a `settle` cut only if the borrower stays solvent afterwards
///         (post-cut collateral value >= post-cut debt) — the guarantee a production controller must
///         provide, since the core itself has no solvency check on `settle`. All other hooks are
///         permissive.
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

        // The hook fires before the core writes state, so these reads are the pre-cut position, and the
        // core has already bounded the cut (seizedAssets <= collateral, borrowSharesCanceled <= debt shares).
        uint256 postCollateral = _core.collateral(id, d.borrower) - d.seizedAssets;
        uint256 postDebt = (_core.borrowShares(id, d.borrower) - d.borrowSharesCanceled)
        .toAssetsUp(
            _core.totalBorrowAssets(id) - d.borrowAssetsCanceled, _core.totalBorrowShares(id) - d.borrowSharesCanceled
        );

        uint256 postCollateralValue = postCollateral.mulDivDown(_oracle.price(), ORACLE_PRICE_SCALE);
        require(postCollateralValue >= postDebt, "borrower would be insolvent");
    }
}
