// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";

contract CreateMarketIntegrationTest is BaseTest {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using MarketParamsLib for MarketParams;

    /* ============================== MORPHO UPSTREAM TESTS ============================== */
    /* Inherited from morpho-org/morpho-blue @ 1478e9cf, adapted to the LidoLend core. */

    function testCreateMarketAlreadyCreated(MarketParams memory marketParamsFuzz) public {
        marketParamsFuzz.irm = address(irm);
        marketParamsFuzz.lltv = _boundValidLltv(marketParamsFuzz.lltv);

        vm.prank(OWNER);
        morpho.createMarket(marketParamsFuzz);

        vm.expectRevert(bytes(ErrorsLib.MARKET_ALREADY_CREATED));
        vm.prank(OWNER);
        morpho.createMarket(marketParamsFuzz);
    }

    function testIdToMarketParams(MarketParams memory marketParamsFuzz) public {
        marketParamsFuzz.irm = address(irm);
        marketParamsFuzz.lltv = _boundValidLltv(marketParamsFuzz.lltv);
        Id marketParamsFuzzId = marketParamsFuzz.id();

        vm.prank(OWNER);
        morpho.createMarket(marketParamsFuzz);

        MarketParams memory params = morpho.idToMarketParams(marketParamsFuzzId);

        assertEq(marketParamsFuzz.loanToken, params.loanToken, "loanToken != loanToken");
        assertEq(marketParamsFuzz.collateralToken, params.collateralToken, "collateralToken != collateralToken");
        assertEq(marketParamsFuzz.oracle, params.oracle, "oracle != oracle");
        assertEq(marketParamsFuzz.irm, params.irm, "irm != irm");
        assertEq(marketParamsFuzz.lltv, params.lltv, "lltv != lltv");
    }

    function testCreateMarket(MarketParams memory marketParamsFuzz) public {
        marketParamsFuzz.irm = address(irm);
        marketParamsFuzz.lltv = _boundValidLltv(marketParamsFuzz.lltv);
        Id marketParamsFuzzId = marketParamsFuzz.id();

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.CreateMarket(marketParamsFuzz.id(), marketParamsFuzz);
        vm.prank(OWNER);
        morpho.createMarket(marketParamsFuzz);

        assertEq(morpho.lastUpdate(marketParamsFuzzId), block.timestamp, "lastUpdate != block.timestamp");
        assertEq(morpho.totalSupplyAssets(marketParamsFuzzId), 0, "totalSupplyAssets != 0");
        assertEq(morpho.totalSupplyShares(marketParamsFuzzId), 0, "totalSupplyShares != 0");
        assertEq(morpho.totalBorrowAssets(marketParamsFuzzId), 0, "totalBorrowAssets != 0");
        assertEq(morpho.totalBorrowShares(marketParamsFuzzId), 0, "totalBorrowShares != 0");
        assertEq(morpho.fee(marketParamsFuzzId), 0, "fee != 0");
    }

    /* ================================= LIDO FORK TESTS ================================= */
    /* Tests for fork-added behavior. */

    function testCreateMarketTooHighLltv(MarketParams memory marketParamsFuzz) public {
        marketParamsFuzz.lltv = bound(marketParamsFuzz.lltv, WAD, type(uint256).max);

        vm.expectRevert(bytes(ErrorsLib.MAX_LLTV_EXCEEDED));
        vm.prank(OWNER);
        morpho.createMarket(marketParamsFuzz);
    }

    function testCreateMarketEnablesIrmAndLltv(MarketParams memory marketParamsFuzz) public {
        marketParamsFuzz.irm = address(new IrmMock());
        marketParamsFuzz.lltv = _boundValidLltv(marketParamsFuzz.lltv);
        vm.assume(!morpho.isLltvEnabled(marketParamsFuzz.lltv));

        assertFalse(morpho.isIrmEnabled(marketParamsFuzz.irm), "fresh IRM already enabled");

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.CreateMarket(marketParamsFuzz.id(), marketParamsFuzz);
        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.EnableIrm(marketParamsFuzz.irm);
        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.EnableLltv(marketParamsFuzz.lltv);
        vm.prank(OWNER);
        morpho.createMarket(marketParamsFuzz);

        assertTrue(morpho.isIrmEnabled(marketParamsFuzz.irm), "IRM is not enabled");
        assertTrue(morpho.isLltvEnabled(marketParamsFuzz.lltv), "LLTV is not enabled");
    }

    function testCreateMarketDoesNotReEnable(MarketParams memory marketParamsFuzz) public {
        marketParamsFuzz.irm = address(irm);
        marketParamsFuzz.lltv = marketParams.lltv; // both already enabled by the base market in setUp

        vm.assume(neq(marketParamsFuzz, marketParams));

        vm.recordLogs();
        vm.prank(OWNER);
        morpho.createMarket(marketParamsFuzz);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].topics[0], EventsLib.EnableIrm.selector, "EnableIrm re-emitted");
            assertNotEq(logs[i].topics[0], EventsLib.EnableLltv.selector, "EnableLltv re-emitted");
        }
    }
}
