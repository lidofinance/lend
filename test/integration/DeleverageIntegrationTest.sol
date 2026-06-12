// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTestWithController.sol";

import {ILidoBlue} from "../../src/interfaces/ILidoBlue.sol";
import {ILidoBlueMarketController} from "../../src/interfaces/ILidoBlueMarketController.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";

contract DeleverageIntegrationTest is BaseTestWithController {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    // Kept in memory to avoid stack-too-deep under the no-via-ir profile (cf. upstream LiquidateTestParams).
    struct Vars {
        uint256 avail;
        uint256 debtCanceled;
        uint256 sliceShares;
        uint256 tSA;
        uint256 tSS;
        uint256 tBA;
        uint256 tBS;
        uint256 collateralSeized;
        uint256 borrowSharesToBurn;
        uint256 lenderShares;
        uint256 borrowSharesBefore;
        uint256 morphoCollatBefore;
        uint256 morphoLoanBefore;
        uint256 retSeized;
        uint256 retCanceled;
    }

    function _lido() internal view returns (ILidoBlue) {
        return ILidoBlue(address(morpho));
    }

    function _openPosition(uint256 supplied, uint256 collateral, uint256 borrowed) internal {
        _supply(supplied);
        collateralToken.setBalance(BORROWER, collateral);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(marketParams, collateral, BORROWER, hex"");
        morpho.borrow(marketParams, borrowed, 0, BORROWER, BORROWER);
        vm.stopPrank();
    }

    function testDeleverageMarketNotCreated(MarketParams memory mp) public {
        vm.assume(neq(mp, marketParams));
        vm.expectRevert(bytes(ErrorsLib.MARKET_NOT_CREATED));
        _lido().deleverage(mp, 1, BORROWER, address(this), RECEIVER);
    }

    function testDeleverageDisabled() public {
        // The default BaseTest market (non-zero IRM, no controller) was created without deleverage.
        MarketParams memory base = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: DEFAULT_TEST_LLTV
        });
        vm.expectRevert(bytes(ErrorsLib.DELEVERAGE_DISABLED));
        _lido().deleverage(base, 1, BORROWER, address(this), RECEIVER);
    }

    function testDeleverageZeroShares() public {
        vm.expectRevert(bytes(ErrorsLib.ZERO_SHARES));
        _lido().deleverage(marketParams, 0, BORROWER, address(this), RECEIVER);
    }

    function testDeleverageZeroReceiver() public {
        vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
        _lido().deleverage(marketParams, 1, BORROWER, address(this), address(0));
    }

    function testDeleverageUnauthorized() public {
        vm.prank(RECEIVER); // not authorized for onBehalf == BORROWER
        vm.expectRevert(bytes(ErrorsLib.UNAUTHORIZED));
        _lido().deleverage(marketParams, 1, BORROWER, BORROWER, RECEIVER);
    }

    function testDeleverageIneligibleBorrower() public {
        _openPosition(100e18, 200e18, 100e18);
        uint256 supplyShares = morpho.supplyShares(id, address(this)) / 2;
        // Target ONBEHALF, who never borrowed → no debt.
        vm.expectRevert(bytes(ErrorsLib.DELEVERAGE_NO_DEBT));
        _lido().deleverage(marketParams, supplyShares, ONBEHALF, address(this), RECEIVER);
    }

    function testDeleverageLiquidityGateBoundary() public {
        _openPosition(100e18, 100e18, 70e18);
        uint256 avail = morpho.totalSupplyAssets(id) - morpho.totalBorrowAssets(id);
        assertEq(avail, 30e18, "avail");

        // debtCanceled == avail must revert (the gate requires strictly greater).
        vm.expectRevert(bytes(ErrorsLib.DELEVERAGE_LIQUIDITY_AVAILABLE));
        _lido().deleverage(marketParams, avail * SharesMathLib.VIRTUAL_SHARES, BORROWER, address(this), RECEIVER);

        // debtCanceled == avail + 1 clears the gate and executes: at 1:1 it seizes exactly avail + 1.
        uint256 sharesBefore = morpho.supplyShares(id, address(this));
        uint256 slice = (avail + 1) * SharesMathLib.VIRTUAL_SHARES;
        (uint256 seized,) = _lido().deleverage(marketParams, slice, BORROWER, address(this), RECEIVER);
        assertEq(seized, avail + 1, "seized exactly the cancelled debt at 1:1");
        assertEq(morpho.supplyShares(id, address(this)), sharesBefore - slice, "lender shares reduced by the slice");
    }

    // Each cap now has its own error, so the revert string alone pins which check fired.

    function testDeleverageOverCapZeroCollateral() public {
        _openPosition(100e18, 200e18, 100e18);
        oracle.setPrice(MAX_COLLATERAL_PRICE);
        // debtCanceled == 1 → collateralSeized = 1 * SCALE / 1e40 rounds to 0.
        vm.expectRevert(bytes(ErrorsLib.DELEVERAGE_SLICE_TOO_SMALL));
        _lido().deleverage(marketParams, 1 * SharesMathLib.VIRTUAL_SHARES, BORROWER, address(this), RECEIVER);
    }

    function testDeleverageOverCapCollateral() public {
        _openPosition(100e18, 100e18, 70e18);
        oracle.setPrice(ORACLE_PRICE_SCALE / 2); // collateral now worth 50e18
        // debtCanceled 60e18 → collateralSeized 120e18 > 100e18 collateral.
        vm.expectRevert(bytes(ErrorsLib.DELEVERAGE_EXCEEDS_COLLATERAL));
        _lido().deleverage(marketParams, 60e18 * SharesMathLib.VIRTUAL_SHARES, BORROWER, address(this), RECEIVER);
    }

    function testDeleverageOverCapBorrowShares() public {
        _openPosition(100e18, 100e18, 70e18);
        // debtCanceled 80e18 → burns more than the 70e18 debt (collateralSeized 80e18 <= 100e18 collateral).
        vm.expectRevert(bytes(ErrorsLib.DELEVERAGE_EXCEEDS_DEBT));
        _lido().deleverage(marketParams, 80e18 * SharesMathLib.VIRTUAL_SHARES, BORROWER, address(this), RECEIVER);
    }

    function testDeleverageCannotCancelMoreThanOwned() public {
        // A large supplier provides most liquidity; the lender (address(this)) holds only a small slice.
        loanToken.setBalance(SUPPLIER, 100e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 100e18, 0, SUPPLIER, hex"");
        _openPosition(10e18, 200e18, 100e18);

        // Pass more shares than the lender owns; the slice still clears every cap (big borrower).
        uint256 lenderShares = morpho.supplyShares(id, address(this));
        uint256 tooMany = lenderShares + 1e18 * SharesMathLib.VIRTUAL_SHARES;
        vm.expectRevert(stdError.arithmeticError);
        _lido().deleverage(marketParams, tooMany, BORROWER, address(this), RECEIVER);
    }

    function testDeleverageAuthorizedViaApproval() public {
        _openPosition(100e18, 100e18, 70e18);
        morpho.setAuthorization(RECEIVER, true);

        uint256 sharesBefore = morpho.supplyShares(id, address(this));
        uint256 supplyShares = sharesBefore / 2;

        vm.prank(RECEIVER);
        _lido().deleverage(marketParams, supplyShares, BORROWER, address(this), RECEIVER);

        assertEq(morpho.supplyShares(id, address(this)), sharesBefore - supplyShares, "lender shares reduced");
    }

    function testDeleverageBorrowerExitsWhole(uint256 supplied, uint256 sliceSeed) public {
        supplied = bound(supplied, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT / 2);
        uint256 collateral = 2 * supplied;
        _openPosition(supplied, collateral, supplied); // supply == borrow → free liquidity 0

        uint256 lenderShares = morpho.supplyShares(id, address(this));
        uint256 slice = bound(sliceSeed, lenderShares / 4, (lenderShares * 3) / 4);
        (uint256 seized, uint256 canceled) = _lido().deleverage(marketParams, slice, BORROWER, address(this), RECEIVER);
        assertEq(seized, canceled, "fair 1:1 swap"); // price is 1:1
        assertEq(morpho.collateral(id, BORROWER), collateral - seized, "borrower collateral debited by the seizure");

        // The borrower clears the residual debt and pulls out the remaining collateral.
        vm.startPrank(BORROWER);
        loanToken.setBalance(BORROWER, supplied);
        morpho.repay(marketParams, 0, morpho.borrowShares(id, BORROWER), BORROWER, hex"");
        morpho.withdrawCollateral(marketParams, morpho.collateral(id, BORROWER), BORROWER, BORROWER);
        vm.stopPrank();

        // Whole: recovered the unseized collateral, no residual debt, no stuck collateral.
        assertEq(collateralToken.balanceOf(BORROWER), collateral - seized, "borrower recovered the rest");
        assertEq(morpho.borrowShares(id, BORROWER), 0, "no residual debt");
        assertEq(morpho.collateral(id, BORROWER), 0, "no stuck collateral");
    }

    function testDeleverageFullDrainLeavesMarketUsable(uint256 supplied) public {
        supplied = bound(supplied, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT / 2);
        uint256 collateral = 2 * supplied;
        _openPosition(supplied, collateral, supplied); // sole lender, supply == borrow → free liquidity 0

        uint256 allShares = morpho.supplyShares(id, address(this));
        (uint256 seized,) = _lido().deleverage(marketParams, allShares, BORROWER, address(this), RECEIVER);

        // Cancelling the entire stake zeroes the market exactly: at a single first supply, totalShares ==
        // assets * VIRTUAL_SHARES, so the cancellation leaves no rounding remainder.
        assertEq(seized, supplied, "seized the whole supply at 1:1");
        assertEq(morpho.totalSupplyShares(id), 0, "supply shares zeroed");
        assertEq(morpho.totalSupplyAssets(id), 0, "supply assets zeroed");
        assertEq(morpho.totalBorrowShares(id), 0, "borrow shares zeroed");
        assertEq(morpho.totalBorrowAssets(id), 0, "borrow assets zeroed");
        assertEq(morpho.collateral(id, BORROWER), collateral - seized, "borrower keeps the unseized collateral");

        // Not bricked: a fresh deposit into the zeroed market round-trips exactly.
        uint256 fresh = MIN_TEST_AMOUNT;
        loanToken.setBalance(address(this), fresh);
        morpho.supply(marketParams, fresh, 0, address(this), hex"");
        morpho.withdraw(marketParams, 0, morpho.supplyShares(id, address(this)), address(this), address(this));
        assertEq(loanToken.balanceOf(address(this)), fresh, "fresh deposit round-trips exactly");
    }

    function testDeleverageSelfPosition(uint256 supplied, uint256 sliceSeed) public {
        supplied = bound(supplied, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT / 2);
        uint256 collateral = 2 * supplied;
        _supply(supplied); // address(this) lends
        collateralToken.setBalance(address(this), collateral);
        morpho.supplyCollateral(marketParams, collateral, address(this), hex"");
        morpho.borrow(marketParams, supplied, 0, address(this), address(this)); // and borrows → free liquidity 0

        uint256 supplyBefore = morpho.supplyShares(id, address(this));
        uint256 borrowBefore = morpho.borrowShares(id, address(this));
        uint256 tBABefore = morpho.totalBorrowAssets(id);
        uint256 tBSBefore = morpho.totalBorrowShares(id);

        // onBehalf == borrower == address(this).
        uint256 slice = bound(sliceSeed, supplyBefore / 4, (supplyBefore * 3) / 4);
        (uint256 seized, uint256 canceled) =
            _lido().deleverage(marketParams, slice, address(this), address(this), RECEIVER);
        assertEq(seized, canceled, "fair 1:1 swap");

        uint256 burn = canceled.toSharesUp(tBABefore, tBSBefore);
        assertEq(morpho.supplyShares(id, address(this)), supplyBefore - slice, "self: supply shares burned");
        assertEq(morpho.borrowShares(id, address(this)), borrowBefore - burn, "self: debt shares burned");
        assertEq(morpho.collateral(id, address(this)), collateral - seized, "self: collateral seized");
        assertEq(collateralToken.balanceOf(RECEIVER), seized, "receiver got the seized collateral");
    }

    function testDeleverageControllerCanBlock() public {
        _openPosition(100e18, 100e18, 70e18);
        controller.setRevertOn(ILidoBlueMarketController.HookEvent.Deleverage, true);
        uint256 supplyShares = morpho.supplyShares(id, address(this)) / 2;
        vm.expectRevert(bytes("controller: blocked"));
        _lido().deleverage(marketParams, supplyShares, BORROWER, address(this), RECEIVER);
    }

    function testDeleverageHookPayload() public {
        _openPosition(100e18, 100e18, 70e18);
        uint256 supplyShares = morpho.supplyShares(id, address(this)) / 2;
        uint256 expectedCanceled = supplyShares.toAssetsDown(morpho.totalSupplyAssets(id), morpho.totalSupplyShares(id));
        uint256 expectedSeized = expectedCanceled.mulDivDown(ORACLE_PRICE_SCALE, oracle.price());

        _lido().deleverage(marketParams, supplyShares, BORROWER, address(this), RECEIVER);

        ILidoBlueMarketController.DeleverageHookData memory d =
            abi.decode(controller.lastData(), (ILidoBlueMarketController.DeleverageHookData));
        assertEq(d.caller, address(this), "caller");
        assertEq(d.onBehalf, address(this), "onBehalf");
        assertEq(d.borrower, BORROWER, "borrower");
        assertEq(d.receiver, RECEIVER, "receiver");
        assertEq(d.assetsToCancel, expectedCanceled, "assetsToCancel");
        assertEq(d.collateralSeized, expectedSeized, "collateralSeized");
    }

    function testDeleverageSuccessFuzz(
        uint256 collateral,
        uint256 borrowed,
        uint256 price,
        uint256 extraSeed,
        uint256 sliceSeed
    ) public {
        (collateral, borrowed, price) = _boundHealthyPosition(collateral, borrowed, price);
        oracle.setPrice(price);

        Vars memory v;
        // Fuzz both regimes: free liquidity = avail ∈ [0, borrowed-1] < borrowed (cancel window non-empty).
        v.avail = bound(extraSeed, 0, borrowed - 1);
        _openPosition(borrowed + v.avail, collateral, borrowed);
        assertEq(morpho.totalSupplyAssets(id) - morpho.totalBorrowAssets(id), v.avail, "free liquidity == extra");

        // debtCanceled ∈ (avail, borrowed]: clears the gate, within the borrower's debt and (healthy) collateral.
        v.debtCanceled = bound(sliceSeed, v.avail + 1, borrowed);
        v.sliceShares = v.debtCanceled * SharesMathLib.VIRTUAL_SHARES;

        v.tSA = morpho.totalSupplyAssets(id);
        v.tSS = morpho.totalSupplyShares(id);
        v.tBA = morpho.totalBorrowAssets(id);
        v.tBS = morpho.totalBorrowShares(id);

        assertEq(v.sliceShares.toAssetsDown(v.tSA, v.tSS), v.debtCanceled, "slice maps to debtCanceled");

        v.collateralSeized = v.debtCanceled.mulDivDown(ORACLE_PRICE_SCALE, price);
        v.borrowSharesToBurn = v.debtCanceled.toSharesUp(v.tBA, v.tBS);
        vm.assume(v.collateralSeized > 0); // discards only a tiny slice at extreme price

        v.morphoCollatBefore = collateralToken.balanceOf(address(morpho));
        v.morphoLoanBefore = loanToken.balanceOf(address(morpho));
        v.lenderShares = morpho.supplyShares(id, address(this));
        v.borrowSharesBefore = morpho.borrowShares(id, BORROWER);

        (v.retSeized, v.retCanceled) =
            _lido().deleverage(marketParams, v.sliceShares, BORROWER, address(this), RECEIVER);

        // Exact arithmetic (pins rounding direction).
        assertEq(v.retCanceled, v.debtCanceled, "return debtCanceled");
        assertEq(v.retSeized, v.collateralSeized, "return collateralSeized");
        assertEq(morpho.supplyShares(id, address(this)), v.lenderShares - v.sliceShares, "lender shares");
        assertEq(morpho.totalSupplyShares(id), v.tSS - v.sliceShares, "total supply shares");
        assertEq(morpho.totalSupplyAssets(id), v.tSA - v.debtCanceled, "total supply assets");
        assertEq(morpho.borrowShares(id, BORROWER), v.borrowSharesBefore - v.borrowSharesToBurn, "borrow shares");
        assertEq(morpho.totalBorrowShares(id), v.tBS - v.borrowSharesToBurn, "total borrow shares");
        assertEq(morpho.totalBorrowAssets(id), v.tBA - v.debtCanceled, "total borrow assets");

        // Formula-independent invariants.
        assertEq(morpho.totalSupplyAssets(id) - morpho.totalBorrowAssets(id), v.avail, "free liquidity preserved");
        assertEq(collateralToken.balanceOf(RECEIVER), v.collateralSeized, "receiver got the collateral");
        assertEq(
            collateralToken.balanceOf(address(morpho)), v.morphoCollatBefore - v.collateralSeized, "morpho collateral"
        );
        assertEq(loanToken.balanceOf(address(morpho)), v.morphoLoanBefore, "no loan tokens move");
    }

    // With a non-enforcing controller, deleverage leaves bad debt unrealized — preventing this is the
    // controller's responsibility; the core has no in-core backstop (unlike `liquidate`).
    function testDeleverageBadDebtNotRealizedFuzz(
        uint256 collateral,
        uint256 borrowed,
        uint256 priceSeed,
        uint256 sliceSeed
    ) public {
        (collateral, borrowed,) = _boundHealthyPosition(collateral, borrowed, ORACLE_PRICE_SCALE);
        _openPosition(borrowed, collateral, borrowed); // free liquidity 0, sole supplier/borrower

        // Drop into the underwater range: collateralValue < debt ⟺ price < borrowed*SCALE/collateral.
        uint256 underwaterCap = borrowed.mulDivDown(ORACLE_PRICE_SCALE, collateral);
        vm.assume(underwaterCap > MIN_COLLATERAL_PRICE);
        uint256 newPrice = bound(priceSeed, MIN_COLLATERAL_PRICE, underwaterCap - 1);
        oracle.setPrice(newPrice);

        uint256 collateralValue = collateral.mulDivDown(newPrice, ORACLE_PRICE_SCALE);
        vm.assume(collateralValue > 1);
        // Cancel within the collateral value (so collateralSeized <= collateral) and below the debt → residual.
        uint256 debtCanceled = bound(sliceSeed, 1, collateralValue);
        uint256 collateralSeized = debtCanceled.mulDivDown(ORACLE_PRICE_SCALE, newPrice);
        vm.assume(collateralSeized > 0 && collateralSeized <= collateral);
        uint256 sliceShares = debtCanceled * SharesMathLib.VIRTUAL_SHARES;

        uint256 tSA = morpho.totalSupplyAssets(id);

        _lido().deleverage(marketParams, sliceShares, BORROWER, address(this), RECEIVER);

        // The loss is NOT socialized: total supply fell only by the canceled amount, though this slice came out
        // of an underwater position. `liquidate` would have written `totalSupplyAssets` down here; deleverage does not.
        assertEq(morpho.totalSupplyAssets(id), tSA - debtCanceled, "no bad-debt write-down");
        assertGt(morpho.borrowShares(id, BORROWER), 0, "residual debt remains");
        // We do NOT assert the residual stays under-collateralized: collateralSeized rounds down, so at small
        // amounts the rounding slack can heal it to solvent. The hazard is the missing write-down, not the residual.
    }

    // The inherited market is irm==0, where the share:asset ratio stays exactly 1:VIRTUAL_SHARES and
    // toAssetsDown/toSharesUp never round. A fresh interest-bearing market + time warp skews the ratio so the
    // share rounding is actually exercised (price stays 1:1 to isolate it from the price-based rounding).
    function testDeleverageShareRoundingWithInterestFuzz(uint256 elapsed, uint256 sliceSeed) public {
        uint256 lltv = 0.5 ether; // distinct from the inherited (0.8) and base markets → fresh id
        MarketParams memory mp = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: lltv
        });
        Id mid = mp.id();
        ControllerMock c = new ControllerMock(mid);
        vm.prank(OWNER);
        _lido().createMarket(mp, address(c), true);

        // supplied == borrowed → free liquidity stays 0 through interest. Ample collateral headroom.
        uint256 collateral = 1000e18;
        uint256 borrowed = 40e18;
        loanToken.setBalance(address(this), borrowed);
        morpho.supply(mp, borrowed, 0, address(this), hex"");
        collateralToken.setBalance(BORROWER, collateral);
        vm.startPrank(BORROWER);
        morpho.supplyCollateral(mp, collateral, BORROWER, hex"");
        morpho.borrow(mp, borrowed, 0, BORROWER, BORROWER);
        vm.stopPrank();

        // Accrue a fuzzed amount of interest, then realize it now so the test reads what deleverage will use.
        elapsed = bound(elapsed, 1, 365 days);
        vm.warp(block.timestamp + elapsed);
        morpho.accrueInterest(mp);

        Vars memory v;
        v.tSA = morpho.totalSupplyAssets(mid);
        v.tSS = morpho.totalSupplyShares(mid);
        v.tBA = morpho.totalBorrowAssets(mid);
        v.tBS = morpho.totalBorrowShares(mid);
        assertGt(v.tSA, v.tSS / SharesMathLib.VIRTUAL_SHARES, "supply ratio skewed by interest");

        v.lenderShares = morpho.supplyShares(mid, address(this));
        v.sliceShares = bound(sliceSeed, 1, v.lenderShares);

        v.debtCanceled = v.sliceShares.toAssetsDown(v.tSA, v.tSS);
        vm.assume(v.debtCanceled > 0);
        // Caps hold by construction: tSA == tBA (so borrowSharesToBurn <= debt) and tSA < collateral.
        v.collateralSeized = v.debtCanceled.mulDivDown(ORACLE_PRICE_SCALE, oracle.price());
        v.borrowSharesToBurn = v.debtCanceled.toSharesUp(v.tBA, v.tBS);

        v.borrowSharesBefore = morpho.borrowShares(mid, BORROWER);

        (v.retSeized, v.retCanceled) = _lido().deleverage(mp, v.sliceShares, BORROWER, address(this), RECEIVER);

        // Exact arithmetic on a skewed ratio — pins toAssetsDown / toSharesUp rounding direction.
        assertEq(v.retCanceled, v.debtCanceled, "debtCanceled via toAssetsDown");
        assertEq(v.retSeized, v.collateralSeized, "collateralSeized");
        assertEq(morpho.supplyShares(mid, address(this)), v.lenderShares - v.sliceShares, "lender shares");
        assertEq(morpho.totalSupplyShares(mid), v.tSS - v.sliceShares, "total supply shares");
        assertEq(morpho.totalSupplyAssets(mid), v.tSA - v.debtCanceled, "total supply assets");
        assertEq(
            morpho.borrowShares(mid, BORROWER),
            v.borrowSharesBefore - v.borrowSharesToBurn,
            "borrow shares via toSharesUp"
        );
        assertEq(morpho.totalBorrowShares(mid), v.tBS - v.borrowSharesToBurn, "total borrow shares");
        assertEq(morpho.totalBorrowAssets(mid), v.tBA - v.debtCanceled, "total borrow assets");
        assertEq(collateralToken.balanceOf(RECEIVER), v.collateralSeized, "receiver collateral");
    }
}
