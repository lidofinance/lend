// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTestWithController.sol";

import {ILidoLend} from "../../src/interfaces/ILidoLend.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";

/// @dev Tests that verify the arithmetic correctness of `settle`: conversion formulas, rounding
///      directions, ownership/cap boundaries, and share-price invariants after interest accrual.
///      Access control, hook payloads, events, and position-lifecycle tests live in SettleIntegrationTest.
contract SettleMathTest is BaseTestWithController {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    // Kept in memory to avoid stack-too-deep under the no-via-ir profile.
    struct Vars {
        uint256 freeLiquidity;
        uint256 debtCanceled;
        uint256 sliceShares;
        uint256 totalSupplyAssets;
        uint256 totalSupplyShares;
        uint256 totalBorrowAssets;
        uint256 totalBorrowShares;
        uint256 collateralSeized;
        uint256 borrowSharesCanceled;
        uint256 lenderShares;
        uint256 borrowSharesBefore;
        uint256 morphoCollateralBefore;
        uint256 morphoLoanBefore;
        uint256 borrower2DebtBefore;
        uint256 actualSeized;
        uint256 actualCanceled;
        uint256 actualSharesCanceled;
        uint256 actualSharesBurned;
    }

    /* HELPERS */

    /// @dev Extension point: seeds unrelated actors into `params` before the scenario runs. A no-op
    ///      here; SettleMathCrowdedTest (below) overrides it with a matched bystander lender/borrower pair.
    function _seedExtraActors(MarketParams memory params) internal virtual {}

    /// @dev A borrower's debt valued up to loan assets at the market's current index.
    function _debtAssets(Id marketId, address borrower) internal view returns (uint256) {
        return morpho.borrowShares(marketId, borrower)
            .toAssetsUp(morpho.totalBorrowAssets(marketId), morpho.totalBorrowShares(marketId));
    }

    /// @dev Assets-per-share scaled by 1e18 — a readable "share price" for equality checks.
    function _index(uint256 assets, uint256 shares) internal pure returns (uint256) {
        return shares == 0 ? 0 : (assets * 1e18) / shares;
    }

    /* FIXTURES */

    /// @dev Fresh controlled market with settlement enabled, at a 1:1 price. `lltv` makes the id
    ///      distinct from the setUp market's.
    function _freshControlledMarket(uint256 lltv) internal returns (MarketParams memory params, Id marketId) {
        params = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: lltv
        });
        marketId = params.id();
        ControllerMock ctrl = new ControllerMock(marketId);
        vm.prank(OWNER);
        _lido().createMarket(params, address(ctrl), true);
        oracle.setPrice(ORACLE_PRICE_SCALE);
    }

    /// @dev Fresh controlled market with a non-1:1 share:asset rate. Supply == borrow == 40e18 (zero free
    ///      liquidity), ample collateral, then warped `elapsedSeed` (<= 365 days) and accrued. Resets price
    ///      to 1:1 so only share rounding is in play. Pass an `lltv` distinct from the setUp market so the
    ///      id is fresh.
    function _openMarketWithAccruedInterest(uint256 lltv, uint256 elapsedSeed)
        internal
        returns (MarketParams memory params, Id marketId)
    {
        (params, marketId) = _freshControlledMarket(lltv);
        _supplyAs(params, address(this), 40e18);
        _borrowAs(params, BORROWER, 1000e18, 40e18);
        _seedExtraActors(params);

        vm.warp(block.timestamp + bound(elapsedSeed, 1, 365 days));
        morpho.accrueInterest(params);
        assertNotEq(
            morpho.totalSupplyAssets(marketId) * SharesMathLib.VIRTUAL_SHARES,
            morpho.totalSupplyShares(marketId),
            "no accrued interest"
        );
    }

    /// @dev A controlled 1:1 market driven to a drifted index where a borrower's whole holding can no
    ///      longer be cancelled by its asset value: `toAssetsUp(holding)` converted back overshoots the
    ///      holding. Two borrowers make the target debt smaller than the lender's position, so the
    ///      debt-cap does not mask the rounding behavior.
    function _dustyTwoBorrowerMarket() internal returns (MarketParams memory params, Id marketId, address borrower2) {
        // Wei-pinned fixture: deliberately not seeded with extra actors, they would shift the drifted state.
        (params, marketId) = _freshControlledMarket(0.9 ether);
        borrower2 = makeAddr("Borrower2");

        _supplyAs(params, address(this), 12);
        _borrowAs(params, BORROWER, 1e18, 7);
        _borrowAs(params, borrower2, 1e18, 5);

        vm.warp(block.timestamp + 30 days);
        morpho.accrueInterest(params);

        // Pin the drifted state, so an IRM/timing change fails loudly right here.
        assertEq(morpho.totalBorrowAssets(marketId), 13, "drifted total debt");
        assertEq(morpho.totalBorrowShares(marketId), 12 * SharesMathLib.VIRTUAL_SHARES, "total borrow shares");
        assertEq(morpho.borrowShares(marketId, BORROWER), 7 * SharesMathLib.VIRTUAL_SHARES, "BORROWER's shares");
        assertEq(morpho.borrowShares(marketId, borrower2), 5 * SharesMathLib.VIRTUAL_SHARES, "borrower2's shares");
    }

    /* OWNERSHIP AND CAP BOUNDARIES */

    // The lender's supply value equals all free liquidity. The hook returns successfully, and the core accepts
    // the settlement because the lender owns every share being burned.
    function testSettleOwnershipBoundaryIndependentOfFreeLiquidity(uint256 priceSeed) public {
        _setFuzzedPrice(priceSeed);
        _supplyAs(marketParams, SUPPLIER, 100e18);
        _openPosition(10e18, 200e18, 100e18);

        uint256 lenderSharesBefore = morpho.supplyShares(id, address(this));
        uint256 suppliedAssets =
            lenderSharesBefore.toAssetsDown(morpho.totalSupplyAssets(id), morpho.totalSupplyShares(id));
        uint256 freeLiquidity = morpho.totalSupplyAssets(id) - morpho.totalBorrowAssets(id);
        assertEq(suppliedAssets, freeLiquidity, "lender supply equals free liquidity");

        (uint256 seizedAssets, uint256 canceled,, uint256 supplySharesBurned) =
            _lido().settle(marketParams, lenderSharesBefore, 0, address(this), BORROWER, RECEIVER);

        assertEq(seizedAssets, _seizedFor(canceled), "seized collateral");
        assertEq(supplySharesBurned, lenderSharesBefore, "burned all owned shares");
        assertEq(morpho.supplyShares(id, address(this)), 0, "lender shares");
    }

    // Each cap has its own error; the revert string pins which check fired.

    // At an extreme collateral price the seizure `cut * ORACLE_PRICE_SCALE / price` rounds to zero for
    // every cut below one price unit: rejected across the whole rounds-to-zero range, not just at 1 wei.
    function testSettleOverCapZeroCollateral(uint256 cutSeed) public {
        _openPosition(100e18, 200e18, 100e18);
        oracle.setPrice(MAX_COLLATERAL_PRICE);

        uint256 zeroSeizeThreshold = oracle.price() / ORACLE_PRICE_SCALE; // the smallest cut seizing 1 wei
        uint256 cut = bound(cutSeed, 1, zeroSeizeThreshold - 1);
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_SLICE_TOO_SMALL));
        _lido().settle(marketParams, cut * SharesMathLib.VIRTUAL_SHARES, 0, address(this), BORROWER, RECEIVER);
    }

    // Any cut above the collateral's value seizes past the collateral while staying within the debt
    // and owned supply: the collateral cap fires across the whole (collateralValue, borrowed] window,
    // not just at one point.
    function testSettleOverCapCollateral(uint256 cutSeed) public {
        uint256 collateral = 100e18;
        uint256 borrowed = 70e18;
        _openPosition(100e18, collateral, borrowed);
        oracle.setPrice(ORACLE_PRICE_SCALE / 2);

        uint256 collateralValue = collateral.mulDivDown(oracle.price(), ORACLE_PRICE_SCALE);
        uint256 cut = bound(cutSeed, collateralValue + 1, borrowed);
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_COLLATERAL));
        _lido().settle(marketParams, cut * SharesMathLib.VIRTUAL_SHARES, 0, address(this), BORROWER, RECEIVER);
    }

    // The debt cap fires before the ownership check for every cut above the borrower's holding.
    function testSettleOverCapBorrowShares(uint256 cutSeed) public {
        uint256 supplied = 100e18;
        uint256 borrowed = 70e18;
        _openPosition(supplied, 100e18, borrowed);

        uint256 cut = bound(cutSeed, borrowed + 1, supplied);
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_DEBT));
        _lido().settle(marketParams, cut * SharesMathLib.VIRTUAL_SHARES, 0, address(this), BORROWER, RECEIVER);
    }

    // Boundary of the collateral cap: a cut whose seizure equals the borrower's collateral exactly
    // passes, stripping the collateral to zero while the residual debt stays open (only the controller
    // can forbid that).
    function testSettleSeizeExactlyAllCollateral() public {
        uint256 collateral = 100e18;
        uint256 borrowed = 70e18;
        _openPosition(100e18, collateral, borrowed);
        oracle.setPrice(ORACLE_PRICE_SCALE / 2);

        // Cancelling exactly the collateral's value seizes exactly the whole collateral.
        uint256 cut = collateral.mulDivDown(oracle.price(), ORACLE_PRICE_SCALE);
        (uint256 seized,,,) =
            _lido().settle(marketParams, cut * SharesMathLib.VIRTUAL_SHARES, 0, address(this), BORROWER, RECEIVER);

        assertEq(seized, collateral, "seized the whole collateral");
        assertEq(morpho.collateral(id, BORROWER), 0, "collateral stripped to zero");
        assertEq(
            morpho.borrowShares(id, BORROWER),
            (borrowed - cut) * SharesMathLib.VIRTUAL_SHARES,
            "residual debt stays open"
        );
    }

    // Boundary of the slice guard: a cut one wei below one price unit seizes zero and reverts; a cut of
    // exactly one price unit seizes exactly 1 wei and passes.
    function testSettleSliceSeizureBoundary() public {
        _openPosition(100e18, 100e18, 70e18);
        oracle.setPrice(2 * ORACLE_PRICE_SCALE);

        uint256 zeroSeizeThreshold = oracle.price() / ORACLE_PRICE_SCALE; // the smallest cut seizing 1 wei
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_SLICE_TOO_SMALL));
        _lido()
            .settle(
                marketParams,
                (zeroSeizeThreshold - 1) * SharesMathLib.VIRTUAL_SHARES,
                0,
                address(this),
                BORROWER,
                RECEIVER
            );

        (uint256 seized,,,) = _lido()
            .settle(
                marketParams, zeroSeizeThreshold * SharesMathLib.VIRTUAL_SHARES, 0, address(this), BORROWER, RECEIVER
            );
        assertEq(seized, 1, "smallest possible seizure");
    }

    // A borrow-anchored full close can require more supply shares than the lender owns. The required
    // debt is rounded up first, then converted to supply shares rounding up again.
    function testSettleBorrowAnchoredFullCloseExceedsOwnedSupply() public {
        // Wei-pinned scenario: deliberately not seeded with extra actors, they would break the sole-borrower
        // precondition.
        (MarketParams memory params, Id marketId) = _freshControlledMarket(0.7 ether);

        // Sole lender supplies 12, sole borrower borrows the whole 12 (free liquidity 0); drift 12 -> 13.
        _supplyAs(params, address(this), 12);
        _borrowAs(params, BORROWER, 1e18, 12);
        vm.warp(block.timestamp + 30 days);
        morpho.accrueInterest(params);

        uint256 held = morpho.borrowShares(marketId, BORROWER);
        assertEq(held, morpho.totalBorrowShares(marketId), "borrower is the whole pool");
        assertEq(morpho.totalSupplyAssets(marketId), morpho.totalBorrowAssets(marketId), "free liquidity is zero");

        uint256 totalSupplyAssets = morpho.totalSupplyAssets(marketId);
        uint256 totalSupplyShares = morpho.totalSupplyShares(marketId);
        uint256 ownedShares = morpho.supplyShares(marketId, address(this));
        uint256 canceled = held.toAssetsUp(morpho.totalBorrowAssets(marketId), morpho.totalBorrowShares(marketId));
        uint256 requiredSupplyShares = canceled.toSharesUp(totalSupplyAssets, totalSupplyShares);
        assertNotEq(
            totalSupplyAssets * SharesMathLib.VIRTUAL_SHARES, totalSupplyShares, "supply-share price must be non-round"
        );
        assertGt(requiredSupplyShares, ownedShares, "rounded burn exceeds owned shares");

        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_SUPPLY));
        _lido().settle(params, 0, held, address(this), BORROWER, RECEIVER);

        // Supply anchoring burns exactly the owned shares and leaves the virtual-buffer debt dust.
        (, uint256 canceledViaSupply,, uint256 burnedViaSupply) =
            _lido().settle(params, ownedShares, 0, address(this), BORROWER, RECEIVER);
        assertEq(canceledViaSupply, 12, "supply shares cancel all claimable supply");
        assertEq(burnedViaSupply, ownedShares, "burned all owned shares");
        assertEq(morpho.supplyShares(marketId, address(this)), 0, "lender fully exited via supplyShares");
        assertEq(_debtAssets(marketId, BORROWER), 1, "borrower left with the 1-wei buffer dust");
    }

    // Find the largest borrow-share cut whose rounded-up supply burn still fits the lender's position.
    // The next boundary (the full borrower holding) is rejected explicitly instead of underflowing.
    function testSettleBorrowAnchoredMaxCutBurnWithinSupplyFuzz(uint256 elapsed) public {
        (MarketParams memory params, Id marketId) = _openMarketWithAccruedInterest(0.65 ether, elapsed);

        Vars memory vars;
        vars.totalSupplyAssets = morpho.totalSupplyAssets(marketId);
        vars.totalSupplyShares = morpho.totalSupplyShares(marketId);
        vars.totalBorrowAssets = morpho.totalBorrowAssets(marketId);
        vars.totalBorrowShares = morpho.totalBorrowShares(marketId);
        vars.lenderShares = morpho.supplyShares(marketId, address(this));
        vars.borrowSharesBefore = morpho.borrowShares(marketId, BORROWER);

        // Zero free liquidity (fixture): the lender's whole position determines the ownership boundary.
        assertEq(vars.totalSupplyAssets, vars.totalBorrowAssets, "free liquidity is zero");
        uint256 maxDebtCovered = vars.lenderShares.toAssetsDown(vars.totalSupplyAssets, vars.totalSupplyShares);

        // The largest borrow-share cut whose canceled debt (rounded UP) converts back within ownership. The fixture is
        // symmetric (the lender's supply mirrors BORROWER's debt), so it stays within BORROWER's holding.
        vars.borrowSharesCanceled = maxDebtCovered.toSharesDown(vars.totalBorrowAssets, vars.totalBorrowShares);
        vars.debtCanceled = vars.borrowSharesCanceled.toAssetsUp(vars.totalBorrowAssets, vars.totalBorrowShares);
        vars.sliceShares = vars.debtCanceled.toSharesUp(vars.totalSupplyAssets, vars.totalSupplyShares);
        assertLe(vars.sliceShares, vars.lenderShares, "max cut burn fits ownership");

        uint256 fullCloseDebt = vars.borrowSharesBefore.toAssetsUp(vars.totalBorrowAssets, vars.totalBorrowShares);
        uint256 fullCloseBurn = fullCloseDebt.toSharesUp(vars.totalSupplyAssets, vars.totalSupplyShares);
        assertGt(fullCloseBurn, vars.lenderShares, "full close burn exceeds ownership");
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_SUPPLY));
        _lido().settle(params, 0, vars.borrowSharesBefore, address(this), BORROWER, RECEIVER);

        (vars.actualSeized, vars.actualCanceled, vars.actualSharesCanceled, vars.actualSharesBurned) =
            _lido().settle(params, 0, vars.borrowSharesCanceled, address(this), BORROWER, RECEIVER);

        assertEq(vars.actualCanceled, vars.debtCanceled, "return debtCanceled");
        assertEq(vars.actualSeized, _seizedFor(vars.debtCanceled), "return collateralSeized");
        assertEq(vars.actualSharesCanceled, vars.borrowSharesCanceled, "return borrowSharesCanceled");
        assertEq(vars.actualSharesBurned, vars.sliceShares, "return supplySharesBurned");
        assertLe(vars.actualSharesBurned, vars.lenderShares, "burn within ownership");
        assertEq(
            morpho.supplyShares(marketId, address(this)), vars.lenderShares - vars.actualSharesBurned, "lender shares"
        );
        assertEq(morpho.totalSupplyShares(marketId), vars.totalSupplyShares - vars.sliceShares, "total supply shares");
        assertEq(morpho.totalSupplyAssets(marketId), vars.totalSupplyAssets - vars.debtCanceled, "total supply assets");
        assertEq(
            morpho.borrowShares(marketId, BORROWER),
            vars.borrowSharesBefore - vars.borrowSharesCanceled,
            "borrow shares"
        );
        assertEq(collateralToken.balanceOf(RECEIVER), vars.actualSeized, "receiver collateral");
    }

    // A non-round supply index can also land exactly on the ownership boundary. With 25 assets split
    // 13/12 and two units of accrued interest, closing the 13-share borrower burns exactly 13 supply shares.
    function testSettleBorrowAnchoredFullCloseAtExactOwnershipBoundary() public {
        (MarketParams memory params, Id marketId) = _freshControlledMarket(0.775 ether);
        address borrower2 = makeAddr("BoundaryBorrower2");

        _supplyAs(params, address(this), 13);
        _supplyAs(params, SUPPLIER, 12);
        _borrowAs(params, BORROWER, 1e18, 13);
        _borrowAs(params, borrower2, 1e18, 12);
        vm.warp(block.timestamp + 30 days);
        morpho.accrueInterest(params);

        uint256 totalSupplyAssets = morpho.totalSupplyAssets(marketId);
        uint256 totalSupplyShares = morpho.totalSupplyShares(marketId);
        uint256 ownedShares = morpho.supplyShares(marketId, address(this));
        uint256 heldBorrowShares = morpho.borrowShares(marketId, BORROWER);
        uint256 canceled =
            heldBorrowShares.toAssetsUp(morpho.totalBorrowAssets(marketId), morpho.totalBorrowShares(marketId));
        uint256 requiredSupplyShares = canceled.toSharesUp(totalSupplyAssets, totalSupplyShares);

        assertEq(totalSupplyAssets, 27, "interest creates the pinned non-round index");
        assertNotEq(
            totalSupplyAssets * SharesMathLib.VIRTUAL_SHARES, totalSupplyShares, "supply-share price must be non-round"
        );
        assertEq(requiredSupplyShares, ownedShares, "full close lands on ownership boundary");

        (,, uint256 borrowSharesCanceled, uint256 supplySharesBurned) =
            _lido().settle(params, 0, heldBorrowShares, address(this), BORROWER, RECEIVER);

        assertEq(borrowSharesCanceled, heldBorrowShares, "closed all borrower shares");
        assertEq(supplySharesBurned, ownedShares, "burned exactly all owned shares");
        assertEq(morpho.borrowShares(marketId, BORROWER), 0, "borrower closed");
        assertEq(morpho.supplyShares(marketId, address(this)), 0, "lender closed");
    }

    /* EXACT ARITHMETIC */

    // Full arithmetic verification: pins every delta and both rounding directions across fuzzed prices,
    // collateral amounts, and slice sizes.
    function testSettleSuccessFuzz(
        uint256 collateral,
        uint256 borrowed,
        uint256 price,
        uint256 extraSeed,
        uint256 sliceSeed
    ) public {
        (collateral, borrowed, price) = _boundHealthyPosition(collateral, borrowed, price);
        oracle.setPrice(price);

        Vars memory vars;
        // Fuzz free liquidity independently of the core ownership boundary.
        vars.freeLiquidity = bound(extraSeed, 0, borrowed - 1);
        _openPosition(borrowed + vars.freeLiquidity, collateral, borrowed);
        assertEq(
            morpho.totalSupplyAssets(id) - morpho.totalBorrowAssets(id), vars.freeLiquidity, "free liquidity == extra"
        );

        // debtCanceled is deliberately above free liquidity while remaining within debt and ownership.
        vars.debtCanceled = bound(sliceSeed, vars.freeLiquidity + 1, borrowed);
        vars.sliceShares = vars.debtCanceled * SharesMathLib.VIRTUAL_SHARES;

        vars.totalSupplyAssets = morpho.totalSupplyAssets(id);
        vars.totalSupplyShares = morpho.totalSupplyShares(id);
        vars.totalBorrowAssets = morpho.totalBorrowAssets(id);
        vars.totalBorrowShares = morpho.totalBorrowShares(id);

        assertEq(
            vars.sliceShares.toAssetsDown(vars.totalSupplyAssets, vars.totalSupplyShares),
            vars.debtCanceled,
            "slice maps to debtCanceled"
        );

        vars.collateralSeized = _seizedFor(vars.debtCanceled);
        vars.borrowSharesCanceled = vars.debtCanceled.toSharesUp(vars.totalBorrowAssets, vars.totalBorrowShares);
        vm.assume(vars.collateralSeized > 0); // discards only a tiny slice at extreme price

        vars.morphoCollateralBefore = collateralToken.balanceOf(address(morpho));
        vars.morphoLoanBefore = loanToken.balanceOf(address(morpho));
        vars.lenderShares = morpho.supplyShares(id, address(this));
        vars.borrowSharesBefore = morpho.borrowShares(id, BORROWER);

        (vars.actualSeized, vars.actualCanceled, vars.actualSharesCanceled, vars.actualSharesBurned) =
            _lido().settle(marketParams, vars.sliceShares, 0, address(this), BORROWER, RECEIVER);

        // Exact arithmetic (pins rounding direction).
        assertEq(vars.actualCanceled, vars.debtCanceled, "return debtCanceled");
        assertEq(vars.actualSeized, vars.collateralSeized, "return collateralSeized");
        assertEq(vars.actualSharesCanceled, vars.borrowSharesCanceled, "return borrowSharesCanceled");
        assertEq(vars.actualSharesBurned, vars.sliceShares, "return supplySharesBurned");
        assertLe(vars.actualSharesBurned, vars.lenderShares, "burn within ownership");
        assertEq(morpho.supplyShares(id, address(this)), vars.lenderShares - vars.actualSharesBurned, "lender shares");
        assertEq(morpho.totalSupplyShares(id), vars.totalSupplyShares - vars.sliceShares, "total supply shares");
        assertEq(morpho.totalSupplyAssets(id), vars.totalSupplyAssets - vars.debtCanceled, "total supply assets");
        assertEq(
            morpho.borrowShares(id, BORROWER), vars.borrowSharesBefore - vars.borrowSharesCanceled, "borrow shares"
        );
        assertEq(
            morpho.totalBorrowShares(id), vars.totalBorrowShares - vars.borrowSharesCanceled, "total borrow shares"
        );
        assertEq(morpho.totalBorrowAssets(id), vars.totalBorrowAssets - vars.debtCanceled, "total borrow assets");

        // Formula-independent invariants.
        assertEq(
            morpho.totalSupplyAssets(id) - morpho.totalBorrowAssets(id), vars.freeLiquidity, "free liquidity preserved"
        );
        assertEq(collateralToken.balanceOf(RECEIVER), vars.collateralSeized, "receiver got the collateral");
        assertEq(
            collateralToken.balanceOf(address(morpho)),
            vars.morphoCollateralBefore - vars.collateralSeized,
            "morpho collateral"
        );
        assertEq(loanToken.balanceOf(address(morpho)), vars.morphoLoanBefore, "no loan tokens move");
    }

    // Cross-rounding: a drifted share index and a non-par oracle price active together, both return
    // values and every delta pinned exactly (supply anchor).
    function testSettleDriftedIndexWithPriceFuzz(uint256 elapsed, uint256 sliceSeed, uint256 priceSeed) public {
        (MarketParams memory params, Id marketId) = _openMarketWithAccruedInterest(0.45 ether, elapsed);
        _setFuzzedPrice(priceSeed);

        Vars memory vars;
        vars.totalSupplyAssets = morpho.totalSupplyAssets(marketId);
        vars.totalSupplyShares = morpho.totalSupplyShares(marketId);
        vars.totalBorrowAssets = morpho.totalBorrowAssets(marketId);
        vars.totalBorrowShares = morpho.totalBorrowShares(marketId);
        vars.lenderShares = morpho.supplyShares(marketId, address(this));
        vars.borrowSharesBefore = morpho.borrowShares(marketId, BORROWER);

        vars.sliceShares = bound(sliceSeed, 1, vars.lenderShares);
        vars.debtCanceled = vars.sliceShares.toAssetsDown(vars.totalSupplyAssets, vars.totalSupplyShares);
        vars.borrowSharesCanceled = vars.debtCanceled.toSharesUp(vars.totalBorrowAssets, vars.totalBorrowShares);
        vars.collateralSeized = vars.debtCanceled.mulDivDown(ORACLE_PRICE_SCALE, oracle.price());
        vm.assume(vars.collateralSeized > 0);
        vm.assume(vars.borrowSharesCanceled <= vars.borrowSharesBefore);

        (vars.actualSeized, vars.actualCanceled, vars.actualSharesCanceled, vars.actualSharesBurned) =
            _lido().settle(params, vars.sliceShares, 0, address(this), BORROWER, RECEIVER);

        assertEq(vars.actualCanceled, vars.debtCanceled, "return debtCanceled");
        assertEq(vars.actualSeized, vars.collateralSeized, "return collateralSeized");
        assertEq(vars.actualSharesCanceled, vars.borrowSharesCanceled, "return borrowSharesCanceled");
        assertEq(vars.actualSharesBurned, vars.sliceShares, "return supplySharesBurned");
        assertEq(morpho.supplyShares(marketId, address(this)), vars.lenderShares - vars.sliceShares, "lender shares");
        assertEq(morpho.totalSupplyShares(marketId), vars.totalSupplyShares - vars.sliceShares, "total supply shares");
        assertEq(morpho.totalSupplyAssets(marketId), vars.totalSupplyAssets - vars.debtCanceled, "total supply assets");
        assertEq(
            morpho.borrowShares(marketId, BORROWER),
            vars.borrowSharesBefore - vars.borrowSharesCanceled,
            "borrow shares"
        );
        assertEq(
            morpho.totalBorrowShares(marketId),
            vars.totalBorrowShares - vars.borrowSharesCanceled,
            "total borrow shares"
        );
        assertEq(morpho.totalBorrowAssets(marketId), vars.totalBorrowAssets - vars.debtCanceled, "total borrow assets");
        assertEq(collateralToken.balanceOf(RECEIVER), vars.collateralSeized, "receiver collateral");
    }

    // Borrow-anchored PARTIAL cut (strictly within the holding) under a drifted index and fuzzed price:
    // the exact-delta mirror of the close-to-zero tests.
    function testSettleBorrowAnchoredPartialFuzz(uint256 elapsed, uint256 burnSeed, uint256 priceSeed) public {
        (MarketParams memory params, Id marketId) = _openMarketWithAccruedInterest(0.55 ether, elapsed);
        _setFuzzedPrice(priceSeed);

        Vars memory vars;
        vars.totalSupplyAssets = morpho.totalSupplyAssets(marketId);
        vars.totalSupplyShares = morpho.totalSupplyShares(marketId);
        vars.totalBorrowAssets = morpho.totalBorrowAssets(marketId);
        vars.totalBorrowShares = morpho.totalBorrowShares(marketId);
        vars.lenderShares = morpho.supplyShares(marketId, address(this));
        vars.borrowSharesBefore = morpho.borrowShares(marketId, BORROWER);

        vars.borrowSharesCanceled = bound(burnSeed, 1, vars.borrowSharesBefore - 1);
        vars.debtCanceled = vars.borrowSharesCanceled.toAssetsUp(vars.totalBorrowAssets, vars.totalBorrowShares);
        vars.sliceShares = vars.debtCanceled.toSharesUp(vars.totalSupplyAssets, vars.totalSupplyShares);
        vars.collateralSeized = vars.debtCanceled.mulDivDown(ORACLE_PRICE_SCALE, oracle.price());
        vm.assume(vars.collateralSeized > 0);
        vm.assume(vars.sliceShares <= vars.lenderShares);

        (vars.actualSeized, vars.actualCanceled, vars.actualSharesCanceled, vars.actualSharesBurned) =
            _lido().settle(params, 0, vars.borrowSharesCanceled, address(this), BORROWER, RECEIVER);

        assertEq(vars.actualCanceled, vars.debtCanceled, "return debtCanceled");
        assertEq(vars.actualSeized, vars.collateralSeized, "return collateralSeized");
        assertEq(vars.actualSharesCanceled, vars.borrowSharesCanceled, "return borrowSharesCanceled");
        assertEq(vars.actualSharesBurned, vars.sliceShares, "return supplySharesBurned");
        assertLe(vars.actualSharesBurned, vars.lenderShares, "burn within ownership");
        assertEq(
            morpho.supplyShares(marketId, address(this)), vars.lenderShares - vars.actualSharesBurned, "lender shares"
        );
        assertEq(morpho.totalSupplyShares(marketId), vars.totalSupplyShares - vars.sliceShares, "total supply shares");
        assertEq(morpho.totalSupplyAssets(marketId), vars.totalSupplyAssets - vars.debtCanceled, "total supply assets");
        assertEq(
            morpho.borrowShares(marketId, BORROWER),
            vars.borrowSharesBefore - vars.borrowSharesCanceled,
            "borrow shares"
        );
        assertEq(
            morpho.totalBorrowShares(marketId),
            vars.totalBorrowShares - vars.borrowSharesCanceled,
            "total borrow shares"
        );
        assertEq(morpho.totalBorrowAssets(marketId), vars.totalBorrowAssets - vars.debtCanceled, "total borrow assets");
        assertEq(collateralToken.balanceOf(RECEIVER), vars.collateralSeized, "receiver collateral");
    }

    // Settle by SHARES: the burned debt shares, valued back to assets, must equal the cancelled debt exactly;
    // an under-burn (the pool-draining direction) would value back to debtCanceled - 1.
    function testSettleShareRoundingWithInterestFuzz(uint256 elapsed, uint256 sliceSeed) public {
        (MarketParams memory params, Id marketId) = _openMarketWithAccruedInterest(0.5 ether, elapsed);

        Vars memory vars;
        vars.totalSupplyAssets = morpho.totalSupplyAssets(marketId);
        vars.totalSupplyShares = morpho.totalSupplyShares(marketId);
        vars.totalBorrowAssets = morpho.totalBorrowAssets(marketId);
        vars.totalBorrowShares = morpho.totalBorrowShares(marketId);
        vars.lenderShares = morpho.supplyShares(marketId, address(this));
        vars.sliceShares = bound(sliceSeed, 1, vars.lenderShares);
        // Skip zero-debt slices.
        vm.assume(vars.sliceShares.toAssetsDown(vars.totalSupplyAssets, vars.totalSupplyShares) > 0);

        vars.borrowSharesBefore = morpho.borrowShares(marketId, BORROWER);
        (vars.actualSeized, vars.actualCanceled, vars.actualSharesCanceled, vars.actualSharesBurned) =
            _lido().settle(params, vars.sliceShares, 0, address(this), BORROWER, RECEIVER);
        uint256 borrowSharesBurned = vars.borrowSharesBefore - morpho.borrowShares(marketId, BORROWER);

        assertEq(
            morpho.supplyShares(marketId, address(this)), vars.lenderShares - vars.sliceShares, "supply burned == input"
        );
        assertEq(
            borrowSharesBurned.toAssetsDown(vars.totalBorrowAssets, vars.totalBorrowShares),
            vars.actualCanceled,
            "burned debt valued back == cancelled debt"
        );
        assertEq(vars.actualSeized, vars.actualCanceled, "seized == cancelled at 1:1");

        assertEq(morpho.totalSupplyShares(marketId), vars.totalSupplyShares - vars.sliceShares, "total supply shares");
        assertEq(
            morpho.totalSupplyAssets(marketId), vars.totalSupplyAssets - vars.actualCanceled, "total supply assets"
        );
        assertEq(morpho.totalBorrowShares(marketId), vars.totalBorrowShares - borrowSharesBurned, "total borrow shares");
        assertEq(
            morpho.totalBorrowAssets(marketId), vars.totalBorrowAssets - vars.actualCanceled, "total borrow assets"
        );
        assertEq(collateralToken.balanceOf(RECEIVER), vars.actualSeized, "receiver collateral");
    }

    // Settle to a target asset amount: the burned supply shares, valued back to assets, must equal the
    // cancelled debt exactly; an under-burn would value back to debtCanceled - 1.
    function testSettleAssetTargetRoundingWithInterestFuzz(uint256 elapsed, uint256 assetsSeed) public {
        (MarketParams memory params, Id marketId) = _openMarketWithAccruedInterest(0.625 ether, elapsed);

        Vars memory vars;
        vars.totalSupplyAssets = morpho.totalSupplyAssets(marketId);
        vars.totalSupplyShares = morpho.totalSupplyShares(marketId);
        vars.lenderShares = morpho.supplyShares(marketId, address(this));
        vars.debtCanceled =
            bound(assetsSeed, 1, vars.lenderShares.toAssetsDown(vars.totalSupplyAssets, vars.totalSupplyShares));
        vm.assume(vars.debtCanceled.toSharesUp(vars.totalSupplyAssets, vars.totalSupplyShares) <= vars.lenderShares);

        (, vars.actualCanceled,,) = _lido()
            .settle(
                params,
                vars.debtCanceled.toSharesUp(vars.totalSupplyAssets, vars.totalSupplyShares),
                0,
                address(this),
                BORROWER,
                RECEIVER
            );
        uint256 supplySharesBurned = vars.lenderShares - morpho.supplyShares(marketId, address(this));

        assertEq(vars.actualCanceled, vars.debtCanceled, "cancelled debt == asset target");
        assertEq(
            supplySharesBurned.toAssetsDown(vars.totalSupplyAssets, vars.totalSupplyShares),
            vars.debtCanceled,
            "burned supply valued back == cancelled debt"
        );
        assertEq(morpho.totalSupplyShares(marketId), vars.totalSupplyShares - supplySharesBurned, "total supply shares");
        assertEq(morpho.totalSupplyAssets(marketId), vars.totalSupplyAssets - vars.debtCanceled, "total supply assets");
    }

    /* ACCRUAL */

    // settle must realize pending interest itself (it calls _accrueInterest before computing the cut).
    function testSettleAccruesInterest() public {
        (MarketParams memory params, Id marketId) = _openMarketWithAccruedInterest(0.75 ether, 30 days);

        uint256 staleUpdate = morpho.lastUpdate(marketId);
        vm.warp(block.timestamp + 30 days);
        assertEq(morpho.lastUpdate(marketId), staleUpdate, "precondition: interest pending, unrealized");

        // Post-accrual totals: the cut must be derived from these, not from the stale ones.
        (uint256 expTSA, uint256 expTSS,,) = morpho.expectedMarketBalances(params);
        uint256 slice = uint256(1e18).toSharesUp(expTSA, expTSS);

        (, uint256 canceled,,) = _lido().settle(params, slice, 0, address(this), BORROWER, RECEIVER);

        assertEq(morpho.lastUpdate(marketId), block.timestamp, "settle realized pending interest");
        assertEq(canceled, slice.toAssetsDown(expTSA, expTSS), "cut derived from post-accrual totals");
    }

    /* POSITION CLOSURE */

    // The borrow-share anchor closes a borrower's whole position even when its asset value cannot. On a
    // drifted index `toAssetsUp(holding)` converts back (UP or DOWN) to more shares than held, so a
    // value-anchored cut reverts SETTLEMENT_EXCEEDS_DEBT; passing the holding as `borrowShares` burns it
    // exactly and zeroes the position.
    function testSettleClosePositionRoundsBurnPastHolding() public {
        (MarketParams memory params, Id marketId, address borrower2) = _dustyTwoBorrowerMarket();

        Vars memory v;
        v.totalBorrowAssets = morpho.totalBorrowAssets(marketId);
        v.totalBorrowShares = morpho.totalBorrowShares(marketId);
        uint256 held = morpho.borrowShares(marketId, BORROWER); // 7e6

        // The holding's asset value, converted back, overshoots the holding in BOTH directions.
        uint256 fullDebt = held.toAssetsUp(v.totalBorrowAssets, v.totalBorrowShares); // 8
        assertEq(fullDebt, 8, "fullDebt valued up");
        assertEq(
            fullDebt.toSharesUp(v.totalBorrowAssets, v.totalBorrowShares),
            7_428_572,
            "toSharesUp overshoots the 7e6 holding"
        );
        assertEq(
            fullDebt.toSharesDown(v.totalBorrowAssets, v.totalBorrowShares),
            7_428_571,
            "toSharesDown overshoots too (direction irrelevant)"
        );

        // A value-anchored cut (a supply slice worth fullDebt) reverts on the debt-cap.
        {
            uint256 valueSlice =
                fullDebt.toSharesUp(morpho.totalSupplyAssets(marketId), morpho.totalSupplyShares(marketId));
            vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_DEBT));
            _lido().settle(params, valueSlice, 0, address(this), BORROWER, RECEIVER);
        }

        // The borrow-share anchor closes BORROWER to exactly zero.
        v.totalSupplyAssets = morpho.totalSupplyAssets(marketId);
        v.totalSupplyShares = morpho.totalSupplyShares(marketId);
        v.lenderShares = morpho.supplyShares(marketId, address(this));
        v.borrower2DebtBefore = _debtAssets(marketId, borrower2); // borrower2 debt valued up: 6

        (v.actualSeized, v.actualCanceled,,) = _lido().settle(params, 0, held, address(this), BORROWER, RECEIVER);

        assertEq(morpho.borrowShares(marketId, BORROWER), 0, "BORROWER closed to zero");
        assertEq(v.actualCanceled, fullDebt, "canceled == toAssetsUp(holding)");
        assertEq(v.actualSeized, _seizedFor(fullDebt), "seized == cut at oracle price");
        assertEq(morpho.totalBorrowShares(marketId), v.totalBorrowShares - held, "total borrow shares -= holding");
        assertEq(
            morpho.totalBorrowAssets(marketId),
            v.totalBorrowAssets - v.actualCanceled,
            "total borrow assets -= canceled"
        );
        assertEq(
            v.lenderShares - morpho.supplyShares(marketId, address(this)),
            v.actualCanceled.toSharesUp(v.totalSupplyAssets, v.totalSupplyShares),
            "supply burn derived from the cut"
        );

        // The remaining borrower keeps its shares; its debt drifts 6 -> 5 because the closer absorbed the
        // round-up (paid 8 for a ~7.58 position). borrower2 now owns the whole remaining pool.
        assertEq(
            morpho.borrowShares(marketId, borrower2), 5 * SharesMathLib.VIRTUAL_SHARES, "borrower2 shares untouched"
        );
        assertEq(v.borrower2DebtBefore, 6, "borrower2 debt before close");
        assertEq(_debtAssets(marketId, borrower2), 5, "borrower2 debt after close (closer ate the round-up)");
        assertEq(
            _debtAssets(marketId, borrower2), morpho.totalBorrowAssets(marketId), "borrower2 owns the remaining pool"
        );

        // --- rounding ledger: who pays, who receives -----------------------------------------
        // Before the cut the borrowers' rounded-up debts overcount the pool by 1 (8 + 6 = 14 > 13). That
        // overlapping wei is exactly what a value-anchored close could never land on.
        assertEq(fullDebt + v.borrower2DebtBefore, 14, "rounded-up debts sum to 14, overcounting the 13-wei pool");
        // The closing lender PAYS: burns the full 8 (toSharesUp) for BORROWER's ~7.58-fair holding.
        // borrower2 RECEIVES: 1 wei of relief (6 -> 5). Nothing is minted.
        assertEq(v.borrower2DebtBefore - _debtAssets(marketId, borrower2), 1, "borrower2 relieved by 1 wei");

        // --- borrow / supply share price, before vs after ------------
        // Borrow index deflates (borrowers relieved), supply index inflates (remaining lenders
        // enriched) — both corollaries of the exact deltas pinned above and below.
        assertEq(
            v.totalSupplyShares - morpho.totalSupplyShares(marketId),
            v.actualCanceled.toSharesUp(v.totalSupplyAssets, v.totalSupplyShares),
            "total supply shares -= derived burn"
        );

        // --- solvency ------------------------------------------------------------------------
        // Supply and borrow assets fall by the same `canceled`, so free liquidity is invariant and the
        // protocol stays solvent (supply >= borrow). No value is created or destroyed.
        assertEq(
            v.totalSupplyAssets - morpho.totalSupplyAssets(marketId), v.actualCanceled, "supply assets -= canceled"
        );
        assertEq(
            v.totalBorrowAssets - morpho.totalBorrowAssets(marketId), v.actualCanceled, "borrow assets -= canceled"
        );
        assertEq(
            v.totalSupplyAssets - v.totalBorrowAssets,
            morpho.totalSupplyAssets(marketId) - morpho.totalBorrowAssets(marketId),
            "free liquidity preserved"
        );
    }

    // The supply-share anchor accepts exactly all owned shares and rejects one share more. The borrower's
    // debt exceeds the lender's position, so the ownership check is the active boundary.
    function testSettleSupplyAnchoredOwnershipBoundary() public {
        (MarketParams memory params, Id marketId) = _freshControlledMarket(0.85 ether);

        // Two lenders (`stake` each); one borrower owes both stakes (free liquidity 0). The borrower's
        // debt exceeds our lender's supply, so the lender exits fully without hitting the debt-cap.
        uint256 stake = 50;
        _supplyAs(params, address(this), stake);
        _supplyAs(params, makeAddr("LenderB"), stake);
        _borrowAs(params, BORROWER, 1e18, 2 * stake);

        _seedExtraActors(params);

        uint256 tsa = morpho.totalSupplyAssets(marketId);
        uint256 tba = morpho.totalBorrowAssets(marketId);
        uint256 tbs = morpho.totalBorrowShares(marketId);
        uint256 borrowerDebtBefore = _debtAssets(marketId, BORROWER); // 100

        uint256 all = morpho.supplyShares(marketId, address(this));
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_EXCEEDS_SUPPLY));
        _lido().settle(params, all + 1, 0, address(this), BORROWER, RECEIVER);

        (, uint256 canceled,, uint256 supplySharesBurned) =
            _lido().settle(params, all, 0, address(this), BORROWER, RECEIVER);

        assertEq(supplySharesBurned, all, "burned exactly all owned shares");
        assertEq(morpho.supplyShares(marketId, address(this)), 0, "lender fully exited");
        assertEq(canceled, stake, "cancelled the lender's whole supply value");
        // The borrower is left half-settled: shares and debt both halved, position still open.
        assertEq(
            morpho.borrowShares(marketId, BORROWER), stake * SharesMathLib.VIRTUAL_SHARES, "borrower shares halved"
        );
        assertEq(_debtAssets(marketId, BORROWER), stake, "borrower debt halved");

        // --- solvency (clean: 1:1 with no accrual leaves no rounding) -------------------------
        assertEq(borrowerDebtBefore, 2 * stake, "borrower owed both stakes before");
        assertEq(tsa - morpho.totalSupplyAssets(marketId), canceled, "supply assets -= canceled");
        assertEq(tba - morpho.totalBorrowAssets(marketId), canceled, "borrow assets -= canceled");
        assertEq(
            tsa - tba,
            morpho.totalSupplyAssets(marketId) - morpho.totalBorrowAssets(marketId),
            "free liquidity preserved"
        );

        // The exit removes supply and borrow proportionally, so the borrow share price is unchanged.
        assertEq(
            _index(tba, tbs),
            _index(morpho.totalBorrowAssets(marketId), morpho.totalBorrowShares(marketId)),
            "borrow share price unchanged"
        );
    }

    // The borrow-share anchor does not bypass the collateral guard: a dust debt at a high price still
    // reverts SLICE_TOO_SMALL because the seized collateral rounds to zero.
    function testSettleCloseBlockedWhenSeizeRoundsToZero() public {
        (MarketParams memory params, Id marketId,) = _dustyTwoBorrowerMarket();
        oracle.setPrice(MAX_COLLATERAL_PRICE);

        uint256 held = morpho.borrowShares(marketId, BORROWER);
        vm.expectRevert(bytes(ErrorsLib.SETTLEMENT_SLICE_TOO_SMALL));
        _lido().settle(params, 0, held, address(this), BORROWER, RECEIVER);
    }
}

/// @notice Reruns every SettleMathTest scenario with a bystander lender and a bystander borrower
///         seeded into the market: the lender supplies `CROWD_AMOUNT` and the borrower borrows it
///         back, leaving free liquidity and the share rate unchanged while the market's totals no
///         longer belong to the scenario's own lender and borrower alone.
contract SettleMathCrowdedTest is SettleMathTest {
    uint256 internal constant CROWD_AMOUNT = 1234e18 + 567; // deliberately non-round

    address internal CROWD_LENDER = makeAddr("CrowdLender");
    address internal CROWD_BORROWER = makeAddr("CrowdBorrower");

    function setUp() public override {
        super.setUp();
        _seedExtraActors(marketParams);
    }

    function _seedExtraActors(MarketParams memory params) internal override {
        _supplyAs(params, CROWD_LENDER, CROWD_AMOUNT);
        _borrowAs(params, CROWD_BORROWER, 4 * CROWD_AMOUNT, CROWD_AMOUNT);
    }
}
