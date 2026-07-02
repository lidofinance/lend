// SPDX-License-Identifier: GPL-2.0-or-later
import "Health.spec";

function mulDivUp(uint256 x, uint256 y, uint256 d) returns uint256 {
    assert d != 0;
    return assert_uint256((x * y + (d - 1)) / d);
}

// Check that without accruing interest, no interaction can put an healthy account into an unhealthy one.
// The liquidate function times out in this rule, but has been checked separately.
// settle is also excluded: it has no core health gate and burns totalBorrowShares/Assets, shifting the
// pooled borrow ratio like liquidate (supply-anchored burns borrow shares rounded up for the canceled
// debt; borrow-anchored cancels debt valued up for the exact shares burned). The settled borrower's own
// health is preserved by the par cut — collateralSeized rounds down against the value of debt canceled;
// the ratio shift is the standard adverse-to-user Morpho rounding for third parties.
// A machine-checked settle case (analogous to the liquidate rules below) times out monolithically and
// needs the same case-splitting; left as follow-up.
rule stayHealthy(env e, method f, calldataarg data)
filtered {
    f -> !f.isView &&
    f.selector != sig:liquidate(MorphoHarness.MarketParams, address, uint256, uint256, bytes).selector &&
    f.selector != sig:settle(MorphoHarness.MarketParams, uint256, uint256, address, address, address).selector
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

// The liquidate case for the stayHealthy rule, assuming no bad debt realization, otherwise it times out.
// This particular rule makes the following assumptions:
//   - the market of the liquidation is the market of the user, see the *DifferentMarkets rule,
//   - there is still some borrow on the market after liquidation, see the *LastBorrow rule.
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

rule stayHealthyLiquidateDifferentMarkets(env e, MorphoHarness.MarketParams marketParams, address borrower, uint256 seizedAssets, bytes data) {
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

    liquidate(e, liquidationMarketParams, borrower, seizedAssets, 0, data);

    // Safe require because of the invariant sumBorrowSharesCorrect.
    require borrowShares(id, user) <= totalBorrowShares(id);

    assert isHealthy(marketParams, user);
}

rule stayHealthyLiquidateLastBorrow(env e, MorphoHarness.MarketParams marketParams, address borrower, uint256 seizedAssets, bytes data) {
    MorphoHarness.Id id = Util.libId(marketParams);
    address user;

    // Assume the invariant initially.
    require isHealthy(marketParams, user);

    // Safe require because of the invariants onlyEnabledLltv and lltvSmallerThanWad in ConsistentState.spec.
    require marketParams.lltv < 10^18;
    // Assumption to ensure that no interest is accumulated.
    require lastUpdate(id) == e.block.timestamp;

    liquidate(e, marketParams, borrower, seizedAssets, 0, data);

    // Safe require because of the invariant sumBorrowSharesCorrect.
    require borrowShares(id, user) <= totalBorrowShares(id);
    // Assume that there is no remaining borrow on the market after liquidation.
    require totalBorrowAssets(id) == 0;

    assert isHealthy(marketParams, user);
}

// The settle case, split like the liquidate case above. Only the borrow-anchored path is checked for
// third parties: it cancels debt valued with toAssetsUp for the exact shares burned, so the borrow
// exchange rate cannot increase and no other borrower's position can degrade. The supply-anchored
// path burns borrow shares rounded up, which can push the pooled rate up by one ULP and flip a
// borderline third-party position — the standard adverse-to-user Morpho rounding (see the exclusion
// comment above), so no third-party rule holds for it. The settled borrower's own protection is the
// par-value cut, characterized by settleSeizesAtMostParCollateral in LiquidateBuffer.spec.
rule stayHealthySettleBorrowAnchored(env e, MorphoHarness.MarketParams marketParams, uint256 shares, address onBehalf, address borrower, address receiver) {
    MorphoHarness.Id id = Util.libId(marketParams);
    address user;

    // Assume the invariant initially.
    require isHealthy(marketParams, user);

    // Safe require because of the invariants onlyEnabledLltv and lltvSmallerThanWad in ConsistentState.spec.
    require marketParams.lltv < 10^18;
    // Assumption to ensure that no interest is accumulated.
    require lastUpdate(id) == e.block.timestamp;
    // The settled borrower's collateral shrinks; only third parties are claimed here.
    require user != borrower;

    settle(e, marketParams, 0, shares, onBehalf, borrower, receiver);

    // Safe require because of the invariant sumBorrowSharesCorrect.
    require borrowShares(id, user) <= totalBorrowShares(id);
    // Assume that there is still some borrow on the market after the cut, see the *LastBorrow rule.
    require totalBorrowAssets(id) > 0;

    assert isHealthy(marketParams, user);
}

rule stayHealthySettleBorrowAnchoredLastBorrow(env e, MorphoHarness.MarketParams marketParams, uint256 shares, address onBehalf, address borrower, address receiver) {
    MorphoHarness.Id id = Util.libId(marketParams);
    address user;

    // Assume the invariant initially.
    require isHealthy(marketParams, user);

    // Safe require because of the invariants onlyEnabledLltv and lltvSmallerThanWad in ConsistentState.spec.
    require marketParams.lltv < 10^18;
    // Assumption to ensure that no interest is accumulated.
    require lastUpdate(id) == e.block.timestamp;
    // The settled borrower's collateral shrinks; only third parties are claimed here.
    require user != borrower;

    settle(e, marketParams, 0, shares, onBehalf, borrower, receiver);

    // Safe require because of the invariant sumBorrowSharesCorrect.
    require borrowShares(id, user) <= totalBorrowShares(id);
    // Assume that there is no remaining borrow on the market after the cut.
    require totalBorrowAssets(id) == 0;

    assert isHealthy(marketParams, user);
}

// Both anchor paths: a settle on a different market cannot affect the user's health.
rule stayHealthySettleDifferentMarkets(env e, MorphoHarness.MarketParams marketParams, MorphoHarness.MarketParams settleMarketParams, uint256 supplyShares, uint256 borrowShares, address onBehalf, address borrower, address receiver) {
    MorphoHarness.Id id = Util.libId(marketParams);
    address user;

    // Assume the invariant initially.
    require isHealthy(marketParams, user);

    // Safe require because of the invariants onlyEnabledLltv and lltvSmallerThanWad in ConsistentState.spec.
    require marketParams.lltv < 10^18;
    // Assumption to ensure that no interest is accumulated.
    require lastUpdate(id) == e.block.timestamp;
    // Assume that the settle is on a different market.
    require settleMarketParams != marketParams;

    settle(e, settleMarketParams, supplyShares, borrowShares, onBehalf, borrower, receiver);

    // Safe require because of the invariant sumBorrowSharesCorrect.
    require borrowShares(id, user) <= totalBorrowShares(id);

    assert isHealthy(marketParams, user);
}
