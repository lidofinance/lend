// SPDX-License-Identifier: GPL-2.0-or-later

using Util as Util;

methods {
    function extSloads(bytes32[]) external returns (bytes32[]) => NONDET DELETE;

    function supplyShares(MorphoHarness.Id, address) external returns (uint256) envfree;
    function borrowShares(MorphoHarness.Id, address) external returns (uint256) envfree;
    function collateral(MorphoHarness.Id, address) external returns (uint256) envfree;
    function totalSupplyAssets(MorphoHarness.Id) external returns (uint256) envfree;
    function totalSupplyShares(MorphoHarness.Id) external returns (uint256) envfree;
    function totalBorrowAssets(MorphoHarness.Id) external returns (uint256) envfree;
    function totalBorrowShares(MorphoHarness.Id) external returns (uint256) envfree;
    function fee(MorphoHarness.Id) external returns (uint256) envfree;
    function lastUpdate(MorphoHarness.Id) external returns (uint256) envfree;
    function isIrmEnabled(address) external returns (bool) envfree;
    function isLltvEnabled(uint256) external returns (bool) envfree;
    function isAuthorized(address, address) external returns (bool) envfree;
    function idToMarketParams_(MorphoHarness.Id) external returns (MorphoHarness.MarketParams) envfree;
    function nonce(address) external returns (uint256) envfree;
    function marketController(MorphoHarness.Id) external returns (address) envfree;
    function isSettlementEnabled(MorphoHarness.Id) external returns (bool) envfree;

    function Util.maxFee() external returns (uint256) envfree;
    function Util.wad() external returns (uint256) envfree;
    function Util.libId(MorphoHarness.MarketParams) external returns (MorphoHarness.Id) envfree;

    function _.borrowRate(MorphoHarness.MarketParams, MorphoHarness.Market) external => HAVOC_ECF;

    // NONDET is safe here: on() returns nothing, and this spec only reads currentContract storage and
    // persistent ghosts, neither of which an external call can touch. HAVOC_ECF is equivalent for these
    // rules but times out on liquidate.
    function _.on(bytes32, uint8, bytes) external => NONDET;

    // Every rule in this spec is linear in the storage deltas the ghosts accumulate: the exact values
    // of share/asset conversions and mulDiv chains never matter, only that the same value feeds the
    // paired writes and transfers. The summaries below are therefore a sound over-approximation, and
    // they remove the nonlinear arithmetic that times the liquidate case out. Rounding exactness is
    // proved in ExactMath / AssetsAccounting / LibSummary instead. Two linear facts are kept, both
    // true of the real functions: every conversion maps zero to zero, and the ceil-direction
    // conversions map a positive input to a positive output (a debtless borrower stays unreachable:
    // liquidate values zero shares to zero debt and reverts healthy, settle's positive cut rounds up
    // to at least one debt share and trips the debt gate).
    function SharesMathLib.toSharesUp(uint256 a, uint256 b, uint256 c) internal returns (uint256) => positivePreserving(a);
    function SharesMathLib.toSharesDown(uint256 a, uint256 b, uint256 c) internal returns (uint256) => zeroPreserving(a);
    function SharesMathLib.toAssetsUp(uint256 a, uint256 b, uint256 c) internal returns (uint256) => positivePreserving(a);
    function SharesMathLib.toAssetsDown(uint256 a, uint256 b, uint256 c) internal returns (uint256) => zeroPreserving(a);
    function MathLib.mulDivUp(uint256 a, uint256 b, uint256 c) internal returns (uint256) => zeroPreserving(a);
    function MathLib.mulDivDown(uint256 a, uint256 b, uint256 c) internal returns (uint256) => zeroPreserving(a);
    function MathLib.wDivUp(uint256 a, uint256 b) internal returns (uint256) => zeroPreserving(a);
    function MathLib.wDivDown(uint256 a, uint256 b) internal returns (uint256) => zeroPreserving(a);
    function MathLib.wMulDown(uint256 a, uint256 b) internal returns (uint256) => zeroPreserving(a);
    function MathLib.wTaylorCompounded(uint256 a, uint256 b) internal returns (uint256) => zeroPreserving(a);

    function SafeTransferLib.safeTransfer(address token, address to, uint256 value) internal => summarySafeTransferFrom(token, currentContract, to, value);
    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 value) internal => summarySafeTransferFrom(token, from, to, value);
}

// x == 0 => 0: every summarized conversion maps zero to zero.
function zeroPreserving(uint256 x) returns uint256 {
    uint256 r;
    require x == 0 => r == 0;
    return r;
}

// Additionally x > 0 => r > 0: the ceil-direction conversions round a positive input up to >= 1.
function positivePreserving(uint256 x) returns uint256 {
    uint256 r;
    require x == 0 => r == 0;
    require x > 0 => r > 0;
    return r;
}

persistent ghost mapping(MorphoHarness.Id => mathint) sumSupplyShares {
    init_state axiom (forall MorphoHarness.Id id. sumSupplyShares[id] == 0);
}

persistent ghost mapping(MorphoHarness.Id => mathint) sumBorrowShares {
    init_state axiom (forall MorphoHarness.Id id. sumBorrowShares[id] == 0);
}

persistent ghost mapping(MorphoHarness.Id => mathint) sumCollateral {
    init_state axiom (forall MorphoHarness.Id id. sumCollateral[id] == 0);
}

persistent ghost mapping(address => mathint) balance {
    init_state axiom (forall address token. balance[token] == 0);
}

persistent ghost mapping(address => mathint) idleAmount {
    init_state axiom (forall address token. idleAmount[token] == 0);
}

hook Sstore position[KEY MorphoHarness.Id id][KEY address owner].supplyShares uint256 newShares (uint256 oldShares) {
    sumSupplyShares[id] = sumSupplyShares[id] - oldShares + newShares;
}

hook Sstore position[KEY MorphoHarness.Id id][KEY address owner].borrowShares uint128 newShares (uint128 oldShares) {
    sumBorrowShares[id] = sumBorrowShares[id] - oldShares + newShares;
}

hook Sstore position[KEY MorphoHarness.Id id][KEY address owner].collateral uint128 newAmount (uint128 oldAmount) {
    sumCollateral[id] = sumCollateral[id] - oldAmount + newAmount;
    idleAmount[idToMarketParams_(id).collateralToken] = idleAmount[idToMarketParams_(id).collateralToken] - oldAmount + newAmount;
}

hook Sstore market[KEY MorphoHarness.Id id].totalSupplyAssets uint128 newAmount (uint128 oldAmount) {
    idleAmount[idToMarketParams_(id).loanToken] = idleAmount[idToMarketParams_(id).loanToken] - oldAmount + newAmount;
}

hook Sstore market[KEY MorphoHarness.Id id].totalBorrowAssets uint128 newAmount (uint128 oldAmount) {
    idleAmount[idToMarketParams_(id).loanToken] = idleAmount[idToMarketParams_(id).loanToken] + oldAmount - newAmount;
}

function summarySafeTransferFrom(address token, address from, address to, uint256 amount) {
    if (from == currentContract) {
        // Safe require because the reference implementation would revert.
        balance[token] = require_uint256(balance[token] - amount);
    }
    if (to == currentContract) {
        // Safe require because the reference implementation would revert.
        balance[token] = require_uint256(balance[token] + amount);
    }
}

definition isCreated(MorphoHarness.Id id) returns bool = lastUpdate(id) != 0;

// Check that the fee is always lower than the max fee constant.
invariant feeInRange(MorphoHarness.Id id)
    fee(id) <= Util.maxFee();

// Check that the accounting of totalSupplyShares is correct.
invariant sumSupplySharesCorrect(MorphoHarness.Id id)
    to_mathint(totalSupplyShares(id)) == sumSupplyShares[id];

// Check that the accounting of totalBorrowShares is correct.
invariant sumBorrowSharesCorrect(MorphoHarness.Id id)
    to_mathint(totalBorrowShares(id)) == sumBorrowShares[id];

// Check that a market only allows borrows up to the total supply.
// This invariant shows that markets are independent, tokens from one market cannot be taken by interacting with another market.
invariant borrowLessThanSupply(MorphoHarness.Id id)
    totalBorrowAssets(id) <= totalSupplyAssets(id);

// Check correctness of applying idToMarketParams() to an identifier.
invariant hashOfMarketParamsOf(MorphoHarness.Id id)
    isCreated(id) => Util.libId(idToMarketParams_(id)) == id;

// Check correctness of applying id() to a market params.
// This invariant is useful in the following rule, to link an id back to a market.
invariant marketParamsOfHashOf(MorphoHarness.MarketParams marketParams)
    isCreated(Util.libId(marketParams)) => idToMarketParams_(Util.libId(marketParams)) == marketParams;

// Check that the idle amount on the singleton is greater to the sum amount, that is the sum over all the markets of the total supply plus the total collateral minus the total borrow.
invariant idleAmountLessThanBalance(address token)
    idleAmount[token] <= balance[token]
    {
        // Safe requires on the sender because the contract cannot call the function itself.
        preserved supply(MorphoHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) with (env e) {
            requireInvariant marketParamsOfHashOf(marketParams);
            require e.msg.sender != currentContract;
        }
        preserved withdraw(MorphoHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) with (env e) {
            requireInvariant marketParamsOfHashOf(marketParams);
            require e.msg.sender != currentContract;
        }
        preserved borrow(MorphoHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) with (env e) {
            requireInvariant marketParamsOfHashOf(marketParams);
            require e.msg.sender != currentContract;
        }
        preserved repay(MorphoHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) with (env e) {
            requireInvariant marketParamsOfHashOf(marketParams);
            require e.msg.sender != currentContract;
        }
        preserved supplyCollateral(MorphoHarness.MarketParams marketParams, uint256 assets, address onBehalf, bytes data) with (env e) {
            requireInvariant marketParamsOfHashOf(marketParams);
            require e.msg.sender != currentContract;
        }
        preserved withdrawCollateral(MorphoHarness.MarketParams marketParams, uint256 assets, address onBehalf, address receiver) with (env e) {
            requireInvariant marketParamsOfHashOf(marketParams);
            require e.msg.sender != currentContract;
        }
        preserved liquidate(MorphoHarness.MarketParams marketParams, address _b, uint256 shares, uint256 receiver, bytes data) with (env e) {
            requireInvariant marketParamsOfHashOf(marketParams);
            require e.msg.sender != currentContract;
        }
        preserved settle(
            MorphoHarness.MarketParams marketParams,
            uint256 supplySharesInput,
            uint256 borrowSharesInput,
            address onBehalf,
            address borrower,
            address receiver
        ) with (env e) {
            requireInvariant marketParamsOfHashOf(marketParams);
            require e.msg.sender != currentContract;
        }
    }

// Check that a market can only exist if its LLTV is enabled.
invariant onlyEnabledLltv(MorphoHarness.MarketParams marketParams)
    isCreated(Util.libId(marketParams)) => isLltvEnabled(marketParams.lltv);

invariant lltvSmallerThanWad(uint256 lltv)
    isLltvEnabled(lltv) => lltv < Util.wad();

// Check that a market can only exist if its IRM is enabled.
invariant onlyEnabledIrm(MorphoHarness.MarketParams marketParams)
    isCreated(Util.libId(marketParams)) => isIrmEnabled(marketParams.irm);

// Settlement is only available on a market with a bound controller.
invariant settlementRequiresController(MorphoHarness.Id id)
    isSettlementEnabled(id) => marketController(id) != 0;

// Check the pseudo-injectivity of the hashing function id().
rule libIdUnique() {
    MorphoHarness.MarketParams marketParams1;
    MorphoHarness.MarketParams marketParams2;

    // Assume that arguments are the same.
    require Util.libId(marketParams1) == Util.libId(marketParams2);

    assert marketParams1 == marketParams2;
}

// Check that only the user is able to change who is authorized to manage his position.
rule onlyUserCanAuthorizeWithoutSig(env e, method f, calldataarg data) filtered { f -> !f.isView && f.selector != sig:setAuthorizationWithSig(MorphoHarness.Authorization memory, MorphoHarness.Signature calldata).selector } {
    address user;
    address someone;

    // Assume that it is another user that is interacting with Morpho.
    require user != e.msg.sender;

    bool authorizedBefore = isAuthorized(user, someone);

    f(e, data);

    bool authorizedAfter = isAuthorized(user, someone);

    assert authorizedAfter == authorizedBefore;
}

// Check that only authorized users are able to decrease supply shares of a position.
rule userCannotLoseSupplyShares(env e, method f, calldataarg data) filtered { f -> !f.isView } {
    MorphoHarness.Id id;
    address user;

    // Assume that the e.msg.sender is not authorized.
    require !isAuthorized(user, e.msg.sender);
    require user != e.msg.sender;

    mathint sharesBefore = supplyShares(id, user);

    f(e, data);

    mathint sharesAfter = supplyShares(id, user);

    assert sharesAfter >= sharesBefore;
}

// Check that only authorized users are able to increase the borrow shares of a position.
rule userCannotGainBorrowShares(env e, method f, calldataarg args) filtered { f -> !f.isView } {
    MorphoHarness.Id id;
    address user;

    // Assume that the e.msg.sender is not authorized.
    require !isAuthorized(user, e.msg.sender);
    require user != e.msg.sender;

    mathint sharesBefore = borrowShares(id, user);

    f(e, args);

    mathint sharesAfter = borrowShares(id, user);

    assert sharesAfter <= sharesBefore;
}

// Check that users cannot lose collateral by unauthorized parties except through liquidation or settlement.
rule userCannotLoseCollateralExceptLiquidateOrSettle(env e, method f, calldataarg args) filtered {
    f -> !f.isView
        && f.selector != sig:liquidate(MorphoHarness.MarketParams, address, uint256, uint256, bytes).selector
        && f.selector != sig:settle(MorphoHarness.MarketParams, uint256, uint256, address, address, address).selector
} {
    MorphoHarness.Id id;
    address user;

    // Assume that the e.msg.sender is not authorized.
    require !isAuthorized(user, e.msg.sender);
    require user != e.msg.sender;

    mathint collateralBefore = collateral(id, user);

    f(e, args);

    mathint collateralAfter = collateral(id, user);

    assert collateralAfter >= collateralBefore;
}

// Check that users cannot lose collateral by unauthorized parties if they have no outstanding debt.
rule userWithoutBorrowCannotLoseCollateral(env e, method f, calldataarg args) filtered { f -> !f.isView } {
    MorphoHarness.Id id;
    address user;

    // Assume that the e.msg.sender is not authorized.
    require !isAuthorized(user, e.msg.sender);
    require user != e.msg.sender;

    // Assume that the user has no outstanding debt.
    require borrowShares(id, user) == 0;

    mathint collateralBefore = collateral(id, user);

    f(e, args);

    mathint collateralAfter = collateral(id, user);

    assert collateralAfter >= collateralBefore;
}

// Invariant checking that the last updated time is never greater than the current time.
rule noTimeTravel(method f, env e, calldataarg args) filtered { f -> !f.isView } {
    MorphoHarness.Id id;

    // Assume the property before the interaction.
    require lastUpdate(id) <= e.block.timestamp;

    f(e, args);

    assert lastUpdate(id) <= e.block.timestamp;
}

// Invariant checking that the last updated time is never zero.
rule lastUpdateNonZero(method f, env e, calldataarg args) filtered { f -> !f.isView } {
    MorphoHarness.Id id;

    // Assume the timestamp is not extremely far in the future.
    require e.block.timestamp <= max_uint128;

    // Assume the property before the interaction.
    require lastUpdate(id) != 0;

    f(e, args);

    assert lastUpdate(id) != 0;
}

// Invariant checking that the last updated time never decreases.
rule lastUpdateCannotDecrease(method f, env e, calldataarg args) filtered { f -> !f.isView } {
    MorphoHarness.Id id;

    // Assume the timestamp is not extremely far in the future.
    require e.block.timestamp <= max_uint128;
    uint256 lastUpdateBefore = lastUpdate(id);

    f(e, args);

    uint256 lastUpdateAfter = lastUpdate(id);
    assert lastUpdateAfter >= lastUpdateBefore;
}

// Invariant checking that IRM cannot be disabled once enabled.
rule irmCannotBeDisabled(method f, env e, calldataarg args) filtered { f -> !f.isView } {
    address irm;

    // Assume the property before the interaction.
    require isIrmEnabled(irm);

    f(e, args);

    assert isIrmEnabled(irm);
}

// Invariant checking that LLTV cannot be disabled once enabled.
rule lltvCannotBeDisabled(method f, env e, calldataarg args) filtered { f -> !f.isView } {
    uint256 lltv;

    // Assume the property before the interaction.
    require isLltvEnabled(lltv);

    f(e, args);

    assert isLltvEnabled(lltv);
}

// Invariant checking that market parameters for a created market cannot change.
rule idToMarketParamsForCreatedMarketCannotChange(method f, env e, calldataarg args) filtered { f -> !f.isView } {
    MorphoHarness.Id id;

    // Assume the market is created.
    require isCreated(id);
    MorphoHarness.MarketParams itmpBefore = idToMarketParams_(id);

    f(e, args);

    MorphoHarness.MarketParams itmpAfter = idToMarketParams_(id);
    assert itmpBefore == itmpAfter;
}

// Controller bindings and settlement opt-ins are immutable after market creation.
rule marketControllerForCreatedMarketCannotChange(method f, env e, calldataarg args) filtered { f -> !f.isView } {
    MorphoHarness.Id id;
    require isCreated(id);
    address controllerBefore = marketController(id);

    f(e, args);

    assert marketController(id) == controllerBefore;
}

rule settlementFlagForCreatedMarketCannotChange(method f, env e, calldataarg args) filtered { f -> !f.isView } {
    MorphoHarness.Id id;
    require isCreated(id);
    bool enabledBefore = isSettlementEnabled(id);

    f(e, args);

    assert isSettlementEnabled(id) == enabledBefore;
}

rule nonceCannotDecrease(method f, env e, calldataarg args) filtered { f -> !f.isView } {
    address user;

    uint256 nonceBefore = nonce(user);

    f(e, args);

    uint256 nonceAfter = nonce(user);
    assert(nonceAfter == nonceBefore || nonceAfter == nonceBefore + 1);
}
