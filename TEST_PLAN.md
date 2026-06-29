# LidoLend Fork — Test Plan

The fork makes three mechanical changes to Morpho: controller hooks, a `settle` primitive, and an upgradeable initializer. This lists each change and the scenario/integration tests that cover it, plus the key revert and event checks. The rest is inherited Morpho, covered by the upstream suite — a few of those files are minimally adapted to the fork's `onlyOwner` `createMarket` and proxy initializer (an added `vm.prank(OWNER)`, proxy deployment in `setUp`). Where fork tests share an inherited file they sit below a `LIDO FORK TESTS` separator, under the inherited `MORPHO UPSTREAM TESTS`, with no change to any inherited scenario.

Tests live in `test/integration/{Controller,Hooks,Initialize,Reentrancy,Settle}IntegrationTest.sol`, `test/integration/SettleMathTest.sol`, and `test/invariant/SettleInvariantTest.sol`.

---

## 1. Controller hooks

**What changed.** A controller-hook dispatch (`_hook`) fires before the state writes of every state-changing action — supply, withdraw, borrow, repay, supplyCollateral, withdrawCollateral, liquidate, accrueInterest, and the new `settle`. The bound controller is optional, set once at market creation and checked against the market id it declares (`marketId()`). It can revert to veto an action. The dispatch holds a single **global** transient reentrancy lock (EIP-1153) for the length of the hook. `flashLoan` is the one state-touching path with no hook. A market with no controller behaves exactly as upstream.

**Firing, payload, and veto** (`HooksIntegrationTest`, `ControllerIntegrationTest`):
- `Hooks::testHook{Action}Fires` (8 actions) — each action dispatches its hook with the correct `HookEvent`, the bound market id (`lastId`), and a payload whose decoded fields match the resolved action (caller / onBehalf / receiver / assets / shares).
- `Hooks::testHook{Action}Blocks` (8 actions) — a controller that reverts vetoes the action. The revert propagates and **no state is written** — post-revert assertions confirm the touched shares/collateral/totals/token balances are unchanged, pinning the hook-fires-before-writes ordering. (Settle's hook firing and veto live in `SettleIntegrationTest` — `testSettleHookPayload` / `testSettleControllerCanBlock` — not here.)
- `Controller::testCreateMarketBindsController` / `testCreateMarketEmitsBindingEvents` / `testCreateMarketWithoutSettlementSkipsEnableEvent` / `testCreateMarketRevertsOnZeroController` / `testCreateMarketRevertsOnControllerMismatch` — binding at creation: bound state, the `SetMarketController` / `EnableSettlement` events, the settlement-disabled path (controller bound, settlement off, no `EnableSettlement`), and the zero-controller / id-mismatch reverts.
- `Controller::testSupplyFiresSupplyHook` / `testBorrowFiresBorrowHook` — payload decode + market-id assertion on the bound fixture.

**Accrual ordering** (`HooksIntegrationTest`, live-IRM market, a probing controller that records `lastUpdate` / totals at dispatch time, and each assertion discriminates against the opposite ordering):
- `testHookSupplyCollateralDoesNotAccrueBeforeHook` — `supplyCollateral` does not accrue before its hook. The hook sees a stale `lastUpdate` and un-accrued totals (and the action never accrues at all).
- `testHookWithdrawCollateralAccruesBeforeHook` — `withdrawCollateral` does accrue first. The hook sees a fresh `lastUpdate` and accrued totals.
- `testHookAccrueInterestFiresBeforeAccruing` — `accrueInterest` fires its hook before accruing. The hook sees pre-accrual state and totals grow only afterwards.

**Reentrancy lock** (`ReentrancyIntegrationTest`). The lock is a single global flag, held for the length of the hook and released before state writes and Morpho callbacks. Each test arms a reentrant call that is valid on its own (positions funded, controller approved/authorized) and uses `vm.expectCall` as a negative control, so only the lock can stop it.
- `testReentrancy{Action}Blocked` (8 actions) + `testReentrancySettleBlockedEvenWithinLimits` — reentering the **same** market during its hook reverts `HOOK_REENTRANCY`.
- `testSameMarketReentryThroughOtherMarketHookBlocked` — a hook re-entering through another market still reverts, since the global lock is held for the whole outer hook (the nested action never even reaches the second market's hook).
- `testOtherControlledMarketActionBlockedDuringHook` — the global lock blocks an action on a different controlled market mid-hook.
- `testHooklessMarketActionBlockedDuringHook` — the global lock blocks even a no-controller market's action mid-hook.
- `testFlashLoanAllowedDuringHook` — `flashLoan` dispatches no hook and is not locked.
- `testCallbackAfterHookCanReenter` — a Morpho callback (fired after the hook and after state writes) can reenter, preserving the upstream leverage pattern.

---

## 2. `settle`

**What changed.** A new fallback exit: it cancels a borrower's debt against a lender's supply shares and transfers the seized collateral to a receiver, at the oracle price with no liquidation incentive. Usable only on a market that opted in at creation, and only on the part of the lender's supply that ordinary withdrawal liquidity cannot serve (`_settleableSupply` = the supply value beyond free liquidity). The core does not itself prevent bad debt from a cut — that is delegated to the bound controller, consulted via its hook before the write.

**Tests** (`SettleIntegrationTest`, `SettleMathTest`, `SettleInvariantTest` — `SettleMathTest` holds the arithmetic, rounding, and cap-boundary cases, `SettleIntegrationTest` the access-control, hook/event, and lifecycle cases):
- Guard reverts — `testSettleMarketNotCreated`, `testSettleDisabled`, `testSettleInconsistentInput`, `testSettleZeroReceiver`, `testSettleUnauthorized`, `testSettleIneligibleBorrower` (borrower has no debt).
- Happy path — `Controller::testSettleHappyPath`, `testSettleSuccessFuzz` — cancels debt, seizes the matching collateral at the oracle price, pays the receiver. Exact-arithmetic deltas across all touched slots, and "no loan tokens move".
- Liquidity gate — `testSettleLiquidityGateBoundary` verifies the exact-settleable cut passes (its single-borrower fixture makes settleable equal the debt, so the over-large side trips the debt cap `SETTLEMENT_EXCEEDS_DEBT`). The gate's own `SETTLEMENT_LIQUIDITY_AVAILABLE` revert is asserted by `testSettleCannotCancelMoreThanOwned` and the invariant `test_settleBlockedAboveSettleableSupply`. The gate fires before the share subtraction, so an over-large cut reverts cleanly with no underflow.
- Caps (each its own error) — `testSettleOverCapCollateral` (seize past collateral), `testSettleOverCapBorrowShares` (cancel past the borrower's debt), `testSettleOverCapZeroCollateral` (slice rounds to zero collateral).
- Both anchors — the supply-anchored branch can be steered by a target asset amount (`testSettleToTargetAssetAmount`: pass the supply shares worth the target, debtCanceled lands exactly on it). The borrow-anchored branch cancels an exact debt-share count to close a position to zero (`testSettleBorrowAnchoredClosesToZero` asserts the deltas + event, `testSettleBorrowAnchoredHookPayload` the derived payload, `testSettleBorrowAnchoredCloseFuzz` the close across a price range, and `testSettleClosePositionRoundsBurnPastHolding` the rounding detail).
- Authorization — `testSettleUnauthorized` / `testSettleAuthorizedViaApproval` / `testSettleAuthorizedViaSig` — only the share owner or an address it authorized (by approval or an EIP-712 signature) can run a cut.
- Rounding — `testSettleShareRoundingWithInterestFuzz` (share slice) and `testSettleAssetTargetRoundingWithInterestFuzz` (asset target) — on an interest-skewed ratio, `toAssetsDown` / `toSharesUp` round in the protocol's favour.
- Bad debt — `testSettleBadDebtNotRealizedFuzz` — a cut on an underwater position cancels a matched slice without writing lender assets down. Residual debt stays on the borrower (`liquidate` would write down here, `settle` does not).
- Exit completeness — `testSettleBorrowerExitsWhole` (partly-unwound borrower clears the residual and withdraws the rest, no stuck collateral), `testSettleFullDrainLeavesMarketUsable` (cancelling the whole stake zeroes the market and it stays usable), `testSettleSelfPosition` (a lender == borrower loop, where supply burn and borrow/collateral seizure hit distinct fields).
- Hook — `testSettleControllerCanBlock` (veto reverts and leaves every touched slot unchanged), `testSettleHookPayload` (decoded `SettleHookData` + `lastEvent == Settle` + `lastId == id`), `testSettleEmitsEvent` (exact `Settle` event fields).
- `SettleInvariantTest` — stateful fuzz against a solvency-enforcing mock controller, firing both supply-anchored cuts (`settleNoRevert`) and borrow-anchored closes (`settleCloseNoRevert`) through the same exact-delta assertions: `test_settleHappyPath`, `test_controllerBlocksInsolventCut` (the bad-debt backstop), `test_settleBlockedAboveSettleableSupply` (the gate), and `invariantSupplyShares` / `invariantBorrowShares` (share conservation, with a bystander lender/borrower staying untouched).

The bad-debt backstop is the production controller's responsibility. That controller is not in this repo — it is the assumption to lean on (`test_controllerBlocksInsolventCut` stands in via a mock enforcing post-cut solvency).

---

## 3. Upgradeable initializer

**What changed.** The core runs behind a proxy: the constructor petrifies the implementation, `initialize(owner)` replaces the constructor's owner-set, and `DOMAIN_SEPARATOR` became a view recomputed from `block.chainid` + `address(this)` instead of a bytecode immutable.

**Tests** (`InitializeIntegrationTest`, deployed through the `TestProxy` harness):
- `testCannotReinitializeProxy` — a live proxy can't be re-initialized to seize ownership.
- `testImplementationIsPetrified` — the bare implementation can't be initialized directly.
- `testDomainSeparatorResolvesToProxy` / `testDomainSeparatorDiffersFromImplementation` — the EIP-712 domain binds to the proxy address, not the implementation's.

---

## Known gaps (not yet covered)

- `DOMAIN_SEPARATOR` per-call `block.chainid` sensitivity (only its address binding is tested).
- The fork storage fields are round-trip checked via `MorphoStorageLib` (`MorphoStorageLibTest::testStorageForkSlots`) but their literal appended slot positions (9 / 10 / 11) and the immutability of upstream slots 0–8 are not asserted.
- `initialize` exercised as a success-then-revert sequence on one fresh proxy (current tests cover the petrified implementation and re-init on the shared proxy separately).
</content>
</invoke>
