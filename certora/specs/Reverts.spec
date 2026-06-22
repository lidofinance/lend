// SPDX-License-Identifier: GPL-2.0-or-later

using Util as Util;

methods {
    function extSloads(bytes32[]) external returns bytes32[] => NONDET DELETE;

    function owner() external returns address envfree;
    function feeRecipient() external returns address envfree;
    function totalSupplyAssets(MorphoHarness.Id) external returns uint256 envfree;
    function totalBorrowAssets(MorphoHarness.Id) external returns uint256 envfree;
    function totalSupplyShares(MorphoHarness.Id) external returns uint256 envfree;
    function totalBorrowShares(MorphoHarness.Id) external returns uint256 envfree;
    function lastUpdate(MorphoHarness.Id) external returns uint256 envfree;
    function isIrmEnabled(address) external returns bool envfree;
    function isLltvEnabled(uint256) external returns bool envfree;
    function isAuthorized(address, address) external returns bool envfree;
    function nonce(address) external returns uint256 envfree;
    function isSettlementEnabled(MorphoHarness.Id) external returns bool envfree;
    function supplyShares(MorphoHarness.Id, address) external returns uint256 envfree;
    function borrowShares(MorphoHarness.Id, address) external returns uint256 envfree;
    function collateral(MorphoHarness.Id, address) external returns uint256 envfree;
    function virtualTotalSupplyAssets(MorphoHarness.Id) external returns uint256 envfree;
    function virtualTotalSupplyShares(MorphoHarness.Id) external returns uint256 envfree;
    function virtualTotalBorrowAssets(MorphoHarness.Id) external returns uint256 envfree;
    function virtualTotalBorrowShares(MorphoHarness.Id) external returns uint256 envfree;

    function Util.libId(MorphoHarness.MarketParams) external returns MorphoHarness.Id envfree;

    function Util.maxFee() external returns uint256 envfree;
    function Util.wad() external returns uint256 envfree;
    function Util.oraclePriceScale() external returns uint256 envfree;
    function Util.libMulDivDown(uint256, uint256, uint256) external returns uint256 envfree;
    function Util.libMulDivUp(uint256, uint256, uint256) external returns uint256 envfree;

    function _.on(bytes32, uint8, bytes) external => NONDET;
    // marketId() is the controller's immutable bound market id: a storage-free view. Model it as a
    // deterministic ghost (keyed by the controller) so the CONTROLLER_MISMATCH revert can be asserted
    // against a fixed value instead of a havoc'd external return.
    function _.marketId() external => ghostMarketId(calledContract) expect MorphoHarness.Id;
    // Pin the oracle price to a fixed value so settle's collateralSeized = mulDivDown(debtCanceled,
    // ORACLE_PRICE_SCALE, price) can be reconstructed deterministically in the economic-revert rules.
    function _.price() external => constantPrice expect uint256;
}

// Persistent: marketId() is an immutable view, and createMarket ends with an unresolved IIrm.borrowRate()
// call that would otherwise havoc this ghost, desyncing the value the assert reads from the one the
// contract's marketId() check used.
persistent ghost ghostMarketId(address) returns MorphoHarness.Id;
// Persistent for the same reason: the settle economic-revert rules read it in the assert after the call.
persistent ghost uint256 constantPrice;

definition isCreated(MorphoHarness.Id id) returns bool =
    (lastUpdate(id) != 0);

persistent ghost mapping(MorphoHarness.Id => mathint) sumCollateral
{
    init_state axiom (forall MorphoHarness.Id id. sumCollateral[id] == 0);
}
hook Sstore position[KEY MorphoHarness.Id id][KEY address owner].collateral uint128 newAmount (uint128 oldAmount) {
    sumCollateral[id] = sumCollateral[id] - oldAmount + newAmount;
}

definition emptyMarket(MorphoHarness.Id id) returns bool =
    totalSupplyAssets(id) == 0 &&
    totalSupplyShares(id) == 0 &&
    totalBorrowAssets(id) == 0 &&
    totalBorrowShares(id) == 0 &&
    sumCollateral[id] == 0;

definition exactlyOneZero(uint256 assets, uint256 shares) returns bool =
    (assets == 0 && shares != 0) || (assets != 0 && shares == 0);

// This invariant catches bugs when not checking that the market is created with lastUpdate.
invariant notCreatedIsEmpty(MorphoHarness.Id id)
    !isCreated(id) => emptyMarket(id)
{
    preserved with (env e) {
        // Safe require because timestamps cannot realistically be that large.
        require e.block.timestamp < 2^128;
    }
}

// Useful to ensure that authorized parties are not the zero address and so we can omit the sanity check in this case.
invariant zeroDoesNotAuthorize(address authorized)
    !isAuthorized(0, authorized)
{
    preserved setAuthorization(address _authorized, bool _newAuthorization) with (env e) {
        // Safe require because no one controls the zero address.
        require e.msg.sender != 0;
    }
}

// Check the revert condition for the setOwner function.
rule setOwnerRevertCondition(env e, address newOwner) {
    address oldOwner = owner();
    setOwner@withrevert(e, newOwner);
    assert lastReverted <=> e.msg.value != 0 || e.msg.sender != oldOwner || newOwner == oldOwner;
}

// Check that setFee reverts when its inputs are not validated.
// setFee can also revert if the accrueInterest reverts.
rule setFeeInputValidation(env e, MorphoHarness.MarketParams marketParams, uint256 newFee) {
    MorphoHarness.Id id = Util.libId(marketParams);
    address oldOwner = owner();
    bool wasCreated = isCreated(id);
    setFee@withrevert(e, marketParams, newFee);
    bool hasReverted = lastReverted;
    assert e.msg.value != 0 || e.msg.sender != oldOwner || !wasCreated || newFee > Util.maxFee() => hasReverted;
}

// Check the revert condition for the setFeeRecipient function.
rule setFeeRecipientRevertCondition(env e, address newFeeRecipient) {
    address oldOwner = owner();
    address oldFeeRecipient = feeRecipient();
    setFeeRecipient@withrevert(e, newFeeRecipient);
    assert lastReverted <=> e.msg.value != 0 || e.msg.sender != oldOwner || newFeeRecipient == oldFeeRecipient;
}

// Check that createMarket reverts when its inputs are not validated.
// Fork: createMarket is onlyOwner and auto-enables the irm/lltv on first use (the standalone
// enableIrm/enableLltv were removed), so a disabled irm/lltv no longer reverts. The revert
// conditions are instead a non-owner caller and an lltv out of range.
rule createMarketInputValidation(env e, MorphoHarness.MarketParams marketParams) {
    MorphoHarness.Id id = Util.libId(marketParams);
    address oldOwner = owner();
    uint256 wad = Util.wad();
    bool wasCreated = isCreated(id);
    createMarket@withrevert(e, marketParams);
    assert e.msg.value != 0 || e.msg.sender != oldOwner || marketParams.lltv >= wad || wasCreated => lastReverted;
}

// Check that the controller createMarket overload reverts when its inputs are not validated.
// Fork-specific entrypoint: it additionally requires a non-zero controller (the controller and
// the settlement opt-in are fixed at creation) whose own marketId() must equal this market's id
// (CONTROLLER_MISMATCH). The latter is asserted by pinning the controller's marketId() to a
// deterministic ghost; it only fires when controller != 0 (the zero case is the disjunct before it).
rule createMarketWithControllerInputValidation(env e, MorphoHarness.MarketParams marketParams, address controller, bool enableSettlement) {
    MorphoHarness.Id id = Util.libId(marketParams);
    address oldOwner = owner();
    uint256 wad = Util.wad();
    bool wasCreated = isCreated(id);
    createMarket@withrevert(e, marketParams, controller, enableSettlement);
    assert e.msg.value != 0 || e.msg.sender != oldOwner || controller == 0 || marketParams.lltv >= wad || wasCreated || ghostMarketId(controller) != id => lastReverted;
}

// Check that supply reverts when its input are not validated.
rule supplyInputValidation(env e, MorphoHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) {
    supply@withrevert(e, marketParams, assets, shares, onBehalf, data);
    assert !exactlyOneZero(assets, shares) || onBehalf == 0 => lastReverted;
}

// Check that withdraw reverts when its inputs are not validated.
rule withdrawInputValidation(env e, MorphoHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) {
    // Safe require because no one controls the zero address.
    require e.msg.sender != 0;
    requireInvariant zeroDoesNotAuthorize(e.msg.sender);
    withdraw@withrevert(e, marketParams, assets, shares, onBehalf, receiver);
    assert !exactlyOneZero(assets, shares) || onBehalf == 0 || receiver == 0 => lastReverted;
}

// Check that borrow reverts when its inputs are not validated.
rule borrowInputValidation(env e, MorphoHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) {
    // Safe require because no one controls the zero address.
    require e.msg.sender != 0;
    requireInvariant zeroDoesNotAuthorize(e.msg.sender);
    borrow@withrevert(e, marketParams, assets, shares, onBehalf, receiver);
    assert !exactlyOneZero(assets, shares) || onBehalf == 0  || receiver == 0 => lastReverted;
}

// Check that repay reverts when its inputs are not validated.
rule repayInputValidation(env e, MorphoHarness.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) {
    repay@withrevert(e, marketParams, assets, shares, onBehalf, data);
    assert !exactlyOneZero(assets, shares) || onBehalf == 0 => lastReverted;
}

// Check that supplyCollateral reverts when its inputs are not validated.
rule supplyCollateralInputValidation(env e, MorphoHarness.MarketParams marketParams, uint256 assets, address onBehalf, bytes data) {
    supplyCollateral@withrevert(e, marketParams, assets, onBehalf, data);
    assert assets == 0 || onBehalf == 0 => lastReverted;
}

// Check that withdrawCollateral reverts when its inputs are not validated.
rule withdrawCollateralInputValidation(env e, MorphoHarness.MarketParams marketParams, uint256 assets, address onBehalf, address receiver) {
    // Safe require because no one controls the zero address.
    require e.msg.sender != 0;
    requireInvariant zeroDoesNotAuthorize(e.msg.sender);
    withdrawCollateral@withrevert(e, marketParams, assets, onBehalf, receiver);
    assert assets == 0 || onBehalf == 0 || receiver == 0 => lastReverted;
}

// Check that flashLoan reverts when its inputs are not validated.
rule flashLoanInputValidation(env e, address token, uint256 assets, bytes data) {
    flashLoan@withrevert(e, token, assets, data);
    assert assets == 0 => lastReverted;
}

// Check that liquidate reverts when its inputs are not validated.
rule liquidateInputValidation(env e, MorphoHarness.MarketParams marketParams, address borrower, uint256 seizedAssets, uint256 repaidShares, bytes data) {
    liquidate@withrevert(e, marketParams, borrower, seizedAssets, repaidShares, data);
    assert !exactlyOneZero(seizedAssets, repaidShares) => lastReverted;
}

// Check that settle reverts when its inputs are not validated.
// Fork entrypoint. Like withdraw, exactly one of supplyAssets/supplyShares must be non-zero, the
// receiver must be non-zero, and the caller must be authorized for onBehalf. Two settle-specific
// input gates: the market must exist and settlement must be enabled on it (the createMarket(.., true)
// opt-in). Each is a require that must hold for success, so any of them failing forces a revert
// regardless of their order. The deeper economic guards (borrower has debt, the slice fits the
// borrower's collateral and debt, ordinary liquidity is exhausted) depend on accrual/oracle/share
// math and are not characterized here.
rule settleInputValidation(env e, MorphoHarness.MarketParams marketParams, uint256 supplyAssets, uint256 supplyShares, address onBehalf, address borrower, address receiver) {
    MorphoHarness.Id id = Util.libId(marketParams);
    // Capture envfree getters before the @withrevert call; querying them afterwards would reset lastReverted.
    bool created = isCreated(id);
    bool settlementEnabled = isSettlementEnabled(id);
    // Safe require because no one controls the zero address.
    require e.msg.sender != 0;
    requireInvariant zeroDoesNotAuthorize(e.msg.sender);
    settle@withrevert(e, marketParams, supplyAssets, supplyShares, onBehalf, borrower, receiver);
    assert !created || !settlementEnabled || !exactlyOneZero(supplyAssets, supplyShares) || onBehalf == 0 || receiver == 0 => lastReverted;
}

// The next four rules characterize settle's economic guards (the ones beyond input validation), each as
// a one-directional "condition => revert". They share two modeling assumptions so the resolved quantities
// can be reconstructed exactly: the assets-input path (supplyShares == 0, which leaves debtCanceled ==
// supplyAssets), and zero elapsed interest (lastUpdate == now, so _accrueInterest leaves the totals put).

// settle reverts (SETTLEMENT_NO_DEBT) when the targeted borrower has no debt — it is a soft liquidation
// and only acts on indebted positions. borrowShares is untouched by interest accrual, so the pre-state
// read is the value the guard sees; no other assumption is needed.
rule settleNoDebtReverts(env e, MorphoHarness.MarketParams marketParams, uint256 supplyAssets, uint256 supplyShares, address onBehalf, address borrower, address receiver) {
    MorphoHarness.Id id = Util.libId(marketParams);
    bool noDebt = borrowShares(id, borrower) == 0;
    settle@withrevert(e, marketParams, supplyAssets, supplyShares, onBehalf, borrower, receiver);
    assert noDebt => lastReverted;
}

// settle reverts (SETTLEMENT_LIQUIDITY_AVAILABLE) when the cancelled debt exceeds onBehalf's settleable
// supply: the part of onBehalf's supply that sits beyond the freely-withdrawable liquidity. The liquid
// part must be redeemed with a normal withdraw, so settle is gated to debtCanceled <= _settleableSupply,
// where _settleableSupply = max(0, onBehalfSupplyAssets - availableLiquidity),
//   availableLiquidity   = zeroFloorSub(totalSupplyAssets, totalBorrowAssets),
//   onBehalfSupplyAssets = toAssetsDown(supplyShares(onBehalf), totalSupplyAssets, totalSupplyShares).
rule settleLiquidityAvailableReverts(env e, MorphoHarness.MarketParams marketParams, uint256 supplyAssets, uint256 supplyShares, address onBehalf, address borrower, address receiver) {
    MorphoHarness.Id id = Util.libId(marketParams);
    require supplyShares == 0;
    require lastUpdate(id) == e.block.timestamp;

    mathint availableLiquidity = totalSupplyAssets(id) > totalBorrowAssets(id)
        ? to_mathint(totalSupplyAssets(id)) - to_mathint(totalBorrowAssets(id))
        : 0;
    uint256 onBehalfSupplyAssets = Util.libMulDivDown(supplyShares(id, onBehalf), virtualTotalSupplyAssets(id), virtualTotalSupplyShares(id));
    mathint settleableSupply = to_mathint(onBehalfSupplyAssets) > availableLiquidity
        ? to_mathint(onBehalfSupplyAssets) - availableLiquidity
        : 0;

    settle@withrevert(e, marketParams, supplyAssets, supplyShares, onBehalf, borrower, receiver);

    assert to_mathint(supplyAssets) > settleableSupply => lastReverted;
}

// settle reverts on the collateral cut: the seized collateral must be non-zero (SETTLEMENT_SLICE_TOO_SMALL)
// and must fit the borrower's collateral (SETTLEMENT_EXCEEDS_COLLATERAL). collateralSeized =
// mulDivDown(debtCanceled, ORACLE_PRICE_SCALE, price), reconstructed with the pinned constant price.
rule settleCollateralCutReverts(env e, MorphoHarness.MarketParams marketParams, uint256 supplyAssets, uint256 supplyShares, address onBehalf, address borrower, address receiver) {
    MorphoHarness.Id id = Util.libId(marketParams);
    require supplyShares == 0;
    require lastUpdate(id) == e.block.timestamp;
    // A zero price makes the contract's own mulDivDown revert; that sub-case is excluded, not characterized.
    require constantPrice != 0;

    uint256 collateralSeized = Util.libMulDivDown(supplyAssets, Util.oraclePriceScale(), constantPrice);
    // Capture before the @withrevert call; querying it afterwards would reset lastReverted.
    uint256 borrowerCollateral = collateral(id, borrower);

    settle@withrevert(e, marketParams, supplyAssets, supplyShares, onBehalf, borrower, receiver);

    assert collateralSeized == 0 => lastReverted;
    assert to_mathint(collateralSeized) > to_mathint(borrowerCollateral) => lastReverted;
}

// settle reverts (SETTLEMENT_EXCEEDS_DEBT) when the shares burned for the cut exceed the borrower's debt.
// borrowSharesToBurn = toSharesUp(debtCanceled, totalBorrowAssets, totalBorrowShares)
//                    = mulDivUp(supplyAssets, totalBorrowShares + VIRTUAL_SHARES, totalBorrowAssets + VIRTUAL_ASSETS).
rule settleExceedsDebtReverts(env e, MorphoHarness.MarketParams marketParams, uint256 supplyAssets, uint256 supplyShares, address onBehalf, address borrower, address receiver) {
    MorphoHarness.Id id = Util.libId(marketParams);
    require supplyShares == 0;
    require lastUpdate(id) == e.block.timestamp;

    uint256 borrowSharesToBurn = Util.libMulDivUp(supplyAssets, virtualTotalBorrowShares(id), virtualTotalBorrowAssets(id));
    // Capture before the @withrevert call; querying it afterwards would reset lastReverted.
    uint256 borrowerDebt = borrowShares(id, borrower);

    settle@withrevert(e, marketParams, supplyAssets, supplyShares, onBehalf, borrower, receiver);

    assert to_mathint(borrowSharesToBurn) > to_mathint(borrowerDebt) => lastReverted;
}

// Check that setAuthorizationWithSig reverts when its inputs are not validated.
rule setAuthorizationWithSigInputValidation(env e, MorphoHarness.Authorization authorization, MorphoHarness.Signature signature) {
    uint256 nonceBefore = nonce(authorization.authorizer);
    setAuthorizationWithSig@withrevert(e, authorization, signature);
    assert e.block.timestamp > authorization.deadline || authorization.nonce != nonceBefore => lastReverted;
}

// Check that accrueInterest reverts when its inputs are not validated.
rule accrueInterestInputValidation(env e, MorphoHarness.MarketParams marketParams) {
    bool wasCreated = isCreated(Util.libId(marketParams));
    accrueInterest@withrevert(e, marketParams);
    assert !wasCreated => lastReverted;
}
