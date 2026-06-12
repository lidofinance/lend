// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";

import {IMorphoBase} from "../../src/interfaces/IMorpho.sol";
import {ILidoBlue} from "../../src/interfaces/ILidoBlue.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {ReentrantControllerMock} from "../../src/mocks/ReentrantControllerMock.sol";

/// @dev The controller hook runs under a transient reentrancy lock checked inside `_hook`: while a
///      hook executes, reentering any of the nine hooked entrypoints reverts with HOOK_REENTRANCY
///      (`flashLoan` dispatches no hook and is deliberately not locked). Each test arms a reentrant
///      call that would be valid on its own (positions pre-funded; the controller funded, approved,
///      and authorized), so only the lock can stop it — and arms it into the same entrypoint under
///      test, so every entrypoint's lock check is pinned individually.
contract ReentrancyIntegrationTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using MorphoLib for IMorpho;

    MarketParams internal dp;
    Id internal did;
    ReentrantControllerMock internal rc;

    function _lido() internal view returns (ILidoBlue) {
        return ILidoBlue(address(morpho));
    }

    /// @dev Arms the reentrant call and asserts the hook actually dispatches it (a negative control:
    ///      the test stays meaningful even if the outer call later reverts for some unrelated reason).
    function _armAndExpect(bytes memory reentry) internal {
        rc.arm(reentry);
        vm.expectCall(address(morpho), reentry);
    }

    function setUp() public override {
        super.setUp();
        // `irm == 0` gives an id distinct from the default (irm) market; bound to the reentrant controller.
        dp = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(0),
            lltv: DEFAULT_TEST_LLTV
        });
        did = dp.id();
        rc = new ReentrantControllerMock(did, address(morpho));
        vm.prank(OWNER);
        _lido().createMarket(dp, address(rc), true);

        // Worst case: the controller is fully funded/approved and authorized to act for the lender.
        loanToken.setBalance(address(rc), 1e30);
        collateralToken.setBalance(address(rc), 1e30);
        vm.startPrank(address(rc));
        loanToken.approve(address(morpho), type(uint256).max);
        collateralToken.approve(address(morpho), type(uint256).max);
        vm.stopPrank();
        morpho.setAuthorization(address(rc), true);
    }

    function testReentrancySupplyBlocked() public {
        loanToken.setBalance(address(this), 10e18);

        _armAndExpect(abi.encodeCall(IMorphoBase.supply, (dp, 1e18, 0, address(rc), hex"")));
        vm.expectRevert(bytes(ErrorsLib.HOOK_REENTRANCY));
        morpho.supply(dp, 10e18, 0, address(this), hex"");
    }

    function testReentrancyWithdrawBlocked() public {
        loanToken.setBalance(address(this), 100e18);
        morpho.supply(dp, 100e18, 0, address(this), hex"");

        _armAndExpect(abi.encodeCall(IMorphoBase.withdraw, (dp, 1e18, 0, address(this), address(this))));
        vm.expectRevert(bytes(ErrorsLib.HOOK_REENTRANCY));
        morpho.withdraw(dp, 10e18, 0, address(this), address(this));
    }

    function testReentrancyBorrowBlocked() public {
        loanToken.setBalance(address(this), 100e18);
        morpho.supply(dp, 100e18, 0, address(this), hex"");
        collateralToken.setBalance(address(this), 100e18);
        morpho.supplyCollateral(dp, 100e18, address(this), hex""); // maxBorrow = 80e18

        _armAndExpect(abi.encodeCall(IMorphoBase.borrow, (dp, 10e18, 0, address(this), address(this))));
        vm.expectRevert(bytes(ErrorsLib.HOOK_REENTRANCY));
        morpho.borrow(dp, 10e18, 0, address(this), address(this));
    }

    function testReentrancyRepayBlocked() public {
        loanToken.setBalance(address(this), 100e18);
        morpho.supply(dp, 100e18, 0, address(this), hex"");
        collateralToken.setBalance(address(this), 100e18);
        morpho.supplyCollateral(dp, 100e18, address(this), hex"");
        morpho.borrow(dp, 50e18, 0, address(this), address(this)); // debt 50e18

        _armAndExpect(abi.encodeCall(IMorphoBase.repay, (dp, 10e18, 0, address(this), hex"")));
        vm.expectRevert(bytes(ErrorsLib.HOOK_REENTRANCY));
        morpho.repay(dp, 10e18, 0, address(this), hex"");
    }

    function testReentrancySupplyCollateralBlocked() public {
        collateralToken.setBalance(address(this), 10e18);

        _armAndExpect(abi.encodeCall(IMorphoBase.supplyCollateral, (dp, 1e18, address(rc), hex"")));
        vm.expectRevert(bytes(ErrorsLib.HOOK_REENTRANCY));
        morpho.supplyCollateral(dp, 10e18, address(this), hex"");
    }

    function testReentrancyWithdrawCollateralBlocked() public {
        collateralToken.setBalance(address(this), 100e18);
        morpho.supplyCollateral(dp, 100e18, address(this), hex"");

        _armAndExpect(abi.encodeCall(IMorphoBase.withdrawCollateral, (dp, 1e18, address(this), address(this))));
        vm.expectRevert(bytes(ErrorsLib.HOOK_REENTRANCY));
        morpho.withdrawCollateral(dp, 10e18, address(this), address(this));
    }

    function testReentrancyLiquidateBlocked() public {
        loanToken.setBalance(address(this), 100e18);
        morpho.supply(dp, 100e18, 0, address(this), hex"");
        collateralToken.setBalance(BORROWER, 100e18);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(dp, 100e18, BORROWER, hex"");
        morpho.borrow(dp, 70e18, 0, BORROWER, BORROWER);
        vm.stopPrank();
        oracle.setPrice(ORACLE_PRICE_SCALE / 2); // unhealthy

        _armAndExpect(abi.encodeCall(IMorphoBase.liquidate, (dp, BORROWER, 10e18, 0, hex"")));
        loanToken.setBalance(address(this), 100e18);
        vm.expectRevert(bytes(ErrorsLib.HOOK_REENTRANCY));
        morpho.liquidate(dp, BORROWER, 10e18, 0, hex"");
    }

    function testReentrancyAccrueInterestBlocked() public {
        bytes memory reentry = abi.encodeCall(IMorphoBase.accrueInterest, (dp));
        rc.arm(reentry);
        // The outer call has identical calldata, so the dispatch control expects two matching calls.
        vm.expectCall(address(morpho), reentry, 2);
        vm.expectRevert(bytes(ErrorsLib.HOOK_REENTRANCY));
        morpho.accrueInterest(dp);
    }

    function testReentrancyDeleverageBlockedEvenWithinLimits() public {
        loanToken.setBalance(address(this), 100e18);
        morpho.supply(dp, 100e18, 0, address(this), hex"");
        collateralToken.setBalance(BORROWER, 200e18);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(dp, 200e18, BORROWER, hex"");
        morpho.borrow(dp, 100e18, 0, BORROWER, BORROWER); // free liquidity 0
        vm.stopPrank();

        // Pre-lock, two in-limit 0.3 slices both applied cleanly; the lock blocks the reentrant one.
        uint256 slice = 30e18 * SharesMathLib.VIRTUAL_SHARES;
        _armAndExpect(abi.encodeCall(ILidoBlue.redeemCollateral, (dp, slice, BORROWER, address(this), RECEIVER)));
        vm.expectRevert(bytes(ErrorsLib.HOOK_REENTRANCY));
        _lido().redeemCollateral(dp, slice, BORROWER, address(this), RECEIVER);
    }

    function testHooklessMarketActionAllowedDuringHook() public {
        loanToken.setBalance(address(this), 110e18);
        morpho.supply(dp, 100e18, 0, address(this), hex"");

        // The gate is scoped to controlled markets: an action on a market with no controller is never
        // gated, even mid-hook, and behaves exactly as upstream.
        _armAndExpect(abi.encodeCall(IMorphoBase.supply, (marketParams, 1e18, 0, address(rc), hex"")));
        morpho.supply(dp, 10e18, 0, address(this), hex"");

        assertEq(morpho.supplyShares(id, address(rc)), 1e18 * SharesMathLib.VIRTUAL_SHARES, "hookless supply applied");
        assertEq(morpho.supplyShares(did, address(this)), 110e18 * SharesMathLib.VIRTUAL_SHARES, "outer supply applied");
    }

    function testFlashLoanAllowedDuringHook() public {
        loanToken.setBalance(address(this), 110e18);
        morpho.supply(dp, 100e18, 0, address(this), hex"");

        // flashLoan dispatches no hook and touches no market or position state, so it is deliberately
        // not locked: the armed reentry succeeds mid-hook and the outer supply completes.
        _armAndExpect(abi.encodeCall(IMorphoBase.flashLoan, (address(loanToken), 1e18, hex"")));
        morpho.supply(dp, 10e18, 0, address(this), hex"");

        assertEq(morpho.supplyShares(did, address(this)), 110e18 * SharesMathLib.VIRTUAL_SHARES, "supply applied");
        assertEq(loanToken.balanceOf(address(morpho)), 110e18, "flash loan netted to zero");
    }

    function testCallbackAfterHookCanReenter() public {
        // The lock spans only the controller call: a Morpho callback, issued after the hook completed
        // and the state was written, can still reenter (the upstream leverage pattern).
        loanToken.setBalance(address(this), 100e18);
        morpho.supply(dp, 100e18, 0, address(this), hex"");
        collateralToken.setBalance(address(this), 100e18);

        morpho.supplyCollateral(dp, 100e18, address(this), abi.encode(uint256(10e18)));

        assertEq(morpho.collateral(did, address(this)), 100e18, "collateral credited");
        assertEq(
            morpho.borrowShares(did, address(this)),
            10e18 * SharesMathLib.VIRTUAL_SHARES,
            "borrow from the callback applied"
        );
    }

    function onMorphoSupplyCollateral(uint256, bytes calldata data) external {
        uint256 borrowAssets = abi.decode(data, (uint256));
        morpho.borrow(dp, borrowAssets, 0, address(this), address(this));
    }
}
