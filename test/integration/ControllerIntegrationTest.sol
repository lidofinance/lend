// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTestWithController.sol";
import {LidoBlueErrorsLib} from "../../src/libraries/LidoBlueErrorsLib.sol";

contract ControllerIntegrationTest is BaseTestWithController {
    using MorphoLib for IMorpho;

    uint8 internal constant SUPPLY = uint8(ILidoBlueMarketController.HookEvent.Supply);
    uint8 internal constant BORROW = uint8(ILidoBlueMarketController.HookEvent.Borrow);
    uint8 internal constant DELEVERAGE = uint8(ILidoBlueMarketController.HookEvent.Deleverage);

    function testCreateMarketBindsController() public {
        assertEq(LidoBlue(address(morpho)).marketController(id), address(controller), "controller bound");
        assertTrue(LidoBlue(address(morpho)).deleverageEnabled(id), "deleverage enabled");
    }

    /// @notice Deleverage has no in-core bad-debt backstop, so enabling it without a controller is forbidden.
    function testCreateMarketRevertsWhenDeleverageEnabledWithoutController() public {
        MarketParams memory params = marketParams; // enabled irm/lltv; fresh oracle => uncreated id
        params.oracle = makeAddr("FreshOracle");

        vm.expectRevert(bytes(LidoBlueErrorsLib.DELEVERAGE_REQUIRES_CONTROLLER));
        vm.prank(OWNER);
        ILidoBlue(address(morpho)).createMarket(params, address(0), true);
    }

    /// @notice A controller may only be bound to the market whose id it declares via `MARKET_ID`.
    function testCreateMarketRevertsOnControllerMismatch() public {
        MarketParams memory params = marketParams; // distinct id from the controlled market
        params.oracle = makeAddr("FreshOracle");

        // `controller` is bound to `id`, not to `params.id()`.
        vm.expectRevert(bytes(LidoBlueErrorsLib.CONTROLLER_MISMATCH));
        vm.prank(OWNER);
        ILidoBlue(address(morpho)).createMarket(params, address(controller), false);
    }

    function testSupplyFiresSupplyHook() public {
        uint256 amount = 1e18;
        loanToken.setBalance(address(this), amount);
        morpho.supply(marketParams, amount, 0, address(this), hex"");

        assertGt(morpho.supplyShares(id, address(this)), 0, "supply shares minted");
        assertEq(uint8(controller.lastEvent()), SUPPLY, "last hook is Supply");
        assertEq(controller.eventCount(SUPPLY), 1, "supply hook fired once");
    }

    function testBorrowFiresBorrowHook() public {
        uint256 supplied = 1e18;
        loanToken.setBalance(address(this), supplied);
        morpho.supply(marketParams, supplied, 0, address(this), hex"");

        _supplyCollateralForBorrower(BORROWER);

        uint256 borrowed = 0.5e18;
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowed, 0, BORROWER, BORROWER);

        assertGt(morpho.borrowShares(id, BORROWER), 0, "borrow shares minted");
        assertEq(loanToken.balanceOf(BORROWER), borrowed, "borrower received loan");
        assertEq(uint8(controller.lastEvent()), BORROW, "last hook is Borrow");
        assertEq(controller.eventCount(BORROW), 1, "borrow hook fired once");
    }

    /// @notice Happy path: the borrower holds >50% of supply as debt, so ordinary withdraw
    ///         liquidity is insufficient for the lender's exit. A mid-size slice is cancelled
    ///         against the borrower's debt and the lender receives the seized collateral.
    function testDeleverageHappyPath() public {
        uint256 supplied = 1e18;
        loanToken.setBalance(address(this), supplied);
        morpho.supply(marketParams, supplied, 0, address(this), hex"");

        _supplyCollateralForBorrower(BORROWER);

        // Borrow 80% of supply → available liquidity is 0.2e18.
        uint256 borrowed = 0.8e18;
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowed, 0, BORROWER, BORROWER);

        uint256 lenderShares = morpho.supplyShares(id, address(this));
        uint256 borrowSharesBefore = morpho.borrowShares(id, BORROWER);
        uint256 borrowerCollateralBefore = morpho.collateral(id, BORROWER);

        // Cancel ~half the lender's stake (≈0.5e18): above the 0.2e18 liquidity gate and below
        // the borrower's 0.8e18 debt, so neither cap is hit.
        uint256 slice = lenderShares / 2;

        (uint256 collateralSeized, uint256 debtCanceled) =
            ILidoBlue(address(morpho)).deleverage(marketParams, slice, BORROWER, address(this), RECEIVER);

        assertGt(debtCanceled, 0.2e18, "debt cancelled exceeds prior liquidity (gate cleared)");
        assertGt(collateralSeized, 0, "collateral seized");
        // Oracle price is 1:1 (ORACLE_PRICE_SCALE), so seizure equals the cancelled debt.
        assertEq(collateralSeized, debtCanceled, "seizure matches cancelled debt at 1:1 price");

        assertEq(morpho.supplyShares(id, address(this)), lenderShares - slice, "lender shares burned");
        assertLt(morpho.borrowShares(id, BORROWER), borrowSharesBefore, "borrower debt reduced");
        assertEq(
            morpho.collateral(id, BORROWER), borrowerCollateralBefore - collateralSeized, "borrower collateral debited"
        );
        assertEq(collateralToken.balanceOf(RECEIVER), collateralSeized, "receiver got seized collateral");
        assertEq(uint8(controller.lastEvent()), DELEVERAGE, "last hook is Deleverage");
        assertEq(controller.eventCount(DELEVERAGE), 1, "deleverage hook fired once");
    }
}
