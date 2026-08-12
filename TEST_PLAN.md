# LidoLend Fork — Test Plan

This document maps fork requirements to the Foundry tests that exercise them; it is a coverage inventory, not a test-run report. Applicable inherited Morpho tests remain in the suite; tests for removed APIs and superseded creation guards do not. Fork-only cases in a shared file appear below a `LIDO FORK TESTS` separator.

| Change | Suites |
|---|---|
| Owner-gated creation and controller binding | `OnlyOwnerIntegrationTest`, `CreateMarketIntegrationTest`, `ControllerIntegrationTest` |
| Controller hooks | `HooksIntegrationTest`, `ReentrancyIntegrationTest`, `SettleIntegrationTest` |
| `settle` | `SettleMathTest`, `SettleMathCrowdedTest`, the four suites in `test/integration/SettleIncidenceTest.sol`, `SettleIntegrationTest`, `SettleInvariantTest` |
| Upgradeable initializer and storage | `InitializeIntegrationTest`, `MorphoStorageLibTest` |

Run `forge test` for the complete Foundry suite. Run `forge coverage --report summary --no-match-coverage "test|mocks"` to produce coverage for the exact commit being reviewed. Do not copy percentages from an earlier commit: coverage can change without changing the test inventory.

For deep fuzz campaigns, raise both the run count and Foundry's rejection limit: `FOUNDRY_FUZZ_RUNS=65536 FOUNDRY_FUZZ_MAX_TEST_REJECTS=4194304 forge test`.

---

## 1. Controller hooks

The [Controller hooks](SPECIFICATION.md#controller-hooks) section defines the runtime behavior. The tests below cover dispatch, payloads, action-specific ordering, veto rollback, controller binding, and the global hook lock.

### Firing, payload, and veto (`HooksIntegrationTest`)

One test per hooked action covers both sides of the hook on a shared fixture. Settle's own hook tests live in `SettleIntegrationTest` (see section 2).

| Verifies | Test |
|---|---|
| A controller veto reverts and the state captured by the test is unchanged; the successful path dispatches the correct `HookEvent`, market id, and resolved payload | `testHookSupply`, `testHookWithdraw`, `testHookBorrow`, `testHookRepay`, `testHookSupplyCollateral`, `testHookWithdrawCollateral`, `testHookLiquidate`, `testHookAccrueInterest` |
| The liquidate payload's `repaidAssets` / `repaidShares` equal the core's resolution exactly (mirrored via the liquidation incentive factor) | part of `testHookLiquidate` |
| `HookEvent`'s numeric values are stable — controllers decode payloads per event, so inserting or reordering members would re-route decoding downstream | `testHookEventEnumValuesAreStable` |

### Binding at creation (`OnlyOwnerIntegrationTest`, `CreateMarketIntegrationTest`, `ControllerIntegrationTest`)

| Verifies | Test |
|---|---|
| The plain and controlled creation overloads reject a non-owner caller | `testCreateMarketWhenNotOwner`, `testCreateMarketWithControllerWhenNotOwner` |
| First use enables the selected IRM and LLTV; later markets using the same values do not emit duplicate enable events | `testCreateMarketEnablesIrmAndLltv`, `testCreateMarketDoesNotReEnable` |
| Creation binds the controller and the settlement opt-in and emits `SetMarketController` / `EnableSettlement` | `testCreateMarketBindsControllerAndEmitsEvents` |
| With settlement off: controller bound, no `EnableSettlement` emitted | `testCreateMarketWithoutSettlementSkipsEnableEvent` |
| The controlled overload rejects a zero controller regardless of the settlement flag; the plain overload is the path for a no-controller market | `testCreateMarketRevertsOnZeroController` |
| A controller declaring a different `marketId` is rejected | `testCreateMarketRevertsOnControllerMismatch` |

### Accrual ordering and hook pre-state (`HooksIntegrationTest`)

On a market with a non-zero interest-rate model (IRM) and elapsed time, a probing controller records `lastUpdate`, totals, and the borrower's position at dispatch time. The tests compare them with `expectedMarketBalances` and pre-action snapshots. A controller veto cannot establish this ordering by itself because a revert rolls back every earlier write.

| Verifies | Test |
|---|---|
| `supplyCollateral` does not accrue before its hook: stale `lastUpdate`, un-accrued totals, pre-deposit collateral seen, and the action never accrues at all | `testHookSupplyCollateralDoesNotAccrueBeforeHook` |
| `withdrawCollateral` accrues first: fresh `lastUpdate`, the exact accrued totals, and the pre-withdraw collateral | `testHookWithdrawCollateralAccruesBeforeHook` |
| `accrueInterest` fires its hook before accruing: pre-accrual state seen, totals grow only afterwards | `testHookAccrueInterestFiresBeforeAccruing` |
| The Supply hook sees post-accrue, pre-supply totals: interest realized, the incoming deposit not yet booked | `testHookSupplySeesPostAccruePreSupplyState` |
| The Borrow hook sees the pre-borrow position (new shares not yet minted) | `testHookBorrowSeesPreBorrowPosition` |
| The Liquidate hook sees the pre-seizure position (collateral and debt shares decremented after it) | `testHookLiquidateSeesPreSeizePosition` |
| The Settle hook sees the pre-settlement position, so a controller reading the core during the hook gets the state to which the requested settlement applies | `testHookSettleSeesPreCutPosition` |

There is no elapsed-interest probing test for the Withdraw or Repay hook state; their generic dispatch tests use a zero-rate IRM.

### Reentrancy lock (`ReentrancyIntegrationTest`)

These tests arm otherwise executable nested calls while a controller hook holds the global lock.

| Verifies | Test |
|---|---|
| Reentering the same market during its hook reverts `HOOK_REENTRANCY` | `testReentrancySupplyBlocked`, `testReentrancyWithdrawBlocked`, `testReentrancyBorrowBlocked`, `testReentrancyRepayBlocked`, `testReentrancySupplyCollateralBlocked`, `testReentrancyWithdrawCollateralBlocked`, `testReentrancyLiquidateBlocked`, `testReentrancyAccrueInterestBlocked`, `testReentrancySettleBlockedEvenWithinLimits` |
| A hook cannot enter a different controlled market; the nested action stops before the second controller hook | `testOtherControlledMarketActionBlockedDuringHook`, `testSameMarketReentryThroughOtherMarketHookBlocked` |
| Even a no-controller market's action is blocked mid-hook | `testHooklessMarketActionBlockedDuringHook` |
| `flashLoan` dispatches no hook and is not locked | `testFlashLoanAllowedDuringHook` |
| An `onMorpho*` callback runs after the hook and state writes and can enter another hooked action | `testCallbackAfterHookCanReenter` |

These tests cover controller-hook reentrancy. No Foundry regression exercises reentry from the selected IRM during `borrowRate`; non-reentrant IRM behavior remains a trust assumption.

---

## 2. `settle`

[Settlement](SPECIFICATION.md#settlement) defines the mechanism and formulas. `SettleMathTest` covers arithmetic and boundaries, `SettleIntegrationTest` covers authorization, hooks, events, and lifecycle behavior, and `SettleInvariantTest` supplies stateful fuzz coverage.

### Guards and authorization (`SettleIntegrationTest`)

| Verifies | Test |
|---|---|
| Guard ordering across checks before accrual and checks after derivation: market not created, settlement disabled, zero borrow-share input, zero receiver, unauthorized caller, and an input above the borrower's debt shares | `testSettleGuardReverts` |
| An address authorized by approval can settle for the supply owner | `testSettleAuthorizedViaApproval` |
| An address authorized by an Ethereum typed-data (EIP-712) signature can settle for the supply owner, consuming the nonce | `testSettleAuthorizedViaSig` |

### Ownership and balance boundaries (`SettleMathTest`)

| Verifies | Test |
|---|---|
| The core ownership boundary is independent of free liquidity: settlement succeeds when the hook returns and the lender owns every burned share | `testSettleOwnershipBoundaryIndependentOfFreeLiquidity` |
| A borrow-share input whose derived supply burn equals all owned shares succeeds, and one more borrow share reverts with `SETTLEMENT_EXCEEDS_SUPPLY` | `testSettleDerivedSupplyOwnershipBoundary` |
| Seizing past the borrower's collateral reverts | `testSettleOverCapCollateral` |
| Cancelling past the borrower's debt reverts | `testSettleOverCapBorrowShares` |
| A settlement with zero calculated collateral output reverts | `testSettleOverCapZeroCollateral` |
| An exact full-share close does not bypass the zero-seize guard | `testSettleCloseBlockedWhenSeizeRoundsToZero` |
| Passing side: a seizure equal to the whole collateral succeeds when the hook returns, stripping it to zero while the debt stays open | `testSettleSeizeExactlyAllCollateral` |
| Passing side: the smallest non-zero seizure succeeds | `testSettleSliceSeizureBoundary` |
| At a non-round supply-share price, a full close whose rounded burn exceeds ownership reverts with `SETTLEMENT_EXCEEDS_SUPPLY` and leaves both positions unchanged | `testSettleFullCloseExceedsOwnedSupply` |
| At a non-round supply-share price, a full close succeeds when the derived burn equals all owned shares exactly | `testSettleFullCloseAtExactOwnershipBoundary` |
| After share prices change, the largest exact borrow-share input whose rounded burn fits succeeds, while a full close above the ownership boundary reverts | `testSettleMaxCutBurnWithinSupplyFuzz` |

### Exact arithmetic (`SettleMathTest`)

The fuzz cases recompute settlement amounts and check exact deltas for the position and market fields they capture. `testSettleSuccessFuzz` also checks the receiver's collateral and that settlement moves no loan tokens. Inputs are constrained so the final oracle conversion produces at least one raw collateral unit.

| Verifies | Test |
|---|---|
| Exact borrow-share settlement before share prices change, across fuzzed prices, collateral, free liquidity, and input sizes | `testSettleSuccessFuzz` |
| Exact borrow-share settlement after the share price changes, with a fuzzed collateral price | `testSettleDriftedIndexWithPriceFuzz` |
| After interest changes share prices, the input borrow shares are burned exactly, debt assets and supply shares are derived upward, and collateral is derived from the same shares valued downward | `testSettleShareRoundingWithInterestFuzz` |
| When one raw borrow share is worth more than one asset unit, the exact share input is burned and the canceled assets and supply burn match their upward-rounded conversions | `testSettleExpensiveBorrowShareUsesExactShareCut` |
| Settlement realizes pending interest, and canceled debt assets use the post-accrual borrow totals from `expectedMarketBalances` | `testSettleAccruesInterest` |

### Rounding allocation and edge cases (`test/integration/SettleIncidenceTest.sol`)

| Verifies | Test |
|---|---|
| Across changed share prices and a fuzzed oracle price: the borrower does not lose more collateral value than its debt relief, the calculated collateral output is not worth more than `onBehalf`'s surrendered supply claim, and an untouched borrower's down-rounded debt value does not increase | `testIncidenceFuzz` |
| A borrower with no debt cannot be settled against for any input, even on a market where one raw borrow share is worth more than one asset unit | `testDebtlessBorrowerCannotBeSettledFuzz` |
| A zero borrow-share input is rejected before any amount is calculated | `testZeroCutRejected` |
| When upward valuation exceeds total borrow assets by one raw unit, the new total is floored at zero instead of underflowing and the supply total decreases by the full canceled amount | `testZeroFloorSubIsExercised` |
| A full settlement of a sub-unit debt holding whose calculated collateral output is zero reverts with `SETTLEMENT_SLICE_TOO_SMALL` | `testDustPositionCannotBeClosed` |

### Position closure (`SettleMathTest`, `SettleIntegrationTest`)

| Verifies | Test |
|---|---|
| When asset-to-share conversion overshoots a holding, the exact-share close zeros it and checks canceled assets, seized collateral, supply and borrow totals, bystander debt, and unchanged free liquidity | `testSettleClosePositionRoundsBurnPastHolding` |
| Full close to zero: exact deltas, the `Settle` event, and the hook payload | `testSettleClosesToZero` |
| Across a fuzzed healthy price range, a full-share cut closes the borrower, returns the expected debt and collateral amounts, and preserves zero free liquidity | `testSettleCloseFuzz` |
| After a partial settlement, full-share repayment zeros the remaining debt and full collateral withdrawal returns every unseized collateral unit | `testSettleBorrowerExitsWhole` |
| A full cut zeros all four market totals; a subsequent supply and full-share withdrawal round-trip exactly | `testSettleFullDrainLeavesMarketUsable` |
| A lender == borrower loop: supply burn and borrow/collateral seizure hit distinct fields | `testSettleSelfPosition` |
| Settlement on an underwater position does not socialize residual debt: supply decreases only by the canceled amount, and remaining debt shares stay on the borrower | `testSettleBadDebtNotRealizedFuzz` |
| When settlement exhausts collateral while leaving expensive borrow shares, direct one-share liquidation reverts; with a permissive controller, a one-unit collateral top-up can be seized to trigger repayment and bad-debt realization | `testOneCollateralUnitTopUpEnablesBadDebtRealization` |

### Hook and event (`SettleIntegrationTest`)

| Verifies | Test |
|---|---|
| Debt- and collateral-cap failures use the core error and do not dispatch the settle hook | `testSettleGuardsPrecedeHook` |
| A controller veto reverts and the positions and receiver balance captured by the test remain unchanged | `testSettleControllerCanBlock` |
| The decoded `SettleHookData`, `lastEvent`/`lastId`, and the exact `Settle` event fields, in one pass | `testSettleHookPayloadAndEvent` |

### Crowded rerun (`SettleMathCrowdedTest`)

`SettleMathCrowdedTest` inherits the arithmetic suite and seeds a matched bystander lender and borrower. Tests that require wei-pinned fresh-market states retain the base fixture.

### Stateful fuzz (`SettleInvariantTest`)

The invariant suite uses one controller-bound market with two borrowers and another lender, kept near zero free liquidity. `warp` changes share prices through interest, `setControllerPrice` changes health, and `topUpControllerMarket` grows positions. The `settleNoRevert` handler filters to core-valid, controller-accepted cuts and checks the exact deltas of every executed settlement.

| Verifies | Test |
|---|---|
| A deterministic solvency-preserving settlement executes with exact deltas, ensuring that the suite exercises a successful path | `testSettleHappyPath` |
| A settlement that would leave the borrower insolvent is rejected by the test controller | `testControllerBlocksInsolventCut` |
| A solvent settlement beyond free market liquidity succeeds when the supply owner has enough shares and the hook returns | `testSettleBeyondFreeLiquidity` |
| Share conservation across all handlers, with the other lender and borrower untouched by every settlement | `invariantSupplyShares`, `invariantBorrowShares` |

The solvency check in this stateful suite is one concrete test-controller behavior, not a requirement imposed by the core on production controllers.

---

## 3. Upgradeable initializer

[Proxy and storage](SPECIFICATION.md#proxy-and-storage) defines the required behavior. `InitializeIntegrationTest` deploys through the test-only `TestProxy`; this repository contains no production proxy or deployment scripts.

| Verifies | Test |
|---|---|
| The full lifecycle on one fresh proxy: starts uninitialized, rejects a zero owner, initializes exactly once (owner set, `SetOwner` emitted), then never again | `testInitializeLifecycleOnFreshProxy` |
| The shared test proxy, initialized atomically through constructor data, cannot be re-initialized to seize ownership | `testCannotReinitializeProxy` |
| The bare implementation deploys locked (`isInitialized`, no owner) and cannot be initialized directly | `testImplementationIsPetrified` |
| The proxy and the implementation each derive the exact separator from their own address and the live `block.chainid`, and after a simulated chain split the proxy's separator tracks the new id | `testDomainSeparatorBindsToAddressAndChainId` |
| The nine inherited slots remain at 0–8 and the fork fields at 9–11; the storage-library accessors round-trip each field | `MorphoStorageLibTest::testStorageForkSlots` |
