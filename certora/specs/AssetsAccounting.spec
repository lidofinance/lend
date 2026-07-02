// SPDX-License-Identifier: GPL-2.0-or-later

using Util as Util;

methods {
    function extSloads(bytes32[]) external returns bytes32[] => NONDET DELETE;

    function supplyShares(MorphoHarness.Id, address) external returns uint256 envfree;
    function borrowShares(MorphoHarness.Id, address) external returns uint256 envfree;
    function collateral(MorphoHarness.Id, address) external returns uint256 envfree;
    function totalSupplyShares(MorphoHarness.Id) external returns uint256 envfree;
    function totalBorrowShares(MorphoHarness.Id) external returns uint256 envfree;
    function totalSupplyAssets(MorphoHarness.Id) external returns uint256 envfree;
    function totalBorrowAssets(MorphoHarness.Id) external returns uint256 envfree;
    function virtualTotalSupplyAssets(MorphoHarness.Id) external returns uint256 envfree;
    function virtualTotalSupplyShares(MorphoHarness.Id) external returns uint256 envfree;
    function virtualTotalBorrowAssets(MorphoHarness.Id) external returns uint256 envfree;
    function virtualTotalBorrowShares(MorphoHarness.Id) external returns uint256 envfree;
    function lastUpdate(MorphoHarness.Id) external returns uint256 envfree;

    function Util.libMulDivDown(uint256, uint256, uint256) external returns uint256 envfree;
    function Util.libMulDivUp(uint256, uint256, uint256) external returns uint256 envfree;
    function Util.libId(MorphoHarness.MarketParams) external returns MorphoHarness.Id envfree;

    function _.on(bytes32, uint8, bytes) external => NONDET;
}

function expectedSupplyAssets(MorphoHarness.Id id, address user) returns uint256 {
    uint256 userShares = supplyShares(id, user);
    uint256 totalSupplyAssets = virtualTotalSupplyAssets(id);
    uint256 totalSupplyShares = virtualTotalSupplyShares(id);

    return Util.libMulDivDown(userShares, totalSupplyAssets, totalSupplyShares);
}

function expectedBorrowAssets(MorphoHarness.Id id, address user) returns uint256 {
    uint256 userShares = borrowShares(id, user);
    uint256 totalBorrowAssets = virtualTotalBorrowAssets(id);
    uint256 totalBorrowShares = virtualTotalBorrowShares(id);

    return Util.libMulDivUp(userShares, totalBorrowAssets, totalBorrowShares);
}

// Check that the assets supplied are greater than the increase in owned assets.
rule supplyAssetsAccounting(env e, MorphoHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) {
    MorphoHarness.Id id = Util.libId(marketParams);

    // Assume no interest as it would increase the total supply assets.
    require lastUpdate(id) == e.block.timestamp;
    // Safe require because of the sumSupplySharesCorrect invariant.
    require supplyShares(id, onBehalf) <= totalSupplyShares(id);

    uint256 ownedAssetsBefore = expectedSupplyAssets(id, onBehalf);

    uint256 suppliedAssets;
    suppliedAssets, _ = supply(e, marketParams, assets, shares, onBehalf, data);

    uint256 ownedAssets = expectedSupplyAssets(id, onBehalf);

    assert ownedAssetsBefore + suppliedAssets >= to_mathint(ownedAssets);
}

// Check that the assets withdrawn are less than the assets owned initially.
rule withdrawAssetsAccounting(env e, MorphoHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) {
    MorphoHarness.Id id = Util.libId(marketParams);

    // Assume no interest as it would increase the total supply assets.
    require lastUpdate(id) == e.block.timestamp;

    uint256 ownedAssets = expectedSupplyAssets(id, onBehalf);

    uint256 withdrawnAssets;
    withdrawnAssets, _ = withdraw(e, marketParams, assets, shares, onBehalf, receiver);

    assert withdrawnAssets <= ownedAssets;
}

// Check that the increase of owed assets are greater than the borrowed assets.
rule borrowAssetsAccounting(env e, MorphoHarness.MarketParams marketParams, uint256 shares, address onBehalf, address receiver) {
    MorphoHarness.Id id = Util.libId(marketParams);

    // Assume no interest as it would increase the total borrowed assets.
    require lastUpdate(id) == e.block.timestamp;
    // Safe require because of the sumBorrowSharesCorrect invariant.
    require borrowShares(id, onBehalf) <= totalBorrowShares(id);

    uint256 owedAssetsBefore = expectedBorrowAssets(id, onBehalf);

    // The borrow call is restricted to shares as input to make it easier on the prover.
    uint256 borrowedAssets;
    borrowedAssets, _ = borrow(e, marketParams, 0, shares, onBehalf, receiver);

    uint256 owedAssets = expectedBorrowAssets(id, onBehalf);

    assert owedAssetsBefore + borrowedAssets <= to_mathint(owedAssets);
}

// Check that the assets repaid are greater than the assets owed initially.
rule repayAssetsAccounting(env e, MorphoHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) {
    MorphoHarness.Id id = Util.libId(marketParams);

    // Assume no interest as it would increase the total borrowed assets.
    require lastUpdate(id) == e.block.timestamp;

    uint256 owedAssets = expectedBorrowAssets(id, onBehalf);

    uint256 repaidAssets;
    repaidAssets, _ = repay(e, marketParams, assets, shares, onBehalf, data);

    // Assume a full repay.
    require borrowShares(id, onBehalf) == 0;

    assert repaidAssets >= owedAssets;
}

// Check that the collateral assets supplied are equal to the increase of owned assets.
rule supplyCollateralAssetsAccounting(env e, MorphoHarness.MarketParams marketParams, uint256 suppliedAssets, address onBehalf, bytes data) {
    MorphoHarness.Id id = Util.libId(marketParams);

    uint256 ownedAssetsBefore = collateral(id, onBehalf);

    supplyCollateral(e, marketParams, suppliedAssets, onBehalf, data);

    uint256 ownedAssets = collateral(id, onBehalf);

    assert ownedAssetsBefore + suppliedAssets == to_mathint(ownedAssets);
}

// Check that the collateral assets withdrawn are less than the assets owned initially.
rule withdrawCollateralAssetsAccounting(env e, MorphoHarness.MarketParams marketParams, uint256 withdrawnAssets, address onBehalf, address receiver) {
    MorphoHarness.Id id = Util.libId(marketParams);

    uint256 ownedAssets = collateral(id, onBehalf);

    withdrawCollateral(e, marketParams, withdrawnAssets, onBehalf, receiver);

    assert withdrawnAssets <= ownedAssets;
}

// Fork: settle cancels borrower debt against onBehalf's supply at par, with no incentive (SPECIFICATION
// §Settlement). The anchor input (exactly one of supplyShares/borrowShares) only picks which side the
// cut is derived from; either way the accounting effect is the same: one debtCanceled value is removed
// from both totalSupplyAssets and totalBorrowAssets, the burned supply shares come entirely from
// onBehalf, and the burned borrow shares come entirely from borrower. The collateral side is
// characterized separately by settleOnlyReducesTargetedBorrowerCollateral in ConsistentState.
rule settleAssetsAccounting(env e, MorphoHarness.MarketParams marketParams, uint256 supplyShares, uint256 borrowShares, address onBehalf, address borrower, address receiver) {
    MorphoHarness.Id id = Util.libId(marketParams);

    // settle accrues interest first; assume it is already accrued (no elapsed time) so the totals move
    // only by the cut, not by accrual.
    require lastUpdate(id) == e.block.timestamp;

    uint256 supplySharesOnBehalfBefore = supplyShares(id, onBehalf);
    uint256 totalSupplySharesBefore = totalSupplyShares(id);
    uint256 totalSupplyAssetsBefore = totalSupplyAssets(id);
    uint256 borrowSharesBorrowerBefore = borrowShares(id, borrower);
    uint256 totalBorrowSharesBefore = totalBorrowShares(id);
    uint256 totalBorrowAssetsBefore = totalBorrowAssets(id);

    uint256 debtCanceled;
    _, debtCanceled = settle(e, marketParams, supplyShares, borrowShares, onBehalf, borrower, receiver);

    // Both asset totals fall by exactly debtCanceled — equal value off each side (par, no incentive).
    // The subtractions are checked in the contract, so a cut deeper than either total reverts instead.
    assert to_mathint(totalSupplyAssets(id)) == to_mathint(totalSupplyAssetsBefore) - to_mathint(debtCanceled);
    assert to_mathint(totalBorrowAssets(id)) == to_mathint(totalBorrowAssetsBefore) - to_mathint(debtCanceled);

    // The burned supply shares are taken entirely from onBehalf; nothing else moves the supply total.
    assert to_mathint(supplySharesOnBehalfBefore) - to_mathint(supplyShares(id, onBehalf))
        == to_mathint(totalSupplySharesBefore) - to_mathint(totalSupplyShares(id));
    // The burned borrow shares are taken entirely from borrower; nothing else moves the borrow total.
    assert to_mathint(borrowSharesBorrowerBefore) - to_mathint(borrowShares(id, borrower))
        == to_mathint(totalBorrowSharesBefore) - to_mathint(totalBorrowShares(id));
}

// Fork: the borrow-anchored input exists precisely to enable exact closure (SPECIFICATION §Settlement,
// PR "two-anchor settle"): it burns the exact debt-share count passed in, so passing the borrower's
// whole balance closes the position to zero — no residual wei of debt survives share-rounding, unlike
// an assets- or supply-derived cut. No accrual assumption is needed: interest accrual changes the
// totals, not the borrower's share balance, and the burn is share-denominated.
rule settleBorrowAnchoredClosesPosition(env e, MorphoHarness.MarketParams marketParams, address onBehalf, address borrower, address receiver) {
    MorphoHarness.Id id = Util.libId(marketParams);

    uint256 debtShares = borrowShares(id, borrower);

    settle(e, marketParams, 0, debtShares, onBehalf, borrower, receiver);

    assert borrowShares(id, borrower) == 0;
}
