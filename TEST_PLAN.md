# LidoLend Fork — Test Plan

The fork makes three mechanical changes to Morpho: controller hooks, a `settle` primitive, and an upgradeable initializer. Each section below states what changed and maps every covered property to its test. The rest is inherited Morpho, covered by the retained upstream suite: a few of those files are minimally adapted to the fork (an added `vm.prank(OWNER)`, proxy deployment in `setUp`), and where fork tests share an inherited file they sit below a `LIDO FORK TESTS` separator with no change to any inherited scenario.

| Change | Suites |
|---|---|
| Controller hooks | `HooksIntegrationTest`, `ControllerIntegrationTest`, `ReentrancyIntegrationTest` |
| `settle` | `SettleMathTest` (+ `SettleMathCrowdedTest` in the same file), `SettleIntegrationTest`, `SettleInvariantTest` |
| Upgradeable initializer | `InitializeIntegrationTest` |

Run with `forge test`. For deep fuzz campaigns raise the rejection cap alongside the runs (see FORK_NOTES "Tests and verification"): `FOUNDRY_FUZZ_RUNS=65536 FOUNDRY_FUZZ_MAX_TEST_REJECTS=4194304 forge test`.

Coverage (`forge coverage --report summary --no-match-coverage "test|mocks"`) is complete across `src/`:

| File | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| `src/LidoLend.sol` | 100% (274/274) | 100% (290/290) | 100% (139/139) | 100% (29/29) |
| `src/libraries/**` (8 files) | 100% (146/146) | 100% (142/142) | 100% (16/16) | 100% (52/52) |
| **Total** | **100% (420/420)** | **100% (432/432)** | **100% (155/155)** | **100% (81/81)** |

Three revert branches upstream left untested (`setFee` / `setFeeRecipient` `ALREADY_SET`, `safeTransfer` on a reverting token) are closed by coverage-closure tests under the `LIDO FORK TESTS` separators in `OnlyOwnerIntegrationTest` and `SafeTransferLibTest`.

The Certora specs (section 4) are the formal-verification layer on top of these tests: the inherited Morpho Blue properties re-proved against the fork, plus fork-specific rules for the hooks, the lock, and `settle`.

---

## 1. Controller hooks

**What changed.** A controller-hook dispatch (`_hook`) fires before the state writes of every state-changing action — supply, withdraw, borrow, repay, supplyCollateral, withdrawCollateral, liquidate, accrueInterest, and the new `settle`. The bound controller is optional, set once at market creation and checked against the market id it declares (`marketId()`). It can revert to veto an action. The dispatch holds a single **global** transient reentrancy lock (EIP-1153) for the length of the hook. `flashLoan` is the one state-touching path with no hook. A market with no controller dispatches no hook of its own, but is still subject to the global lock: its actions revert while another market's hook is in flight (covered below).

### Firing, payload, and veto (`HooksIntegrationTest`)

One test per hooked action covers both sides of the hook on a shared fixture. Settle's own hook tests live in `SettleIntegrationTest` (see section 2).

| Verifies | Test |
|---|---|
| A controller veto reverts the action with no state left behind (the touched shares/collateral/totals/token balances are unchanged), and the unblocked action dispatches the correct `HookEvent`, the bound market id, and a payload whose decoded fields match the resolved action | `testHook{Action}` (8 actions) |
| The liquidate payload's `repaidAssets` / `repaidShares` equal the core's resolution exactly (mirrored via the liquidation incentive factor) | part of `testHookLiquidate` |
| `HookEvent`'s numeric values are stable — controllers decode payloads per event, so inserting or reordering members would re-route decoding downstream | `testHookEventEnumValuesAreStable` |

### Binding at creation (`ControllerIntegrationTest`)

| Verifies | Test |
|---|---|
| Creation binds the controller and the settlement opt-in and emits `SetMarketController` / `EnableSettlement` | `testCreateMarketBindsControllerAndEmitsEvents` |
| With settlement off: controller bound, no `EnableSettlement` emitted | `testCreateMarketWithoutSettlementSkipsEnableEvent` |
| A zero controller is rejected regardless of the settlement flag | `testCreateMarketRevertsOnZeroController` |
| A controller declaring a different `marketId` is rejected | `testCreateMarketRevertsOnControllerMismatch` |

### Accrual ordering and hook pre-state (`HooksIntegrationTest`)

On a live-IRM market, a probing controller records `lastUpdate`, the totals, and the borrower's position at dispatch time; each assertion is exact (against `expectedMarketBalances` and pre-action snapshots), discriminating against the opposite ordering. This is what actually pins hook-before-writes on the success path — a veto alone cannot, since a revert rolls everything back.

| Verifies | Test |
|---|---|
| `supplyCollateral` does not accrue before its hook: stale `lastUpdate`, un-accrued totals, pre-deposit collateral seen, and the action never accrues at all | `testHookSupplyCollateralDoesNotAccrueBeforeHook` |
| `withdrawCollateral` accrues first: fresh `lastUpdate`, the exact accrued totals, and the pre-withdraw collateral | `testHookWithdrawCollateralAccruesBeforeHook` |
| `accrueInterest` fires its hook before accruing: pre-accrual state seen, totals grow only afterwards | `testHookAccrueInterestFiresBeforeAccruing` |
| The Supply hook sees post-accrue, pre-supply totals: interest realized, the incoming deposit not yet booked | `testHookSupplySeesPostAccruePreSupplyState` |
| The Borrow hook sees the pre-borrow position (new shares not yet minted) | `testHookBorrowSeesPreBorrowPosition` |
| The Liquidate hook sees the pre-seizure position (collateral and debt shares decremented after it) | `testHookLiquidateSeesPreSeizePosition` |
| The Settle hook sees the pre-cut position — a controller re-reading the core mid-hook gets the state the cut applies to | `testHookSettleSeesPreCutPosition` |

### Reentrancy lock (`ReentrancyIntegrationTest`)

The lock is a single global flag, held for the length of the hook and released before state writes and Morpho callbacks. Each test arms a reentrant call that is valid on its own (positions funded, controller approved/authorized) and uses `vm.expectCall` as a negative control, so only the lock can stop it.

| Verifies | Test |
|---|---|
| Reentering the same market during its hook reverts `HOOK_REENTRANCY` | `testReentrancy{Action}Blocked` (8 actions), `testReentrancySettleBlockedEvenWithinLimits` |
| A hook re-entering through another market still reverts — the nested action never reaches the second market's hook | `testSameMarketReentryThroughOtherMarketHookBlocked` |
| An action on a different controlled market is blocked mid-hook | `testOtherControlledMarketActionBlockedDuringHook` |
| Even a no-controller market's action is blocked mid-hook | `testHooklessMarketActionBlockedDuringHook` |
| `flashLoan` dispatches no hook and is not locked | `testFlashLoanAllowedDuringHook` |
| A Morpho callback (after the hook and the state writes) can reenter — the upstream leverage pattern survives | `testCallbackAfterHookCanReenter` |

---

## 2. `settle`

**What changed.** A new fallback exit: it cancels a borrower's debt against a lender's supply shares and transfers the seized collateral to a receiver, at the oracle price with no liquidation incentive. Usable only on a market that opted in at creation, and only on the part of the lender's supply that ordinary withdrawal liquidity cannot serve (`_settleableSupply` = the supply value beyond free liquidity). The core does not itself prevent bad debt from a cut — that is delegated to the bound controller, consulted via its hook before the write.

`SettleMathTest` holds the arithmetic, rounding, and boundary cases; `SettleIntegrationTest` the access-control, hook/event, and lifecycle cases; `SettleInvariantTest` the stateful fuzz.

### Guards and authorization (`SettleIntegrationTest`)

| Verifies | Test |
|---|---|
| All six pre-derivation guards, asserted in the core's check order on one live position: market not created, settlement disabled, inconsistent input, zero receiver, unauthorized caller, borrower with no debt | `testSettleGuardReverts` |
| A lender whose supply sits within free liquidity (settleable = 0) cannot settle at all — fuzzed across the whole zero-settleable range, rejected cleanly before the share subtraction | `testSettleCannotCancelMoreThanOwned` |
| An address authorized by approval can cut for the lender | `testSettleAuthorizedViaApproval` |
| An address authorized by an EIP-712 signature can cut for the lender (nonce consumed) | `testSettleAuthorizedViaSig` |

### Gate and cap boundaries (`SettleMathTest`)

Each cap has its own revert string, fuzzed across its whole over-cap window rather than a single point; passing-side boundaries are pinned separately.

| Verifies | Test |
|---|---|
| The exact-settleable cut passes; any fuzzed excess above it reverts (in this single-borrower fixture settleable equals the debt, so the whole window trips `SETTLEMENT_EXCEEDS_DEBT`) | `testSettleLiquidityGateBoundary` |
| Seizing past the borrower's collateral reverts | `testSettleOverCapCollateral` |
| Cancelling past the borrower's debt reverts | `testSettleOverCapBorrowShares` |
| A slice seizing zero collateral reverts | `testSettleOverCapZeroCollateral` |
| The borrow-share anchor does not bypass the zero-seize guard | `testSettleCloseBlockedWhenSeizeRoundsToZero` |
| Passing side: a seizure equal to the whole collateral succeeds, stripping it to zero while the debt stays open (only the controller can forbid that) | `testSettleSeizeExactlyAllCollateral` |
| Passing side: the smallest non-zero seizure succeeds | `testSettleSliceSeizureBoundary` |
| The gate's 1-wei edge: a sole borrower spanning the whole pool cannot be closed via `borrowShares` when the lender holds no surplus (the round-up overshoots settleable by exactly one wei); the supply-anchored exit still clears | `testSettleSoleBorrowerWholePoolBlockedByCap` |

### Exact arithmetic (`SettleMathTest`)

Every fuzz pins each touched slot with an exact-equality delta plus formula-independent invariants (free liquidity preserved, receiver paid, no loan tokens move).

| Verifies | Test |
|---|---|
| The supply anchor on a driftless market, across fuzzed prices, collateral, free liquidity, and slice sizes | `testSettleSuccessFuzz` |
| The supply anchor with a drifted share index and a fuzzed price active together (both rounding legs) | `testSettleDriftedIndexWithPriceFuzz` |
| A borrow-anchored cut strictly within the holding, under drift × price | `testSettleBorrowAnchoredPartialFuzz` |
| A share slice under drift: the burned debt shares valued back equal the cancelled debt exactly (an under-burn would drain the pool) | `testSettleShareRoundingWithInterestFuzz` |
| An asset target under drift: the burned supply shares valued back equal the cancelled debt exactly | `testSettleAssetTargetRoundingWithInterestFuzz` |
| Settle realizes pending interest itself, and the cut is derived from the post-accrual totals (asserted against `expectedMarketBalances`) | `testSettleAccruesInterest` |

### Position closure (`SettleMathTest`, `SettleIntegrationTest`)

| Verifies | Test |
|---|---|
| The borrow anchor closes a holding whose asset value cannot (the round-trip overshoots the holding in both rounding directions), with the full rounding ledger: who pays the wei, who is relieved, share prices, solvency | `testSettleClosePositionRoundsBurnPastHolding` |
| Passing the lender's whole supply-share balance exits the position to exactly zero | `testSettleClosesLenderSupplyToZero` |
| Borrow-anchored close to zero: exact deltas, the `Settle` event, and the hook payload (the exact debt-share input plus derived values) | `testSettleBorrowAnchoredClosesToZero` |
| The close across a fuzzed price range | `testSettleBorrowAnchoredCloseFuzz` |
| A partly-settled borrower clears the residual and withdraws the rest — no residual debt, no stuck collateral | `testSettleBorrowerExitsWhole` |
| Cancelling the whole stake zeroes the market exactly, and a fresh deposit round-trips — not bricked | `testSettleFullDrainLeavesMarketUsable` |
| A lender == borrower loop: supply burn and borrow/collateral seizure hit distinct fields | `testSettleSelfPosition` |
| A cut on an underwater position is not socialized: supply falls only by the canceled amount, the residual debt stays on the borrower (`liquidate` would write down here, `settle` does not) | `testSettleBadDebtNotRealizedFuzz` |

### Hook and event (`SettleIntegrationTest`)

| Verifies | Test |
|---|---|
| The core validates the cut before consulting the controller: invalid cuts revert with the core's error and the settle hook is never dispatched (controllers trust `shares <= debt`, `0 < seize <= collateral` without re-checking) | `testSettleGuardsPrecedeHook` |
| A controller veto reverts and leaves every touched slot unchanged | `testSettleControllerCanBlock` |
| The decoded `SettleHookData`, `lastEvent`/`lastId`, and the exact `Settle` event fields, in one pass | `testSettleHookPayloadAndEvent` |

### Crowded rerun (`SettleMathCrowdedTest`)

Reruns the whole `SettleMathTest` suite with a bystander lender and borrower (equal supply and borrow) seeded into the market, pinning every assertion to relative deltas rather than a single-lender/single-borrower world. The two wei-pinned fixtures (`_dustyTwoBorrowerMarket`, the sole-borrower edge) are deliberately not seeded — extra actors would destroy the states they pin.

### Stateful fuzz (`SettleInvariantTest`)

One controller-bound market with two borrowers and a bystander lender, kept near zero free liquidity; `warp` drifts the index, `setControllerPrice` swings health, and a solvency-enforcing controller mock stands in for the production bad-debt backstop. The handlers (`settleNoRevert`, `settleCloseNoRevert`) mirror every core check, then assert the exact post-state of each successful cut against the contract's returned values.

| Verifies | Test |
|---|---|
| A solvency-preserving cut executes with exact deltas — deterministic, so the suite cannot silently go vacuous | `testSettleHappyPath` |
| An insolvent-leaving cut is rejected by the controller (the bad-debt backstop) | `testControllerBlocksInsolventCut` |
| A slice above the settleable supply is rejected by the gate, fuzzed across the over-cap window | `testSettleBlockedAboveSettleableSupply` |
| Share conservation across all handlers, with the bystander lender and borrower untouched by every cut | `invariantSupplyShares`, `invariantBorrowShares` |

The bad-debt backstop is the production controller's responsibility. That controller is not in this repo — it is the assumption to lean on (`testControllerBlocksInsolventCut` stands in via a mock enforcing post-cut solvency).

---

## 3. Upgradeable initializer

**What changed.** The core runs behind a proxy: the constructor petrifies the implementation, `initialize(owner)` replaces the constructor's owner-set, and `DOMAIN_SEPARATOR` became a view recomputed from `block.chainid` + `address(this)` instead of a bytecode immutable.

Tests deploy through the `TestProxy` harness (`InitializeIntegrationTest`).

| Verifies | Test |
|---|---|
| The full lifecycle on one fresh proxy: starts uninitialized, rejects a zero owner, initializes exactly once (owner set, `SetOwner` emitted), then never again | `testInitializeLifecycleOnFreshProxy` |
| The shared proxy, initialized atomically through the constructor's initData (the production deployment path), cannot be re-initialized to seize ownership | `testCannotReinitializeProxy` |
| The bare implementation deploys locked (`isInitialized`, no owner) and cannot be initialized directly | `testImplementationIsPetrified` |
| The proxy and the implementation each derive the exact separator from their own address and the live `block.chainid`; after a simulated chain split the proxy's separator tracks the new id | `testDomainSeparatorBindsToAddressAndChainId` |

---

## 4. Formal verification (Certora specs)

**What it is.** The Morpho Blue Certora specs, carried over and extended to the fork. Every parametric rule (`method f`) automatically quantifies over the fork's entrypoints — the controller `createMarket` overload, `settle`, and the hook dispatch inside every action — so the inherited properties double as fork regression proofs; fork-added rules are marked `Fork:` in the spec comments. Specs live in `certora/specs/`, one runner conf each in `certora/confs/`; CI runs the full matrix from `.github/workflows/certora.yml`. Two specs (`LibSummary`, `Transfer`) exist to validate the CVL summaries the others rely on.

**`ConsistentState.spec` — global state consistency.**
- Share accounting — `sumSupplySharesCorrect` / `sumBorrowSharesCorrect`: market totals equal the sum of per-user positions.
- Solvency — `borrowLessThanSupply` (markets are independent); `idleAmountLessThanBalance`: the contract's token balance covers the summed obligations of all markets.
- Market identity — `hashOfMarketParamsOf` / `marketParamsOfHashOf` / `libIdUnique` / `idToMarketParamsForCreatedMarketCannotChange`: id ↔ params is injective and frozen at creation; `onlyEnabledIrm` / `onlyEnabledLltv` / `lltvSmallerThanWad` / `irmCannotBeDisabled` / `lltvCannotBeDisabled`.
- Unauthorized-access safety — `userCannotLoseSupplyShares`, `userCannotGainBorrowShares`, `userCannotLoseCollateralExceptLiquidateOrSettle`, `userWithoutBorrowCannotLoseCollateral` (no debt ⇒ collateral untouchable, **including** by `settle`), `onlyUserCanAuthorizeWithoutSig`, `nonceCannotDecrease`.
- Fork — `settleOnlyReducesTargetedBorrowerCollateral`: a cut touches only the targeted borrower's collateral, only in the settled market, only downward, and only if the borrower had debt.
- Timekeeping — `noTimeTravel` / `lastUpdateNonZero` / `lastUpdateCannotDecrease`; `feeInRange`.

**`Health.spec` / `StayHealthy.spec` — position health.**
- `healthyUserCannotLoseCollateral` — a healthy position cannot be cut by third parties (`settle` excluded by design: it has no core health gate; borrower protection is the controller's duty).
- `alwaysCollateralized` — debt implies collateral (`settle` excluded by design: a cut may leave residual debt on empty collateral for a later liquidation to socialize).
- `stayHealthy` — no interaction turns a healthy account unhealthy, with the liquidate case split to stay tractable (`stayHealthyLiquidate` / `...DifferentMarkets` / `...LastBorrow`).
- Fork — the settle case, split the same way: `stayHealthySettleBorrowAnchored` / `...LastBorrow` / `stayHealthySettleDifferentMarkets` — a borrow-anchored cut cannot degrade any third party's health, and a cut on another market touches nothing. Deliberate non-claim: the supply-anchored path burns borrow shares rounded up, which can shift the pooled rate by one ULP and flip a borderline third-party position — the standard adverse-to-user Morpho rounding, documented in the spec instead of claimed.
- `liquidateEquivalentInputDebtAndInputCollateral` — seized-input and shares-input liquidations resolve equivalently.

**`ExchangeRate.spec` — share-price monotonicity.**
- Supply side: `accrueInterestIncreasesSupplyExchangeRate`, `onlyLiquidateCanDecreaseSupplyExchangeRate` (`settle` **included** — a cut cannot hurt remaining suppliers), `liquidateWithoutBadDebtRealizationIncreasesSupplyExchangeRate`.
- Borrow side: `accrueInterestIncreasesBorrowExchangeRate`, `onlyAccrueInterestCanIncreaseBorrowExchangeRate` (repay/liquidate/settle excluded), `repayDecreasesBorrowExchangeRate`, `liquidateDecreasesBorrowExchangeRate`.
- Fork — `settleBorrowAnchoredDecreasesBorrowExchangeRate`: the borrow-anchored cut can only lower residual borrowers' per-share debt (the positive counterpart of settle's exclusion above; the supply-anchored path is the one that can nudge it up by a ULP).

**`ExactMath.spec` — no-arbitrage under exact arithmetic.** `supplyWithdraw` and `borrowRepay` (no profit from a same-block round-trip), `repayAllResetsBorrowExchangeRate`.

**`AssetsAccounting.spec` — per-action accounting.**
- `supply/withdraw/borrow/repay-AssetsAccounting` — share↔asset conversion rounds in the protocol's favour on every action; `supplyCollateral/withdrawCollateral-AssetsAccounting` — collateral is 1:1.
- Fork — `settleAssetsAccounting`: both asset totals fall by exactly `debtCanceled` (par, no incentive) and the burned shares come entirely from `onBehalf` / `borrower`; `settleBorrowAnchoredClosesPosition`: passing the borrower's whole debt-share balance closes the position to exactly zero.

**`Liveness.spec` — executability and token conservation.**
- `*ChangesTokensAndShares` (supply, withdraw, borrow, repay, supplyCollateral, withdrawCollateral, liquidate) — token balances, positions, and liquidity move consistently; `can*ByPassingShares` reachability checks; `setAuthorizationWithSigChangesNonceAndAuthorizes`.
- Exit liveness — `canRepayAll` / `canWithdrawAll` / `canWithdrawCollateralAll`: a borrower/lender can always fully exit. The controller hook is modeled as non-reverting, so on controller-bound markets this holds modulo the controller's veto policy — the core itself never blocks an exit.
- Fork — `canSettleBorrowAnchored` / `canSettleSupplyAnchored`: the completeness direction of settle's guards — when every documented precondition holds, the cut succeeds.

**`Reverts.spec` — revert conditions.**
- Input validation for every entrypoint (supply, withdraw, borrow, repay, supplyCollateral, withdrawCollateral, flashLoan, liquidate, accrueInterest, setFee, setFeeRecipient, setOwner, setAuthorizationWithSig, both `createMarket` overloads — including the fork's zero-controller and `marketId()`-mismatch gates — and `settle`).
- Fork, settle economic guards (one-directional `condition ⇒ revert`, per anchor): `settleLiquidityAvailableReverts{Supply,Borrow}Anchored`, `settleCollateralCutReverts{Supply,Borrow}Anchored`, `settleExceedsDebtReverts{Supply,Borrow}Anchored`, plus `settleNoDebtReverts` (a debtless borrower cannot be settled — emergent from the exceeds-debt and slice-too-small guards).
- Fork — `hookLockFreezesMarketActions`: while a controller hook is in flight, all nine hooked entrypoints revert `HOOK_REENTRANCY`; `flashLoan`, authorization, and admin setters stay callable by design.

**`AccrueInterest.spec` — accrual ordering.** `supply/withdraw/borrow/repayAccruesInterest` (an explicit `accrueInterest` before the action is a no-op) and `accrueInterestCommutesExceptForSetFeeRecipient`.

**`Reentrancy.spec` — call-pattern safety.** `reentrancySafe` (no storage→external-call→storage pattern; the IRM and controller-hook calls are the trusted exceptions — the hook's own protection is the lock, machine-checked in `Reverts.spec`) and `noDelegateCalls` (immutability).

**`LiquidateBuffer.spec` — cut economics.**
- `liquidateImprovePosition` — liquidating a position with LTV < 1/LIF improves its health.
- Fork — `settleSeizesAtMostParCollateral`: the par guarantee for the settled borrower — the value of collateral seized never exceeds the value of debt canceled, in either anchor path (settle has no liquidation incentive). Deliberate non-claim: a boolean "settled borrower stays healthy" does not hold at wei granularity (two floor roundings can cost a borderline position one wei of headroom), documented in the spec.

**`Transfer.spec` / `LibSummary.spec` — summary validation.** Functional correctness and revert conditions of the `safeTransfer` / `safeTransferFrom` summary; `mulDivUp` / `mulDivDown` rounding bounds, `id()` hashing, `min`.

**Modeling caveats.** Controller hooks are arbitrary non-reverting external calls (`NONDET`/`HAVOC_ECF` per spec) — properties hold for *any* controller policy, but hook-veto liveness is out of model; most economic rules pin zero elapsed interest (`lastUpdate == now`) and, where reconstruction is needed, a constant oracle price. These assumptions are stated inline as `require`s in each rule.

---

## Storage layout

The fork storage fields are round-trip checked via `MorphoStorageLib` (`MorphoStorageLibTest::testStorageForkSlots`), which also pins every slot constant to its literal position — the nine upstream slots at 0–8 and the fork slots at 9–11 — so a layout reshuffle fails loudly there.
