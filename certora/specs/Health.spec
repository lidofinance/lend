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
    function lastUpdate(MorphoHarness.Id) external returns uint256 envfree;

    function Util.libId(MorphoHarness.MarketParams) external returns MorphoHarness.Id envfree;
    function isHealthy(MorphoHarness.MarketParams, address user) external returns bool envfree;

    function _.price() external => CONSTANT;
    function _.on(bytes32, uint8, bytes) external => NONDET;
    function UtilsLib.min(uint256 a, uint256 b) internal returns uint256 => summaryMin(a, b);
}

function summaryMin(uint256 a, uint256 b) returns uint256 {
    return a < b ? a : b;
}

// Check that users cannot lose collateral by unauthorized parties except in case of an unhealthy position.
// Liquidate needs no exclusion here: a healthy position cannot be liquidated, so it reverts.
// Fork: settle is excluded. Per SPECIFICATION.md (Settlement), settle is a soft liquidation with no
// core health check (it must reach unhealthy-but-solvent positions), so even a healthy borrower can
// be cut; protecting the borrower is the controller's responsibility, not the core's.
rule healthyUserCannotLoseCollateral(env e, method f, calldataarg data)
filtered { f -> !f.isView && f.selector != sig:settle(MorphoHarness.MarketParams, uint256, uint256, address, address, address).selector }
{
    MorphoHarness.MarketParams marketParams;
    MorphoHarness.Id id = Util.libId(marketParams);
    address user;

    // Assume that the e.msg.sender is not authorized.
    require !isAuthorized(user, e.msg.sender);
    require user != e.msg.sender;
    // Assumption to ensure that no interest is accumulated.
    require lastUpdate(id) == e.block.timestamp;
    // Assume that the user is healthy.
    require isHealthy(marketParams, user);

    uint256 collateralBefore = collateral(id, user);

    f(e, data);

    assert collateral(id, user) >= collateralBefore;
}

// Check that users without collateral also have no debt.
// This invariant ensures that bad-debt realization cannot be bypassed by the ordinary actions.
// Fork: settle is excluded. Per SPECIFICATION.md (Settlement), settle never realizes bad debt — a cut
// that empties the collateral leaves residual borrow shares in place (to be socialized by a later
// liquidation), and excluding LTV>100% borrowers is the controller's duty, not the core's. So the core
// does not maintain debt => collateral across settle.
invariant alwaysCollateralized(MorphoHarness.Id id, address borrower)
    borrowShares(id, borrower) != 0 => collateral(id, borrower) != 0
    filtered { f -> f.selector != sig:settle(MorphoHarness.MarketParams, uint256, uint256, address, address, address).selector }

// Checks that passing a seized amount input to liquidate leads to repaid shares S and repaid amount A such that liquidating instead with shares S also repays the amount A.
rule liquidateEquivalentInputDebtAndInputCollateral(env e, MorphoHarness.MarketParams marketParams, address borrower, uint256 seizedAssets, bytes data) {
    MorphoHarness.Id id = Util.libId(marketParams);

    // Assume no interest accrual to ease the verification.
    require lastUpdate(id) == e.block.timestamp;

    storage init = lastStorage;
    uint256 sharesBefore = borrowShares(id, borrower);

    uint256 repaidAssets1;
    _, repaidAssets1 = liquidate(e, marketParams, borrower, seizedAssets, 0, data);
    // Omit the bad debt realization case.
    require collateral(id, borrower) != 0;
    uint256 sharesAfter = borrowShares(id, borrower);
    uint256 repaidShares1 = assert_uint256(sharesBefore - sharesAfter);

    uint256 repaidAssets2;
    _, repaidAssets2 = liquidate(e, marketParams, borrower, 0, repaidShares1, data) at init;

    assert repaidAssets1 == repaidAssets2;
}
