// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./BaseTest.sol";
import {ILidoLend} from "../src/interfaces/ILidoLend.sol";
import {ILidoLendMarketController} from "../src/interfaces/ILidoLendMarketController.sol";
import {ControllerMock} from "../src/mocks/ControllerMock.sol";

/// @notice BaseTest variant whose market is bound to a (permissive) controller with settlement
///         enabled. The inherited `marketParams`/`id` are repointed to this controlled market, so
///         every BaseTest helper (`_supply`, `_supplyCollateralForBorrower`, ...) operates on it.
/// @dev The controlled market uses `irm == address(0)` (interest disabled) so settlement/share
///      math stays exact. Both `address(0)` IRM and `DEFAULT_TEST_LLTV` are already enabled by
///      `BaseTest.setUp`; the differing IRM gives this market a distinct id from the default one.
contract BaseTestWithController is BaseTest {
    using MathLib for uint256;
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

    function _lido() internal view returns (ILidoLend) {
        return ILidoLend(address(morpho));
    }

    /// @dev Collateral seized for cancelling `debtAssets` of loan value at the current price (matches the
    ///      core's mulDivDown).
    function _seizedFor(uint256 debtAssets) internal view returns (uint256) {
        return debtAssets.mulDivDown(ORACLE_PRICE_SCALE, oracle.price());
    }

    /// @dev Bounds `seed` to a healthy price (collateral worth 1x..10x the loan) and applies it.
    function _setFuzzedPrice(uint256 seed) internal {
        oracle.setPrice(bound(seed, ORACLE_PRICE_SCALE, 10 * ORACLE_PRICE_SCALE));
    }

    /// @dev `lender` supplies `amount` of loan tokens to `params`.
    function _supplyAs(MarketParams memory params, address lender, uint256 amount) internal {
        loanToken.setBalance(lender, amount);
        vm.startPrank(lender);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(params, amount, 0, lender, hex"");
        vm.stopPrank();
    }

    /// @dev `borrower` posts `collateral` and borrows `borrowed` on `params`.
    function _borrowAs(MarketParams memory params, address borrower, uint256 collateral, uint256 borrowed) internal {
        collateralToken.setBalance(borrower, collateral);
        vm.startPrank(borrower);
        collateralToken.approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(params, collateral, borrower, hex"");
        morpho.borrow(params, borrowed, 0, borrower, borrower);
        vm.stopPrank();
    }

    /// @dev address(this) supplies `supplied`; BORROWER posts `collateral` and borrows `borrowed`.
    function _openPosition(uint256 supplied, uint256 collateral, uint256 borrowed) internal {
        _supply(supplied);
        _borrowAs(marketParams, BORROWER, collateral, borrowed);
    }
}
