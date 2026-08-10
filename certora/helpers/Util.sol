// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id, MarketParams, MarketParamsLib} from "../../src/libraries/MarketParamsLib.sol";
import "../../src/libraries/MathLib.sol";
import "../../src/libraries/SharesMathLib.sol";
import "../../src/libraries/ConstantsLib.sol";
import "../../src/libraries/UtilsLib.sol";

contract Util {
    using MarketParamsLib for MarketParams;
    using MathLib for uint256;

    function wad() external pure returns (uint256) {
        return WAD;
    }

    function maxFee() external pure returns (uint256) {
        return MAX_FEE;
    }

    function oraclePriceScale() external pure returns (uint256) {
        return ORACLE_PRICE_SCALE;
    }

    function lif(uint256 lltv) external pure returns (uint256) {
        return
            UtilsLib.min(MAX_LIQUIDATION_INCENTIVE_FACTOR, WAD.wDivDown(WAD - LIQUIDATION_CURSOR.wMulDown(WAD - lltv)));
    }

    function libId(MarketParams memory marketParams) external pure returns (Id) {
        return marketParams.id();
    }

    function refId(MarketParams memory marketParams) external pure returns (Id marketParamsId) {
        marketParamsId = Id.wrap(keccak256(abi.encode(marketParams)));
    }

    function unwrapId(Id id) external pure returns (bytes32) {
        return Id.unwrap(id);
    }

    function libMulDivUp(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return MathLib.mulDivUp(x, y, d);
    }

    function libMulDivDown(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return MathLib.mulDivDown(x, y, d);
    }

    function libMin(uint256 x, uint256 y) external pure returns (uint256) {
        return UtilsLib.min(x, y);
    }

    function toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares) external pure returns (uint256) {
        return SharesMathLib.toSharesUp(assets, totalAssets, totalShares);
    }

    function toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) external pure returns (uint256) {
        return SharesMathLib.toAssetsUp(shares, totalAssets, totalShares);
    }

    function toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) external pure returns (uint256) {
        return SharesMathLib.toAssetsDown(shares, totalAssets, totalShares);
    }
}
