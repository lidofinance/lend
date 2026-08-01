// SPDX-License-Identifier: GPL-2.0-or-later

using Util as Util;

methods {
    function extSloads(bytes32[]) external returns bytes32[] => NONDET DELETE;

    function totalBorrowAssets(MorphoHarness.Id) external returns uint256 envfree;
    function totalBorrowShares(MorphoHarness.Id) external returns uint256 envfree;
    function virtualTotalBorrowAssets(MorphoHarness.Id) external returns uint256 envfree;
    function virtualTotalBorrowShares(MorphoHarness.Id) external returns uint256 envfree;
    function lastUpdate(MorphoHarness.Id) external returns uint256 envfree;
    function borrowShares(MorphoHarness.Id, address) external returns uint256 envfree;
    function collateral(MorphoHarness.Id, address) external returns uint256 envfree;
    function isAuthorized(address, address user) external returns bool envfree;
    function isSettlementEnabled(MorphoHarness.Id) external returns bool envfree;
    function marketController(MorphoHarness.Id) external returns address envfree;
    function hookInProgress() external returns bool envfree;
    function idToMarketParams_(MorphoHarness.Id) external returns MorphoHarness.MarketParams envfree;

    function Util.libId(MorphoHarness.MarketParams) external returns MorphoHarness.Id envfree;
    function Util.wad() external returns uint256 envfree;
    function isHealthy(MorphoHarness.MarketParams, address user) external returns bool envfree;

    function _.price() external => oraclePrice expect uint256;
    function _.on(bytes32, uint8, bytes) external => acceptControllerHook() expect void;
    function SafeTransferLib.safeTransfer(address, address, uint256) internal => NONDET;
    function SafeTransferLib.safeTransferFrom(address, address, address, uint256) internal => NONDET;
    function UtilsLib.min(uint256 a, uint256 b) internal returns uint256 => summaryMin(a, b);
}

persistent ghost uint256 oraclePrice;

function acceptControllerHook() {}

function summaryMin(uint256 a, uint256 b) returns uint256 {
    return a < b ? a : b;
}

// A reverted call leaves collateral unchanged. Successful ordinary actions cannot reduce collateral
// owned by an unrelated, unauthorized healthy user. Liquidation and settlement are checked separately.
rule healthyUserCannotLoseCollateral(env e, method f, calldataarg data)
filtered {
    f -> !f.isView
        && f.selector != sig:liquidate(MorphoHarness.MarketParams, address, uint256, uint256, bytes).selector
        && f.selector != sig:settle(MorphoHarness.MarketParams, uint256, uint256, address, address, address).selector
}
{
    MorphoHarness.MarketParams marketParams;
    MorphoHarness.Id id = Util.libId(marketParams);
    address user;

    // Assume that the e.msg.sender is not authorized.
    require !isAuthorized(user, e.msg.sender);
    require user != e.msg.sender;
    require e.msg.value == 0;
    require !hookInProgress();
    require lastUpdate(id) != 0 && lastUpdate(id) == e.block.timestamp;
    require idToMarketParams_(id) == marketParams;
    require isHealthy(marketParams, user);

    uint256 collateralBefore = collateral(id, user);

    f@withrevert(e, data);

    bool reverted = lastReverted;
    uint256 collateralAfter = collateral(id, user);
    assert reverted || collateralAfter >= collateralBefore;
}

// The health check executes before the controller hook and collateral mutation, so a healthy borrower
// cannot be liquidated with either liquidation anchor.
rule healthyUserCannotBeLiquidated(
    env e,
    MorphoHarness.MarketParams marketParams,
    address borrower,
    uint256 seizedAssets,
    uint256 repaidShares,
    bytes data
) {
    MorphoHarness.Id id = Util.libId(marketParams);

    require e.msg.value == 0;
    require lastUpdate(id) != 0 && lastUpdate(id) == e.block.timestamp;
    require idToMarketParams_(id) == marketParams;
    require (seizedAssets == 0) != (repaidShares == 0);
    require isHealthy(marketParams, borrower);

    liquidate@withrevert(e, marketParams, borrower, seizedAssets, repaidShares, data);

    assert lastReverted;
}

// Only a settlement-enabled market can contain residual debt after a successful cut removes all
// collateral. Other LidoLend actions retain the stronger debt-implies-collateral property.
invariant debtWithoutCollateralRequiresSettlementMarket(MorphoHarness.Id id, address borrower)
    borrowShares(id, borrower) != 0 && collateral(id, borrower) == 0 => isSettlementEnabled(id);

// Guard against accidentally making the invariant a tautology through a getter or storage-model summary.
rule debtWithoutCollateralInvariantIsNontrivial(MorphoHarness.Id id, address borrower) {
    satisfy borrowShares(id, borrower) != 0 && collateral(id, borrower) == 0 && !isSettlementEnabled(id);
}

// Checks that passing a seized amount input to liquidate leads to repaid shares S and repaid amount A such that liquidating instead with shares S also repays the amount A.
rule liquidateEquivalentInputDebtAndInputCollateral(
    env e,
    MorphoHarness.MarketParams marketParams,
    address borrower,
    uint256 seizedAssets,
    bytes data
) {
    MorphoHarness.Id id = Util.libId(marketParams);

    // Isolate the two core liquidation formulas from hook behavior, callbacks and token behavior.
    require e.msg.value == 0;
    require !hookInProgress();
    require marketController(id) == 0;
    require lastUpdate(id) != 0 && lastUpdate(id) == e.block.timestamp;
    require idToMarketParams_(id) == marketParams;
    require marketParams.lltv < Util.wad();
    require oraclePrice > 0;
    require !isHealthy(marketParams, borrower);
    require seizedAssets > 0 && seizedAssets < collateral(id, borrower);
    require data.length == 0;

    storage init = lastStorage;
    uint256 sharesBefore = borrowShares(id, borrower);

    uint256 repaidAssets1;
    _, repaidAssets1 = liquidate(e, marketParams, borrower, seizedAssets, 0, data);
    uint256 sharesAfter = borrowShares(id, borrower);
    uint256 repaidShares1 = assert_uint256(sharesBefore - sharesAfter);

    uint256 repaidAssets2;
    _, repaidAssets2 = liquidate(e, marketParams, borrower, 0, repaidShares1, data) at init;

    assert repaidAssets1 == repaidAssets2;
}
