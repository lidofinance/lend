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
    function lastUpdate(MorphoHarness.Id) external returns uint256 envfree;
    function marketController(MorphoHarness.Id) external returns address envfree;
    function isSettlementEnabled(MorphoHarness.Id) external returns bool envfree;
    function hookInProgress() external returns bool envfree;

    function Util.libId(MorphoHarness.MarketParams) external returns MorphoHarness.Id envfree;
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

// Supply anchoring burns the exact input and applies every returned amount as the exact state delta.
rule settleSupplyAnchorAccounting(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 supplySharesInput,
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
        settle(e, marketParams, supplySharesInput, 0, onBehalf, borrower, receiver);

    assert supplySharesBurned == supplySharesInput;
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
    assert to_mathint(totalBorrowAssets(id))
        == to_mathint(borrowAssetsBefore) - to_mathint(borrowAssetsCanceled);
    assert to_mathint(totalBorrowShares(id))
        == to_mathint(borrowSharesBefore) - to_mathint(borrowSharesCanceled);
    assert to_mathint(totalSupplyAssets(id)) - to_mathint(totalBorrowAssets(id))
        == to_mathint(supplyAssetsBefore) - to_mathint(borrowAssetsBefore);
}

// Borrow anchoring burns the exact debt-share input and applies the rounded-up supply burn exactly.
rule settleBorrowAnchorAccounting(
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
        settle(e, marketParams, 0, borrowSharesInput, onBehalf, borrower, receiver);

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
    assert to_mathint(totalBorrowAssets(id))
        == to_mathint(borrowAssetsBefore) - to_mathint(borrowAssetsCanceled);
    assert to_mathint(totalBorrowShares(id))
        == to_mathint(borrowSharesBefore) - to_mathint(borrowSharesCanceled);
    assert to_mathint(totalSupplyAssets(id)) - to_mathint(totalBorrowAssets(id))
        == to_mathint(supplyAssetsBefore) - to_mathint(borrowAssetsBefore);
}

// With accrual already current, the supply anchor is the exact burn, so an input above ownership must revert.
rule settleSupplyAnchorRejectsUnownedShares(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 supplySharesInput,
    address onBehalf,
    address borrower,
    address receiver
) {
    MorphoHarness.Id id = Util.libId(marketParams);
    uint256 canceled = Util.toAssetsDown(supplySharesInput, totalSupplyAssets(id), totalSupplyShares(id));
    uint256 debtBurn = Util.toSharesUp(canceled, totalBorrowAssets(id), totalBorrowShares(id));

    // Freeze accrual so ownership cannot change between the pre-state read and the settle guard.
    require e.msg.value == 0;
    require e.msg.sender == onBehalf;
    require receiver != 0;
    require lastUpdate(id) != 0 && lastUpdate(id) == e.block.timestamp;
    require isSettlementEnabled(id) && marketController(id) != 0;
    require !hookInProgress() && !controllerShouldRevert && !controllerWasCalled;
    require debtBurn <= borrowShares(id, borrower);
    require supplySharesInput > supplyShares(id, onBehalf);

    settle@withrevert(e, marketParams, supplySharesInput, 0, onBehalf, borrower, receiver);

    assert lastReverted;
    assert !controllerWasCalled;
}

// The borrow anchor is checked against the actual rounded-up supply burn, not an asset approximation.
rule settleBorrowAnchorRejectsRoundedBurnAboveOwnership(
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
    uint256 seized = Util.libMulDivDown(canceled, Util.oraclePriceScale(), oraclePrice);
    require requiredSupplyShares > ownedShares;
    require canceled > 0 && canceled <= supplyAssets && canceled <= borrowAssets;
    require oraclePrice > 0 && seized > 0 && seized <= collateral(id, borrower);

    settle@withrevert(e, marketParams, 0, borrowSharesInput, onBehalf, borrower, receiver);

    assert lastReverted;
    assert !controllerWasCalled;
}

// Burning exactly all owned supply shares is a valid supply-anchored boundary.
rule settleSupplyAnchorAtOwnershipBoundary(
    env e,
    MorphoHarness.MarketParams marketParams,
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
    require ownedShares > 0 && ownedShares <= supplySharesTotal;
    require borrowerShares <= borrowSharesTotal;

    uint256 canceled = Util.toAssetsDown(ownedShares, supplyAssets, supplySharesTotal);
    uint256 debtBurn = Util.toSharesUp(canceled, borrowAssets, borrowSharesTotal);
    uint256 seized = Util.libMulDivDown(canceled, Util.oraclePriceScale(), oraclePrice);
    require canceled > 0 && canceled <= supplyAssets && canceled <= borrowAssets;
    require debtBurn <= borrowerShares;
    require oraclePrice > 0 && seized > 0 && seized <= collateral(id, borrower);

    settle@withrevert(e, marketParams, ownedShares, 0, onBehalf, borrower, receiver);

    assert !lastReverted;
    assert controllerWasCalled && lastControllerHookEvent == 8;
    assert supplyShares(id, onBehalf) == 0;
}

// A borrow-anchored full close succeeds when its rounded-up supply burn lands exactly on ownership.
rule settleBorrowAnchorAtOwnershipBoundary(
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
    uint256 seized = Util.libMulDivDown(canceled, Util.oraclePriceScale(), oraclePrice);
    require requiredSupplyShares == ownedShares;
    require canceled > 0 && canceled <= supplyAssets && canceled <= borrowAssets;
    require oraclePrice > 0 && seized > 0 && seized <= collateral(id, borrower);

    settle@withrevert(e, marketParams, 0, borrowSharesInput, onBehalf, borrower, receiver);

    assert !lastReverted;
    assert controllerWasCalled && lastControllerHookEvent == 8;
    assert supplyShares(id, onBehalf) == 0;
    assert borrowShares(id, borrower) == 0;
}

// When the hook returns successfully, core accounting accepts an owned supply cut independently of free liquidity.
rule settlementOwnershipBoundaryIndependentOfFreeLiquidity(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 supplySharesInput,
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
    require supplySharesInput > 0 && supplySharesInput <= ownedShares;
    require ownedShares <= supplySharesTotal;
    require debtShares <= borrowSharesTotal;
    require supplyAssets >= borrowAssets;
    require Util.toAssetsDown(ownedShares, supplyAssets, supplySharesTotal) == supplyAssets - borrowAssets;

    uint256 canceled = Util.toAssetsDown(supplySharesInput, supplyAssets, supplySharesTotal);
    uint256 debtBurn = Util.toSharesUp(canceled, borrowAssets, borrowSharesTotal);
    uint256 seized = Util.libMulDivDown(canceled, Util.oraclePriceScale(), oraclePrice);
    require canceled > 0 && canceled <= supplyAssets && canceled <= borrowAssets;
    require debtBurn <= debtShares;
    require oraclePrice > 0 && seized > 0 && seized <= collateral(id, borrower);

    settle@withrevert(e, marketParams, supplySharesInput, 0, onBehalf, borrower, receiver);

    assert !lastReverted;
    assert controllerWasCalled && lastControllerHookEvent == 8;
}

// A controller veto reaches the Settle hook and rolls back every core accounting slot.
rule settleControllerRevertIsAtomic(
    env e,
    MorphoHarness.MarketParams marketParams,
    uint256 supplySharesInput,
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
    require supplySharesInput > 0 && supplySharesInput <= lenderShares;
    require lenderShares <= supplySharesTotal;
    require borrowerShares <= borrowSharesTotal;

    uint256 canceled = Util.toAssetsDown(supplySharesInput, supplyAssets, supplySharesTotal);
    uint256 debtBurn = Util.toSharesUp(canceled, borrowAssets, borrowSharesTotal);
    uint256 seized = Util.libMulDivDown(canceled, Util.oraclePriceScale(), oraclePrice);
    require canceled > 0 && canceled <= supplyAssets && canceled <= borrowAssets;
    require debtBurn <= borrowerShares;
    require oraclePrice > 0 && seized > 0 && seized <= borrowerCollateral;

    settle@withrevert(e, marketParams, supplySharesInput, 0, onBehalf, borrower, receiver);

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
