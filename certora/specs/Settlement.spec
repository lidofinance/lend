// SPDX-License-Identifier: GPL-2.0-or-later

using Util as Util;

methods {
    function extSloads(bytes32[]) external returns bytes32[] => NONDET DELETE;

    function supplyShares(MorphoHarness.Id, address) external returns uint256 envfree;
    function borrowShares(MorphoHarness.Id, address) external returns uint256 envfree;
    function collateral(MorphoHarness.Id, address) external returns uint256 envfree;
    function totalSupplyAssets(MorphoHarness.Id) external returns uint256 envfree;
    function totalSupplyShares(MorphoHarness.Id) external returns uint256 envfree;
    function totalBorrowAssets(MorphoHarness.Id) external returns uint256 envfree;
    function totalBorrowShares(MorphoHarness.Id) external returns uint256 envfree;
    function virtualTotalBorrowAssets(MorphoHarness.Id) external returns uint256 envfree;
    function virtualTotalBorrowShares(MorphoHarness.Id) external returns uint256 envfree;
    function lastUpdate(MorphoHarness.Id) external returns uint256 envfree;
    function marketController(MorphoHarness.Id) external returns address envfree;
    function isSettlementEnabled(MorphoHarness.Id) external returns bool envfree;
    function hookInProgress() external returns bool envfree;

    function isHealthy(MorphoHarness.MarketParams, address user) external returns bool envfree;

    function Util.libId(MorphoHarness.MarketParams) external returns MorphoHarness.Id envfree;
    function Util.wad() external returns uint256 envfree;
    function Util.libMulDivDown(uint256, uint256, uint256) external returns uint256 envfree;
    function Util.oraclePriceScale() external returns uint256 envfree;
    function Util.toSharesUp(uint256, uint256, uint256) external returns uint256 envfree;
    function Util.toAssetsUp(uint256, uint256, uint256) external returns uint256 envfree;
    function Util.toAssetsDown(uint256, uint256, uint256) external returns uint256 envfree;

    function SafeTransferLib.safeTransfer(address token, address to, uint256 value) internal => NONDET;
    function _.price() external => oraclePrice expect uint256;
    function _.on(bytes32 id, uint8 hookEvent, bytes data) external
        => controllerOn(id, hookEvent, data) expect void;
}

persistent ghost uint256 oraclePrice;
persistent ghost bool controllerShouldRevert;
persistent ghost bool controllerWasCalled;
persistent ghost uint8 lastControllerHookEvent;

function controllerOn(bytes32 id, uint8 hookEvent, bytes data) {
    assert hookInProgress();
    controllerWasCalled = true;
    lastControllerHookEvent = hookEvent;
    if (controllerShouldRevert) {
        revert("controller rejected");
    }
}

// Settlement burns the exact debt-share input and applies the rounded-up supply burn exactly.
rule settleAccounting(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 borrowSharesInput,
    address onBehalf,
    address borrower,
    address receiver
) {
    MorphoHarness.Id id = Util.libId(marketParams);
    require !controllerShouldRevert;
    require lastUpdate(id) == e.block.timestamp;
    require e.msg.sender == onBehalf;

    uint256 lenderSharesBefore = supplyShares(id, onBehalf);
    uint256 borrowerSharesBefore = borrowShares(id, borrower);
    uint256 collateralBefore = collateral(id, borrower);
    uint256 supplyAssetsBefore = totalSupplyAssets(id);
    uint256 supplySharesBefore = totalSupplyShares(id);
    uint256 borrowAssetsBefore = totalBorrowAssets(id);
    uint256 borrowSharesBefore = totalBorrowShares(id);

    uint256 collateralSeized;
    uint256 borrowAssetsCanceled;
    uint256 borrowSharesCanceled;
    uint256 supplySharesBurned;
    collateralSeized, borrowAssetsCanceled, borrowSharesCanceled, supplySharesBurned =
        settle(e, marketParams, borrowSharesInput, onBehalf, borrower, receiver);

    assert borrowSharesCanceled == borrowSharesInput;
    assert supplySharesBurned <= lenderSharesBefore;
    assert borrowSharesCanceled <= borrowerSharesBefore;
    assert collateralSeized <= collateralBefore;
    assert to_mathint(supplyShares(id, onBehalf))
        == to_mathint(lenderSharesBefore) - to_mathint(supplySharesBurned);
    assert to_mathint(borrowShares(id, borrower))
        == to_mathint(borrowerSharesBefore) - to_mathint(borrowSharesCanceled);
    assert to_mathint(collateral(id, borrower))
        == to_mathint(collateralBefore) - to_mathint(collateralSeized);
    assert to_mathint(totalSupplyAssets(id))
        == to_mathint(supplyAssetsBefore) - to_mathint(borrowAssetsCanceled);
    assert to_mathint(totalSupplyShares(id))
        == to_mathint(supplySharesBefore) - to_mathint(supplySharesBurned);
    // Valuing the cut up can put `borrowAssetsCanceled` one unit above the debt total, which the core
    // applies with a zero floor, so the debt side removes the floored amount.
    mathint borrowAssetsRemoved = to_mathint(borrowAssetsCanceled) > to_mathint(borrowAssetsBefore)
        ? to_mathint(borrowAssetsBefore)
        : to_mathint(borrowAssetsCanceled);
    assert to_mathint(totalBorrowAssets(id)) == to_mathint(borrowAssetsBefore) - borrowAssetsRemoved;
    assert to_mathint(totalBorrowShares(id))
        == to_mathint(borrowSharesBefore) - to_mathint(borrowSharesCanceled);
    // The supply side always removes the full amount, so free liquidity is preserved except for whatever
    // the debt-side floor withheld.
    assert to_mathint(totalSupplyAssets(id)) - to_mathint(totalBorrowAssets(id))
        == to_mathint(supplyAssetsBefore) - to_mathint(borrowAssetsBefore)
            - (to_mathint(borrowAssetsCanceled) - borrowAssetsRemoved);
}

// The exact borrow-share cut is checked against its actual rounded-up supply burn.
rule settleRejectsRoundedBurnAboveOwnership(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 borrowSharesInput,
    address onBehalf,
    address borrower,
    address receiver
) {
    MorphoHarness.Id id = Util.libId(marketParams);
    uint256 supplyAssets = totalSupplyAssets(id);
    uint256 supplySharesTotal = totalSupplyShares(id);
    uint256 borrowAssets = totalBorrowAssets(id);
    uint256 borrowSharesTotal = totalBorrowShares(id);
    uint256 ownedShares = supplyShares(id, onBehalf);
    uint256 borrowerShares = borrowShares(id, borrower);

    require e.msg.value == 0;
    require e.msg.sender == onBehalf;
    require receiver != 0 && marketParams.oracle != 0;
    require lastUpdate(id) == e.block.timestamp;
    require lastUpdate(id) != 0;
    require isSettlementEnabled(id) && marketController(id) != 0;
    require !hookInProgress() && !controllerShouldRevert && !controllerWasCalled;
    require borrowerShares > 0 && borrowSharesInput == borrowerShares;
    require borrowerShares == borrowSharesTotal;
    require ownedShares > 0 && ownedShares == supplySharesTotal;
    require supplyAssets * 10^6 != supplySharesTotal;

    uint256 canceled = Util.toAssetsUp(borrowSharesInput, borrowAssets, borrowSharesTotal);
    uint256 requiredSupplyShares = Util.toSharesUp(canceled, supplyAssets, supplySharesTotal);
    uint256 seizeBasis = Util.toAssetsDown(borrowSharesInput, borrowAssets, borrowSharesTotal);
    uint256 seized = Util.libMulDivDown(seizeBasis, Util.oraclePriceScale(), oraclePrice);
    require requiredSupplyShares > ownedShares;
    require canceled > 0 && canceled <= supplyAssets && canceled <= borrowAssets;
    require oraclePrice > 0 && seized > 0 && seized <= collateral(id, borrower);

    settle@withrevert(e, marketParams, borrowSharesInput, onBehalf, borrower, receiver);

    assert lastReverted;
    assert !controllerWasCalled;
}

// A full close succeeds when its rounded-up supply burn lands exactly on ownership.
rule settleAtOwnershipBoundary(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 borrowSharesInput,
    address onBehalf,
    address borrower,
    address receiver
) {
    MorphoHarness.Id id = Util.libId(marketParams);
    uint256 supplyAssets = totalSupplyAssets(id);
    uint256 supplySharesTotal = totalSupplyShares(id);
    uint256 borrowAssets = totalBorrowAssets(id);
    uint256 borrowSharesTotal = totalBorrowShares(id);
    uint256 ownedShares = supplyShares(id, onBehalf);
    uint256 borrowerShares = borrowShares(id, borrower);

    require e.msg.value == 0;
    require e.msg.sender == onBehalf;
    require receiver != 0 && marketParams.oracle != 0;
    require lastUpdate(id) != 0 && lastUpdate(id) == e.block.timestamp;
    require isSettlementEnabled(id) && marketController(id) != 0;
    require !hookInProgress() && !controllerShouldRevert && !controllerWasCalled;
    require borrowerShares > 0 && borrowSharesInput == borrowerShares;
    require borrowerShares <= borrowSharesTotal;
    require ownedShares > 0 && ownedShares <= supplySharesTotal;
    require supplyAssets * 10^6 != supplySharesTotal;

    uint256 canceled = Util.toAssetsUp(borrowSharesInput, borrowAssets, borrowSharesTotal);
    uint256 requiredSupplyShares = Util.toSharesUp(canceled, supplyAssets, supplySharesTotal);
    uint256 seizeBasis = Util.toAssetsDown(borrowSharesInput, borrowAssets, borrowSharesTotal);
    uint256 seized = Util.libMulDivDown(seizeBasis, Util.oraclePriceScale(), oraclePrice);
    require requiredSupplyShares == ownedShares;
    require canceled > 0 && canceled <= supplyAssets && canceled <= borrowAssets;
    require oraclePrice > 0 && seized > 0 && seized <= collateral(id, borrower);

    settle@withrevert(e, marketParams, borrowSharesInput, onBehalf, borrower, receiver);

    assert !lastReverted;
    assert controllerWasCalled && lastControllerHookEvent == 8;
    assert supplyShares(id, onBehalf) == 0;
    assert borrowShares(id, borrower) == 0;
}

// When the hook returns, an affordable exact borrow-share cut is independent of free market liquidity.
rule settlementIndependentOfFreeLiquidity(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 borrowSharesInput,
    address onBehalf,
    address borrower,
    address receiver
) {
    MorphoHarness.Id id = Util.libId(marketParams);
    uint256 supplyAssets = totalSupplyAssets(id);
    uint256 supplySharesTotal = totalSupplyShares(id);
    uint256 borrowAssets = totalBorrowAssets(id);
    uint256 borrowSharesTotal = totalBorrowShares(id);
    uint256 ownedShares = supplyShares(id, onBehalf);
    uint256 debtShares = borrowShares(id, borrower);

    require e.msg.value == 0;
    require e.msg.sender == onBehalf;
    require receiver != 0;
    require marketParams.oracle != 0;
    require lastUpdate(id) != 0 && lastUpdate(id) == e.block.timestamp;
    require isSettlementEnabled(id) && marketController(id) != 0;
    require !hookInProgress() && !controllerShouldRevert && !controllerWasCalled;
    require borrowSharesInput > 0 && borrowSharesInput <= debtShares;
    require ownedShares <= supplySharesTotal;
    require debtShares <= borrowSharesTotal;
    require supplyAssets >= borrowAssets;
    require Util.toAssetsDown(ownedShares, supplyAssets, supplySharesTotal) == supplyAssets - borrowAssets;

    uint256 canceled = Util.toAssetsUp(borrowSharesInput, borrowAssets, borrowSharesTotal);
    uint256 requiredSupplyShares = Util.toSharesUp(canceled, supplyAssets, supplySharesTotal);
    uint256 seizeBasis = Util.toAssetsDown(borrowSharesInput, borrowAssets, borrowSharesTotal);
    uint256 seized = Util.libMulDivDown(seizeBasis, Util.oraclePriceScale(), oraclePrice);
    require canceled > 0 && canceled <= supplyAssets && canceled <= borrowAssets;
    require requiredSupplyShares <= ownedShares;
    require oraclePrice > 0 && seized > 0 && seized <= collateral(id, borrower);

    settle@withrevert(e, marketParams, borrowSharesInput, onBehalf, borrower, receiver);

    assert !lastReverted;
    assert controllerWasCalled && lastControllerHookEvent == 8;
}

// A controller veto reaches the Settle hook and rolls back every core accounting slot.
rule settleControllerRevertIsAtomic(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 borrowSharesInput,
    address onBehalf,
    address borrower,
    address receiver
) {
    MorphoHarness.Id id = Util.libId(marketParams);
    uint256 supplyAssets = totalSupplyAssets(id);
    uint256 supplySharesTotal = totalSupplyShares(id);
    uint256 borrowAssets = totalBorrowAssets(id);
    uint256 borrowSharesTotal = totalBorrowShares(id);
    uint256 lenderShares = supplyShares(id, onBehalf);
    uint256 borrowerShares = borrowShares(id, borrower);
    uint256 borrowerCollateral = collateral(id, borrower);

    require e.msg.value == 0;
    require e.msg.sender == onBehalf;
    require receiver != 0;
    require marketParams.oracle != 0;
    require lastUpdate(id) != 0 && lastUpdate(id) == e.block.timestamp;
    require isSettlementEnabled(id) && marketController(id) != 0;
    require !hookInProgress();
    require controllerShouldRevert && !controllerWasCalled;
    require borrowSharesInput > 0 && borrowSharesInput <= borrowerShares;
    require lenderShares <= supplySharesTotal;
    require borrowerShares <= borrowSharesTotal;

    uint256 canceled = Util.toAssetsUp(borrowSharesInput, borrowAssets, borrowSharesTotal);
    uint256 requiredSupplyShares = Util.toSharesUp(canceled, supplyAssets, supplySharesTotal);
    uint256 seizeBasis = Util.toAssetsDown(borrowSharesInput, borrowAssets, borrowSharesTotal);
    uint256 seized = Util.libMulDivDown(seizeBasis, Util.oraclePriceScale(), oraclePrice);
    require canceled > 0 && canceled <= supplyAssets && canceled <= borrowAssets;
    require requiredSupplyShares <= lenderShares;
    require oraclePrice > 0 && seized > 0 && seized <= borrowerCollateral;

    settle@withrevert(e, marketParams, borrowSharesInput, onBehalf, borrower, receiver);

    assert lastReverted;
    assert controllerWasCalled && lastControllerHookEvent == 8;
    assert supplyShares(id, onBehalf) == lenderShares;
    assert borrowShares(id, borrower) == borrowerShares;
    assert collateral(id, borrower) == borrowerCollateral;
    assert totalSupplyAssets(id) == supplyAssets;
    assert totalSupplyShares(id) == supplySharesTotal;
    assert totalBorrowAssets(id) == borrowAssets;
    assert totalBorrowShares(id) == borrowSharesTotal;
}

// Passing the borrower's whole holding takes its debt position to zero. This is the guarantee the borrow
// anchor exists for, so it is pinned directly rather than inferred from the accounting deltas.
rule settleFullCloseZeroesPosition(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 borrowSharesInput,
    address onBehalf,
    address borrower,
    address receiver
) {
    MorphoHarness.Id id = Util.libId(marketParams);

    // Assumption to ensure that no interest is accumulated.
    require lastUpdate(id) == e.block.timestamp;
    require !controllerShouldRevert;
    require borrowSharesInput == borrowShares(id, borrower);

    settle(e, marketParams, borrowSharesInput, onBehalf, borrower, receiver);

    assert borrowShares(id, borrower) == 0;
}

// `settle` never turns a bystander unhealthy. Its collateral is untouched and the borrow index only falls,
// so its debt can only shrink.
rule settleKeepsBystanderHealthy(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 borrowSharesInput,
    address onBehalf,
    address borrower,
    address receiver
) {
    MorphoHarness.Id id = Util.libId(marketParams);
    address user;
    require user != borrower;

    // Assume the invariant initially.
    require isHealthy(marketParams, user);

    // Safe require because of the invariants onlyEnabledLltv and lltvSmallerThanWad in ConsistentState.spec.
    require marketParams.lltv < Util.wad();
    // Assumption to ensure that no interest is accumulated.
    require lastUpdate(id) == e.block.timestamp;
    require !controllerShouldRevert;

    settle(e, marketParams, borrowSharesInput, onBehalf, borrower, receiver);

    // Safe require because of the invariant sumBorrowSharesCorrect.
    require borrowShares(id, user) <= totalBorrowShares(id);

    assert isHealthy(marketParams, user);
}

// A settle never worsens the settled borrower's debt-to-collateral ratio. Stated by cross-multiplication so
// no division reaches the solver, which is what puts the `isHealthy` formulation out of reach. Modelled on
// liquidateImprovePosition in LiquidateBuffer.spec.
rule settleImprovePosition(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 borrowSharesInput,
    address onBehalf,
    address borrower,
    address receiver
) {
    MorphoHarness.Id id = Util.libId(marketParams);

    // Place ourselves at the last block, so no interest accrues.
    require lastUpdate(id) == e.block.timestamp;
    require !controllerShouldRevert;

    uint256 borrowerShares = borrowShares(id, borrower);
    // Safe require because of the sumBorrowSharesCorrect invariant.
    require borrowerShares <= totalBorrowShares(id);

    uint256 borrowerCollateral = collateral(id, borrower);
    uint256 virtualTotalAssets = virtualTotalBorrowAssets(id);
    uint256 virtualTotalShares = virtualTotalBorrowShares(id);

    // Let borrowerAssets = borrowerShares * virtualTotalAssets / virtualTotalShares
    // and borrowerCollateralQuoted = borrowerCollateral * oraclePrice / Util.oraclePriceScale()
    // then the following line is the assumption borrowerAssets < borrowerCollateralQuoted, which is
    // solvency at the settlement incentive factor of one.
    require borrowerCollateral * oraclePrice * virtualTotalShares
        > borrowerShares * Util.oraclePriceScale() * virtualTotalAssets;

    uint256 seizedAssets;
    seizedAssets, _, _, _ = settle(e, marketParams, borrowSharesInput, onBehalf, borrower, receiver);

    uint256 newBorrowerShares = borrowShares(id, borrower);
    uint256 newBorrowerCollateral = collateral(id, borrower);
    uint256 canceledShares = assert_uint256(borrowerShares - newBorrowerShares);

    // Hint for the prover about the ratio used to cut the position, which follows from solvency above.
    assert canceledShares * borrowerCollateral >= seizedAssets * borrowerShares;
    // The ratio of debt shares over collateral does not grow.
    assert borrowerShares * newBorrowerCollateral >= newBorrowerShares * borrowerCollateral;
}
