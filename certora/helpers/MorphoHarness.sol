// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import "../../src/LidoLend.sol";
import "../../src/libraries/SharesMathLib.sol";
import "../../src/libraries/MarketParamsLib.sol";

contract MorphoHarness is LidoLend {
    using MarketParamsLib for MarketParams;

    /// @dev Certora verifies the implementation directly. Initialize the owner in constructor storage
    ///      while the inherited constructor keeps the implementation petrified.
    constructor(address newOwner) {
        owner = newOwner;
    }

    function idToMarketParams_(Id id) external view returns (MarketParams memory) {
        return idToMarketParams[id];
    }

    function market_(Id id) external view returns (Market memory) {
        return market[id];
    }

    function position_(Id id, address user) external view returns (Position memory) {
        return position[id][user];
    }

    function totalSupplyAssets(Id id) external view returns (uint256) {
        return market[id].totalSupplyAssets;
    }

    function totalSupplyShares(Id id) external view returns (uint256) {
        return market[id].totalSupplyShares;
    }

    function totalBorrowAssets(Id id) external view returns (uint256) {
        return market[id].totalBorrowAssets;
    }

    function totalBorrowShares(Id id) external view returns (uint256) {
        return market[id].totalBorrowShares;
    }

    function supplyShares(Id id, address account) external view returns (uint256) {
        return position[id][account].supplyShares;
    }

    function borrowShares(Id id, address account) external view returns (uint256) {
        return position[id][account].borrowShares;
    }

    function collateral(Id id, address account) external view returns (uint256) {
        return position[id][account].collateral;
    }

    function lastUpdate(Id id) external view returns (uint256) {
        return market[id].lastUpdate;
    }

    function fee(Id id) external view returns (uint256) {
        return market[id].fee;
    }

    function virtualTotalSupplyAssets(Id id) external view returns (uint256) {
        return market[id].totalSupplyAssets + SharesMathLib.VIRTUAL_ASSETS;
    }

    function virtualTotalSupplyShares(Id id) external view returns (uint256) {
        return market[id].totalSupplyShares + SharesMathLib.VIRTUAL_SHARES;
    }

    function virtualTotalBorrowAssets(Id id) external view returns (uint256) {
        return market[id].totalBorrowAssets + SharesMathLib.VIRTUAL_ASSETS;
    }

    function virtualTotalBorrowShares(Id id) external view returns (uint256) {
        return market[id].totalBorrowShares + SharesMathLib.VIRTUAL_SHARES;
    }

    function isHealthy(MarketParams memory marketParams, address user) external view returns (bool) {
        return _isHealthy(marketParams, marketParams.id(), user);
    }

    function hookInProgress() external view returns (bool) {
        return _hookInProgress;
    }
}
