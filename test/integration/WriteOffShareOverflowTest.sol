// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";

/// @notice Pins an inherited Morpho limit: share totals live in `uint128`. A bad-debt write-off of nearly all supply
/// leaves the supply share total in place while supply assets fall to about one raw unit, so each later raw unit of
/// supply mints a very large number of shares. With a non-zero fee, an accrual whose fee shares no longer fit then
/// reverts, and with it every action that accrues first, `setFee` included.
contract WriteOffShareOverflowTest is BaseTest {
    using MorphoLib for IMorpho;

    address internal HOLDER;
    address internal LATE_LENDER;
    address internal LATE_BORROWER;

    function setUp() public override {
        super.setUp();

        HOLDER = makeAddr("Holder");
        LATE_LENDER = makeAddr("LateLender");
        LATE_BORROWER = makeAddr("LateBorrower");

        vm.prank(HOLDER);
        collateralToken.approve(address(morpho), type(uint256).max);
        vm.startPrank(LATE_LENDER);
        loanToken.approve(address(morpho), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(LATE_BORROWER);
        loanToken.approve(address(morpho), type(uint256).max);
        collateralToken.approve(address(morpho), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Lends `amount` out in full, then lets the oracle report a near-zero price for one block, so the
    /// liquidation of the only borrower writes off nearly all supply.
    function _writeOffNearlyAllSupply(uint256 amount) internal {
        loanToken.setBalance(SUPPLIER, amount);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, amount, 0, SUPPLIER, hex"");

        uint256 collateral = amount * 2;
        collateralToken.setBalance(BORROWER, collateral);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(marketParams, collateral, BORROWER, hex"");
        morpho.borrow(marketParams, amount, 0, BORROWER, BORROWER);
        vm.stopPrank();

        oracle.setPrice(1);
        loanToken.setBalance(LIQUIDATOR, amount);
        vm.prank(LIQUIDATOR);
        morpho.liquidate(marketParams, BORROWER, collateral, 0, hex"");
        oracle.setPrice(ORACLE_PRICE_SCALE);

        assertEq(morpho.totalSupplyAssets(id), 1, "supply assets written down to one unit");
        assertEq(morpho.totalBorrowAssets(id), 0, "no debt left");
    }

    /// @dev Supplies as much as still fits under the uint128 share limit, leaving `headroom` shares, and borrows
    /// most of it so that interest and a fee accrue.
    function _fillShareTotal(uint256 headroom) internal returns (uint256 supplied) {
        uint256 totalAssets = morpho.totalSupplyAssets(id);
        uint256 totalShares = morpho.totalSupplyShares(id);
        supplied = (uint256(type(uint128).max) - totalShares - headroom) * (totalAssets + SharesMathLib.VIRTUAL_ASSETS)
            / (totalShares + SharesMathLib.VIRTUAL_SHARES);

        loanToken.setBalance(LATE_LENDER, supplied);
        vm.prank(LATE_LENDER);
        morpho.supply(marketParams, supplied, 0, LATE_LENDER, hex"");

        collateralToken.setBalance(LATE_BORROWER, supplied * 2);
        vm.startPrank(LATE_BORROWER);
        morpho.supplyCollateral(marketParams, supplied * 2, LATE_BORROWER, hex"");
        morpho.borrow(marketParams, supplied * 9 / 10, 0, LATE_BORROWER, LATE_BORROWER);
        vm.stopPrank();
    }

    function _postCollateral(address account, uint256 amount) internal {
        collateralToken.setBalance(account, amount);
        vm.prank(account);
        morpho.supplyCollateral(marketParams, amount, account, hex"");
    }

    /// After a write-off of a large market, a dust supply fills the share total, and every accruing action reverts
    /// for good, including a debt-free account's collateral withdrawal and the owner's `setFee(0)`.
    function testFeeAccrualFreezesMarketAfterNearTotalWriteOff() public {
        vm.prank(OWNER);
        morpho.setFee(marketParams, 0.01 ether);
        _postCollateral(HOLDER, 50e18);

        _writeOffNearlyAllSupply(10_000e18);
        uint256 supplied = _fillShareTotal(0);
        assertLt(supplied, 1e12, "the supply that fills the share total is dust");

        _forward(60);

        vm.prank(HOLDER);
        vm.expectRevert(stdError.arithmeticError);
        morpho.withdrawCollateral(marketParams, 50e18, HOLDER, HOLDER);

        vm.expectRevert(stdError.arithmeticError);
        morpho.accrueInterest(marketParams);

        uint256 debtShares = morpho.borrowShares(id, LATE_BORROWER);
        loanToken.setBalance(LATE_BORROWER, supplied * 2);
        vm.prank(LATE_BORROWER);
        vm.expectRevert(stdError.arithmeticError);
        morpho.repay(marketParams, 0, debtShares, LATE_BORROWER, hex"");

        vm.prank(OWNER);
        vm.expectRevert(stdError.arithmeticError);
        morpho.setFee(marketParams, 0);

        _forward(365 days);
        vm.prank(HOLDER);
        vm.expectRevert(stdError.arithmeticError);
        morpho.withdrawCollateral(marketParams, 50e18, HOLDER, HOLDER);
    }

    /// After a write-off of a dust market, the share limit is far above dust: here tens of thousands of tokens can
    /// still be supplied. Once that supply fills the share total, the market freezes in the same way.
    function testFeeAccrualFreezesMarketAfterDustWriteOff() public {
        vm.prank(OWNER);
        morpho.setFee(marketParams, 0.25 ether);

        _writeOffNearlyAllSupply(1.3e10);
        uint256 supplied = _fillShareTotal(1e33);
        assertGt(supplied, 10_000e18, "the share limit is not dust");

        _forward(1 days);

        vm.expectRevert(stdError.arithmeticError);
        morpho.accrueInterest(marketParams);

        vm.prank(LATE_LENDER);
        vm.expectRevert(stdError.arithmeticError);
        morpho.withdraw(marketParams, 1, 0, LATE_LENDER, LATE_LENDER);

        vm.prank(OWNER);
        vm.expectRevert(stdError.arithmeticError);
        morpho.setFee(marketParams, 0);
    }

    /// Control: the same sequence on a market without a fee leaves the exits open.
    function testWriteOffWithoutFeeKeepsExitsOpen() public {
        assertEq(morpho.fee(id), 0, "the fixture market has no fee");
        _postCollateral(HOLDER, 50e18);

        _writeOffNearlyAllSupply(10_000e18);
        _fillShareTotal(0);

        _forward(60);

        vm.prank(HOLDER);
        morpho.withdrawCollateral(marketParams, 50e18, HOLDER, HOLDER);
        assertEq(collateralToken.balanceOf(HOLDER), 50e18);
    }
}
