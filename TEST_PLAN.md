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

**What changed.** A new fallback exit: it cancels a borrower's debt against a lender's supply shares and transfers the seized collateral to a receiver, at the oracle price with no liquidation incentive. It is usable only on a controller-bound market that opted in at creation. The core requires the exact `supplySharesBurned` to be owned by `onBehalf`; the bound controller's hook runs before the write and may revert.

`SettleMathTest` holds the arithmetic, rounding, and boundary cases; `SettleIntegrationTest` the access-control, hook/event, and lifecycle cases; `SettleInvariantTest` the stateful fuzz.

### Guards and authorization (`SettleIntegrationTest`)

| Verifies | Test |
|---|---|
| All six pre-derivation guards, asserted in the core's check order on one live position: market not created, settlement disabled, inconsistent input, zero receiver, unauthorized caller, borrower with no debt | `testSettleGuardReverts` |
| Settlement succeeds when the hook returns and the lender owns the requested shares, even if its supply value equals all available free liquidity | `testSettleWhenSupplyEqualsFreeLiquidity` |
| An address authorized by approval can cut for the lender | `testSettleAuthorizedViaApproval` |
| An address authorized by an EIP-712 signature can cut for the lender (nonce consumed) | `testSettleAuthorizedViaSig` |

### Ownership and cap boundaries (`SettleMathTest`)

Each cap has its own revert string, fuzzed across its whole over-cap window rather than a single point; passing-side boundaries are pinned separately.

| Verifies | Test |
|---|---|
| The core ownership boundary is independent of free liquidity: settlement succeeds when the hook returns and the lender owns every burned share | `testSettleOwnershipBoundaryIndependentOfFreeLiquidity` |
| Supply anchoring accepts exactly all owned shares and rejects owned shares plus one with `SETTLEMENT_EXCEEDS_SUPPLY` | `testSettleSupplyAnchoredOwnershipBoundary` |
| Seizing past the borrower's collateral reverts | `testSettleOverCapCollateral` |
| Cancelling past the borrower's debt reverts | `testSettleOverCapBorrowShares` |
| A slice seizing zero collateral reverts | `testSettleOverCapZeroCollateral` |
| The borrow-share anchor does not bypass the zero-seize guard | `testSettleCloseBlockedWhenSeizeRoundsToZero` |
| Passing side: a seizure equal to the whole collateral succeeds when the hook returns, stripping it to zero while the debt stays open | `testSettleSeizeExactlyAllCollateral` |
| Passing side: the smallest non-zero seizure succeeds | `testSettleSliceSeizureBoundary` |
| At a non-round supply-share price, a borrow-anchored full close whose rounded burn exceeds ownership reverts with `SETTLEMENT_EXCEEDS_SUPPLY`; anchoring on all owned supply shares still succeeds | `testSettleBorrowAnchoredFullCloseExceedsOwnedSupply` |
| At a non-round supply-share price, a borrow-anchored full close succeeds when the derived burn equals all owned shares exactly | `testSettleBorrowAnchoredFullCloseAtExactOwnershipBoundary` |
| Across drifted indexes, the largest borrow-anchored cut whose rounded burn fits the position succeeds, while the full close over the ownership boundary reverts cleanly rather than underflowing | `testSettleBorrowAnchoredMaxCutBurnWithinSupplyFuzz` |

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
| Passing the lender's whole supply-share balance exits the position to exactly zero; passing one more share is rejected | `testSettleSupplyAnchoredOwnershipBoundary` |
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

Reruns the whole `SettleMathTest` suite with a bystander lender and borrower (equal supply and borrow) seeded into the market, pinning every assertion to relative deltas rather than a single-lender/single-borrower world. Wei-pinned fresh-market fixtures deliberately do not seed extra actors because that would destroy the states they pin.

### Stateful fuzz (`SettleInvariantTest`)

One controller-bound market with two borrowers and a bystander lender, kept near zero free liquidity; `warp` drifts the index, `setControllerPrice` swings health, and the test controller rejects cuts that would leave an insolvent borrower. The handlers (`settleNoRevert`, `settleCloseNoRevert`) mirror every core check, then assert the exact post-state of each successful cut against the contract's returned values.

| Verifies | Test |
|---|---|
| A solvency-preserving cut executes with exact deltas — deterministic, so the suite cannot silently go vacuous | `testSettleHappyPath` |
| An insolvent-leaving cut is rejected by the test controller | `testControllerBlocksInsolventCut` |
| A solvent slice whose size exceeds the lender's supply beyond free liquidity succeeds when the hook returns | `testSettleBeyondFreeLiquidity` |
| Share conservation across all handlers, with the bystander lender and borrower untouched by every cut | `invariantSupplyShares`, `invariantBorrowShares` |

The solvency check in this stateful suite is one concrete test-controller behavior, not a requirement imposed by the core on production controllers.

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

## Storage layout

The fork storage fields are round-trip checked via `MorphoStorageLib` (`MorphoStorageLibTest::testStorageForkSlots`), which also pins every slot constant to its literal position — the nine upstream slots at 0–8 and the fork slots at 9–11 — so a layout reshuffle fails loudly there.
