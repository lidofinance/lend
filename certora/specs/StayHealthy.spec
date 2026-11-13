// SPDX-License-Identifier: GPL-2.0-or-later
import "Health.spec";

function mulDivUp(uint256 x, uint256 y, uint256 d) returns uint256 {
    assert d != 0;
    return assert_uint256((x * y + (d - 1)) / d);
}

// Check that without accruing interest, ordinary interactions cannot put a healthy account into an
// unhealthy one. Liquidation and settlement are excluded because their share conversions make the generic
// case intractable here. Liquidation is covered by the stayHealthyLiquidate* rules below. Settlement is
// covered by the stayHealthySettle* rules below for every account but the settled borrower. For that
// borrower, settleImprovePosition in Settlement.spec checks that the ratio of debt shares to collateral does
// not grow.
rule stayHealthy(env e, method f, calldataarg data)
filtered {
    f -> !f.isView &&
    f.selector != sig:liquidate(MorphoHarness.MarketParams, address, uint256, uint256, bytes).selector &&
    f.selector != sig:settle(MorphoHarness.MarketParams, uint256, address, address, address).selector
}
{
    MorphoHarness.MarketParams marketParams;
    MorphoHarness.Id id = Util.libId(marketParams);
    address user;

    // Assume that the position is healthy before the interaction.
    require isHealthy(marketParams, user);
    // Safe require because of the invariants onlyEnabledLltv and lltvSmallerThanWad in ConsistentState.spec.
    require marketParams.lltv < 10^18;
    // Assumption to ensure that no interest is accumulated.
    require lastUpdate(id) == e.block.timestamp;

    f(e, data);

    // Safe require because of the invariant sumBorrowSharesCorrect.
    require borrowShares(id, user) <= totalBorrowShares(id);

    assert isHealthy(marketParams, user);
}

// The liquidate case for the stayHealthy rule, with the seized-assets input and no bad debt realization.
// This particular rule makes the following assumptions:
//   - the market of the liquidation is the market of the user, see the *DifferentMarkets rule,
//   - there is still some borrow on the market after liquidation, see the *LastBorrow rule,
//   - the liquidator passes seizedAssets, see the *ByShares rule for repaidShares,
//   - no bad debt is realized, see the *BadDebt rules.
rule stayHealthyLiquidate(env e, MorphoHarness.MarketParams marketParams, address borrower, uint256 seizedAssets, bytes data) {
    MorphoHarness.Id id = Util.libId(marketParams);
    address user;

    // Assume the invariant initially.
    require isHealthy(marketParams, user);

    uint256 debtSharesBefore = borrowShares(id, user);
    uint256 debtAssetsBefore = mulDivUp(debtSharesBefore, virtualTotalBorrowAssets(id), virtualTotalBorrowShares(id));
    // Safe require because of the invariants onlyEnabledLltv and lltvSmallerThanWad in ConsistentState.spec.
    require marketParams.lltv < 10^18;
    // Assumption to ensure that no interest is accumulated.
    require lastUpdate(id) == e.block.timestamp;

    liquidate(e, marketParams, borrower, seizedAssets, 0, data);

    // Safe require because of the invariant sumBorrowSharesCorrect.
    require borrowShares(id, user) <= totalBorrowShares(id);
    // Assume that there is still some borrow on the market after liquidation.
    require totalBorrowAssets(id) > 0;
    // Assume no bad debt realization.
    require collateral(id, borrower) > 0;

    bool stillHealthy = isHealthy(marketParams, user);

    assert user != borrower;
    assert debtSharesBefore == borrowShares(id, user);
    assert debtAssetsBefore >= mulDivUp(debtSharesBefore, virtualTotalBorrowAssets(id), virtualTotalBorrowShares(id));

    assert stillHealthy;
}

// The same as stayHealthyLiquidate with the repaidShares input.
rule stayHealthyLiquidateByShares(env e, MorphoHarness.MarketParams marketParams, address borrower, uint256 repaidShares, bytes data) {
    MorphoHarness.Id id = Util.libId(marketParams);
    address user;

    // Assume the invariant initially.
    require isHealthy(marketParams, user);

    uint256 debtSharesBefore = borrowShares(id, user);
    uint256 debtAssetsBefore = mulDivUp(debtSharesBefore, virtualTotalBorrowAssets(id), virtualTotalBorrowShares(id));
    // Safe require because of the invariants onlyEnabledLltv and lltvSmallerThanWad in ConsistentState.spec.
    require marketParams.lltv < 10^18;
    // Assumption to ensure that no interest is accumulated.
    require lastUpdate(id) == e.block.timestamp;

    liquidate(e, marketParams, borrower, 0, repaidShares, data);

    // Safe require because of the invariant sumBorrowSharesCorrect.
    require borrowShares(id, user) <= totalBorrowShares(id);
    // Assume that there is still some borrow on the market after liquidation.
    require totalBorrowAssets(id) > 0;
    // Assume no bad debt realization.
    require collateral(id, borrower) > 0;

    bool stillHealthy = isHealthy(marketParams, user);

    assert user != borrower;
    assert debtSharesBefore == borrowShares(id, user);
    assert debtAssetsBefore >= mulDivUp(debtSharesBefore, virtualTotalBorrowAssets(id), virtualTotalBorrowShares(id));

    assert stillHealthy;
}

// The same as stayHealthyLiquidate when bad debt is realized and some borrow remains, with the seized-assets
// input. The repayment and the write-off both remove debt assets rounded up against an exact share burn, so the
// value of a borrow share does not rise. That is checked first, as a hint for the debt of the user.
rule stayHealthyLiquidateBadDebt(env e, MorphoHarness.MarketParams marketParams, address borrower, uint256 seizedAssets, bytes data) {
    MorphoHarness.Id id = Util.libId(marketParams);
    address user;

    // Assume the invariant initially.
    require isHealthy(marketParams, user);

    uint256 debtSharesBefore = borrowShares(id, user);
    mathint borrowAssetsBefore = virtualTotalBorrowAssets(id);
    mathint borrowSharesBefore = virtualTotalBorrowShares(id);
    uint256 debtAssetsBefore = mulDivUp(debtSharesBefore, virtualTotalBorrowAssets(id), virtualTotalBorrowShares(id));
    // Safe require because of the invariants onlyEnabledLltv and lltvSmallerThanWad in ConsistentState.spec.
    require marketParams.lltv < 10^18;
    // Assumption to ensure that no interest is accumulated.
    require lastUpdate(id) == e.block.timestamp;

    liquidate(e, marketParams, borrower, seizedAssets, 0, data);

    // Safe require because of the invariant sumBorrowSharesCorrect.
    require borrowShares(id, user) <= totalBorrowShares(id);
    // Assume that there is still some borrow on the market after liquidation.
    require totalBorrowAssets(id) > 0;
    // Assume bad debt realization.
    require collateral(id, borrower) == 0;

    bool stillHealthy = isHealthy(marketParams, user);

    assert user != borrower;
    assert debtSharesBefore == borrowShares(id, user);
    assert virtualTotalBorrowAssets(id) * borrowSharesBefore <= borrowAssetsBefore * virtualTotalBorrowShares(id);
    assert debtAssetsBefore >= mulDivUp(debtSharesBefore, virtualTotalBorrowAssets(id), virtualTotalBorrowShares(id));

    assert stillHealthy;
}

// The same as stayHealthyLiquidateBadDebt with the repaidShares input.
rule stayHealthyLiquidateBadDebtByShares(env e, MorphoHarness.MarketParams marketParams, address borrower, uint256 repaidShares, bytes data) {
    MorphoHarness.Id id = Util.libId(marketParams);
    address user;

    // Assume the invariant initially.
    require isHealthy(marketParams, user);

    uint256 debtSharesBefore = borrowShares(id, user);
    mathint borrowAssetsBefore = virtualTotalBorrowAssets(id);
    mathint borrowSharesBefore = virtualTotalBorrowShares(id);
    uint256 debtAssetsBefore = mulDivUp(debtSharesBefore, virtualTotalBorrowAssets(id), virtualTotalBorrowShares(id));
    // Safe require because of the invariants onlyEnabledLltv and lltvSmallerThanWad in ConsistentState.spec.
    require marketParams.lltv < 10^18;
    // Assumption to ensure that no interest is accumulated.
    require lastUpdate(id) == e.block.timestamp;

    liquidate(e, marketParams, borrower, 0, repaidShares, data);

    // Safe require because of the invariant sumBorrowSharesCorrect.
    require borrowShares(id, user) <= totalBorrowShares(id);
    // Assume that there is still some borrow on the market after liquidation.
    require totalBorrowAssets(id) > 0;
    // Assume bad debt realization.
    require collateral(id, borrower) == 0;

    bool stillHealthy = isHealthy(marketParams, user);

    assert user != borrower;
    assert debtSharesBefore == borrowShares(id, user);
    assert virtualTotalBorrowAssets(id) * borrowSharesBefore <= borrowAssetsBefore * virtualTotalBorrowShares(id);
    assert debtAssetsBefore >= mulDivUp(debtSharesBefore, virtualTotalBorrowAssets(id), virtualTotalBorrowShares(id));

    assert stillHealthy;
}

rule stayHealthyLiquidateDifferentMarkets(env e, MorphoHarness.MarketParams marketParams, address borrower, uint256 seizedAssets, uint256 repaidShares, bytes data) {
    MorphoHarness.Id id = Util.libId(marketParams);
    address user;
    MorphoHarness.MarketParams liquidationMarketParams;

    // Assume the invariant initially.
    require isHealthy(marketParams, user);

    // Safe require because of the invariants onlyEnabledLltv and lltvSmallerThanWad in ConsistentState.spec.
    require marketParams.lltv < 10^18;
    // Assumption to ensure that no interest is accumulated.
    require lastUpdate(id) == e.block.timestamp;
    // Assume that the liquidation is on a different market.
    require liquidationMarketParams != marketParams;

    liquidate(e, liquidationMarketParams, borrower, seizedAssets, repaidShares, data);

    // Safe require because of the invariant sumBorrowSharesCorrect.
    require borrowShares(id, user) <= totalBorrowShares(id);

    assert isHealthy(marketParams, user);
}

rule stayHealthyLiquidateLastBorrow(env e, MorphoHarness.MarketParams marketParams, address borrower, uint256 seizedAssets, uint256 repaidShares, bytes data) {
    MorphoHarness.Id id = Util.libId(marketParams);
    address user;

    // Assume the invariant initially.
    require isHealthy(marketParams, user);

    // Safe require because of the invariants onlyEnabledLltv and lltvSmallerThanWad in ConsistentState.spec.
    require marketParams.lltv < 10^18;
    // Assumption to ensure that no interest is accumulated.
    require lastUpdate(id) == e.block.timestamp;

    liquidate(e, marketParams, borrower, seizedAssets, repaidShares, data);

    // Safe require because of the invariant sumBorrowSharesCorrect.
    require borrowShares(id, user) <= totalBorrowShares(id);
    // Assume that there is no remaining borrow on the market after liquidation.
    require totalBorrowAssets(id) == 0;

    assert isHealthy(marketParams, user);
}

// The settle case for the stayHealthy rule, for an account other than the settled borrower. Settlement
// leaves the collateral and the debt shares of such an account untouched, so the account stays healthy as
// long as its debt in assets does not grow.
// This particular rule makes the following assumptions:
//   - the market of the settlement is the market of the user, see the *DifferentMarkets rule,
//   - there is still some borrow on the market after settlement, see the *LastBorrow rule.
rule stayHealthySettle(env e, MorphoHarness.MarketParams marketParams, uint256 settledShares, address onBehalf, address borrower, address receiver) {
    MorphoHarness.Id id = Util.libId(marketParams);
    address user;

    // The settled borrower is excluded, see settleImprovePosition in Settlement.spec for its position.
    require user != borrower;
    // Assume the invariant initially.
    require isHealthy(marketParams, user);

    uint256 debtSharesBefore = borrowShares(id, user);
    uint256 debtAssetsBefore = mulDivUp(debtSharesBefore, virtualTotalBorrowAssets(id), virtualTotalBorrowShares(id));
    // Safe require because of the invariants onlyEnabledLltv and lltvSmallerThanWad in ConsistentState.spec.
    require marketParams.lltv < 10^18;
    // Assumption to ensure that no interest is accumulated.
    require lastUpdate(id) == e.block.timestamp;

    settle(e, marketParams, settledShares, onBehalf, borrower, receiver);

    // Safe require because of the invariant sumBorrowSharesCorrect.
    require borrowShares(id, user) <= totalBorrowShares(id);
    // Assume that there is still some borrow on the market after settlement.
    require totalBorrowAssets(id) > 0;

    bool stillHealthy = isHealthy(marketParams, user);

    assert debtSharesBefore == borrowShares(id, user);
    assert debtAssetsBefore >= mulDivUp(debtSharesBefore, virtualTotalBorrowAssets(id), virtualTotalBorrowShares(id));

    assert stillHealthy;
}

// Settlement on another market writes none of this market's storage. The rule does not cover an oracle of
// this market whose price depends on the settled market, such as the price of a vault share backed by a
// position there.
rule stayHealthySettleDifferentMarkets(env e, MorphoHarness.MarketParams marketParams, uint256 settledShares, address onBehalf, address borrower, address receiver) {
    MorphoHarness.Id id = Util.libId(marketParams);
    address user;
    MorphoHarness.MarketParams settlementMarketParams;

    // Assume the invariant initially.
    require isHealthy(marketParams, user);

    // Safe require because of the invariants onlyEnabledLltv and lltvSmallerThanWad in ConsistentState.spec.
    require marketParams.lltv < 10^18;
    // Assumption to ensure that no interest is accumulated.
    require lastUpdate(id) == e.block.timestamp;
    // Assume that the settlement is on a different market.
    require settlementMarketParams != marketParams;

    settle(e, settlementMarketParams, settledShares, onBehalf, borrower, receiver);

    // Safe require because of the invariant sumBorrowSharesCorrect.
    require borrowShares(id, user) <= totalBorrowShares(id);

    assert isHealthy(marketParams, user);
}

// When no borrow remains, the total borrow assets may have been floored at zero, which can raise the borrow
// index. The debt of the account still does not grow, because its shares are then worth at most one unit.
rule stayHealthySettleLastBorrow(env e, MorphoHarness.MarketParams marketParams, uint256 settledShares, address onBehalf, address borrower, address receiver) {
    MorphoHarness.Id id = Util.libId(marketParams);
    address user;

    // The settled borrower is excluded, see settleImprovePosition in Settlement.spec for its position.
    require user != borrower;
    // Assume the invariant initially.
    require isHealthy(marketParams, user);

    // Safe require because of the invariants onlyEnabledLltv and lltvSmallerThanWad in ConsistentState.spec.
    require marketParams.lltv < 10^18;
    // Assumption to ensure that no interest is accumulated.
    require lastUpdate(id) == e.block.timestamp;

    settle(e, marketParams, settledShares, onBehalf, borrower, receiver);

    // Safe require because of the invariant sumBorrowSharesCorrect.
    require borrowShares(id, user) <= totalBorrowShares(id);
    // Assume that there is no remaining borrow on the market after settlement.
    require totalBorrowAssets(id) == 0;

    assert isHealthy(marketParams, user);
}
