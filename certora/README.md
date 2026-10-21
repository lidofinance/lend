# LidoLend formal verification

This directory contains Certora Verification Language (CVL) rules for inherited Morpho accounting and the LidoLend fork changes. Read [SPECIFICATION.md](../SPECIFICATION.md) before using them. This is a rule and model inventory, not a proof-status report: a successful run establishes only the property expressed by that rule under its configured summaries and assumptions.

Every helper, configuration, and workflow uses Solidity 0.8.36 with the Cancun EVM target, matching the core.

## Verification model

### Core and markets

`LidoLend` is modeled as one core contract containing many markets. For each token, the `idleAmount` ghost aggregates recorded collateral in markets using it as collateral plus `totalSupplyAssets - totalBorrowAssets` in markets using it as the loan token. The rules require that aggregate not exceed the modeled core balance. A separate per-market invariant requires `totalBorrowAssets <= totalSupplyAssets`. Both depend on the token-transfer model below.

### Token transfers

The transfer summaries assume exact-balance ERC-20 behavior: a successful transfer changes the core balance by exactly the requested amount. Fee-on-transfer, burn-on-transfer, and rebasing tokens are outside the model.

Three dispatch contracts cover common return-value behavior:

- [`ERC20Standard`](dispatch/ERC20Standard.sol) returns a boolean and reverts on insufficient balance or allowance.
- [`ERC20NoRevert`](dispatch/ERC20NoRevert.sol) returns `false` instead of reverting.
- [`ERC20USDT`](dispatch/ERC20USDT.sol) omits the return value.

[`Transfer.spec`](specs/Transfer.spec) summarizes the safe-transfer library and checks its failure handling.

### Accounting value bounds

[`AssetsAccounting.spec`](specs/AssetsAccounting.spec) checks share-conversion bounds on successful inherited entry and exit operations. With no interest elapsed during the checked transition, the rules bound supply gains and withdrawals by the corresponding asset input or pre-call position value. Borrow-by-shares cannot increase upward-rounded debt by less than the assets received, and a closing repayment cannot pay less than the pre-call upward-rounded debt. Collateral additions are exact and withdrawals cannot exceed the recorded balance.

These are per-operation bounds for `supply`, `withdraw`, `borrow`, `repay`, `supplyCollateral`, and `withdrawCollateral`. Settlement has different actors and rounding allocation, so [`Settlement.spec`](specs/Settlement.spec) models it separately.

### Fee, timestamp, and input bounds

The `feeInRange` invariant in [`ConsistentState.spec`](specs/ConsistentState.spec) and [`ExchangeRate.spec`](specs/ExchangeRate.spec) constrains every market fee to `MAX_FEE`, which is 25%. The `noTimeTravel` rule assumes `lastUpdate <= block.timestamp` before an arbitrary non-view call and checks that a successful call preserves that relation.

[`Reverts.spec`](specs/Reverts.spec) checks invalid-input rejection. For example, `supplyInputValidation` requires exactly one of `assets` and `shares` to be non-zero and rejects a zero `onBehalf`; separate `*InputValidation` rules cover the other modeled entry points. `settleInputValidation` checks market creation, settlement enablement, a non-zero borrow-share input, a non-zero receiver, and authorization from `onBehalf`. These implications assert that invalid inputs revert; they do not claim that every other input succeeds.

### Controller calls

General accounting specifications replace `controller.on(...)` with a summary that does not write LidoLend storage. This is a modeling restriction, not a runtime guarantee. A controller can call unhooked entry points or exercise permissions granted to its address.

[`Settlement.spec`](specs/Settlement.spec) models controller acceptance and rejection for settlement. [`Reentrancy.spec`](specs/Reentrancy.spec) checks the hook lock and call ordering. The [Foundry controller-hook tests](../TEST_PLAN.md#1-controller-hooks) cover nested behavior that is not expanded in the generic CVL summaries, including a controller calling `flashLoan` during a hook.

### Authorization

Authorization rules distinguish adverse changes from permissionless beneficial actions. They check that an unauthorized caller cannot reduce another user's supply shares, increase its debt, or withdraw its collateral, while supply, repay, and collateral addition may act for another account. Settlement authorization is taken from the supply owner, not the borrower.

### Health

The health rules use upward-rounded debt and LLTV-adjusted collateral value; equality is healthy. [`StayHealthy.spec`](specs/StayHealthy.spec) checks that ordinary actions preserve a previously healthy position when no interest elapses during the checked call. When liquidation reduces collateral to zero, the core writes off any remaining debt; settlement is modeled separately because it has no liquidation incentive or core health check.

### Settlement roles and rounding

Settlement uses four roles whose addresses may alias unless a rule constrains them:

| Actor | Role |
| --- | --- |
| `msg.sender` | Authorized initiator for `onBehalf`. |
| `onBehalf` | Supply owner whose shares are burned. |
| `borrower` | Debt and collateral owner. |
| `receiver` | Collateral recipient. |

[`Settlement.spec`](specs/Settlement.spec) tracks the upward-rounded supply burn against `onBehalf`, the exact debt-share cut and collateral debit against `borrower`, and the returned downward-rounded collateral amount. Token delivery to `receiver` is covered by the Foundry settlement tests; the CVL transfer is summarized.

### Liveness

Transition rules specify the post-state of successful calls. Separate `canRepayAll`, `canWithdrawAll`, and `canWithdrawCollateralAll` rules check non-reversion only under their explicit controller, transfer, arithmetic, and health assumptions. They do not prove controller-independent exit availability.

## Specification map

| File | Main properties |
| --- | --- |
| [`AccrueInterest.spec`](specs/AccrueInterest.spec) | Interest-accrual equivalence for actions that accrue first. |
| [`AssetsAccounting.spec`](specs/AssetsAccounting.spec) | Entry and exit asset bounds. |
| [`ConsistentState.spec`](specs/ConsistentState.spec) | Market totals, market independence, immutable configuration, and adverse unauthorized changes. |
| [`ExactMath.spec`](specs/ExactMath.spec) | Full-repay exchange-rate reset and no-profit same-block supply/withdraw and borrow/repay round trips. |
| [`ExchangeRate.spec`](specs/ExchangeRate.spec) | Supply and borrow exchange-rate behavior. |
| [`Health.spec`](specs/Health.spec) | Health and the boundary between liquidation and settlement. |
| [`LibSummary.spec`](specs/LibSummary.spec) | Correctness assumptions for library summaries used by other rules. |
| [`LiquidateBuffer.spec`](specs/LiquidateBuffer.spec) | Liquidation buffer properties under the stated price and interest assumptions. |
| [`Liveness.spec`](specs/Liveness.spec) | Expected deltas of successful actions, subject to controller and dependency assumptions. |
| [`Reentrancy.spec`](specs/Reentrancy.spec) | External-call ordering and transient hook-lock lifecycle. |
| [`Reverts.spec`](specs/Reverts.spec) | Input validation and revert conditions. |
| [`Settlement.spec`](specs/Settlement.spec) | Borrow-share-anchored settlement, supply ownership, exact deltas, controller veto, and rollback. |
| [`StayHealthy.spec`](specs/StayHealthy.spec) | With no interest elapsed during the checked call, ordinary actions preserve a previously healthy position; separate rules cover liquidation cases. |
| [`Transfer.spec`](specs/Transfer.spec) | Safe-transfer summaries and supported ERC-20 return patterns. |

Each [`certora/confs`](confs) file selects a harness, one or more CVL specifications, and compiler settings. `Transfer.conf` also links the modeled contracts in [`certora/dispatch`](dispatch). [`certora/helpers`](helpers) exposes internal state needed by the rules.

## Important limitations

- A successful Certora run is evidence for one source commit, configuration, and rule set. Keep the report URL or CI run with the reviewed commit.
- Summaries replace some external calls. A result does not cover behavior excluded by those summaries.
- Token assumptions exclude transfer fees, burns, and rebasing.
- Generic controller summaries do not explore calls from the controller into unhooked core functions, including `flashLoan` and authorization functions.
- `Reentrancy.spec` treats selected-IRM `borrowRate` calls as trusted and does not prove safety against a reentrant or malicious IRM. The Foundry reentrancy suite covers controller hooks, not IRM callbacks.
- The harness verifies the implementation directly and initializes its owner in the harness constructor. Proxy delegatecall storage, `initialize`, the EIP-712 domain behavior, and the upgrade lifecycle are outside the Certora model.
- Liveness is conditional on controller acceptance and the modeled dependencies.
- Settlement actor addresses are unconstrained unless a rule adds equality or inequality assumptions. Several rules require `msg.sender == onBehalf`; `onBehalf`, `borrower`, and `receiver` may otherwise alias.
- `Settlement.spec` does not prove a one-unit bound on the total settlement gap. In the core math, only the up-versus-down borrow-share valuation has that bound; oracle conversion adds a separate remainder of less than one raw collateral-token unit.

## Running the rules

Install `certora-cli` with pip. CI uses the version pinned in [`certora.yml`](../.github/workflows/certora.yml). Put your Certora key in `CERTORAKEY`. The configurations call the compiler as `solc-0.8.36`, so a binary with that name must be on `PATH`.

Run a configuration from the repository root:

```sh
certoraRun certora/confs/ConsistentState.conf
```

Run one rule with `--rule`:

```sh
certoraRun certora/confs/ConsistentState.conf --rule borrowLessThanSupply
```

Record the source commit, CLI version, compiler version, configuration, and report URL for every result used as evidence.
