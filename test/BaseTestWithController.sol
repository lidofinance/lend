// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./BaseTest.sol";
import {ILidoLend} from "../src/interfaces/ILidoLend.sol";
import {ILidoLendMarketController} from "../src/interfaces/ILidoLendMarketController.sol";
import {ControllerMock} from "../src/mocks/ControllerMock.sol";

/// @notice BaseTest variant whose market is bound to a (permissive) controller with deleverage
///         enabled. The inherited `marketParams`/`id` are repointed to this controlled market, so
///         every BaseTest helper (`_supply`, `_supplyCollateralForBorrower`, ...) operates on it.
/// @dev The controlled market uses `irm == address(0)` (interest disabled) so deleverage/share
///      math stays exact. Both `address(0)` IRM and `DEFAULT_TEST_LLTV` are already enabled by
///      `BaseTest.setUp`; the differing IRM gives this market a distinct id from the default one.
contract BaseTestWithController is BaseTest {
    using MarketParamsLib for MarketParams;

    ControllerMock internal controller;

    function setUp() public virtual override {
        super.setUp();

        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(0),
            lltv: DEFAULT_TEST_LLTV
        });
        id = marketParams.id();

        controller = new ControllerMock(id);

        vm.prank(OWNER);
        ILidoLend(address(morpho)).createMarket(marketParams, address(controller), true);

        _forward(1);
    }
}
