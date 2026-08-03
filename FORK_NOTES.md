# Morpho Blue Fork Notes

This repository is a fork of [Morpho Blue](https://github.com/morpho-org/morpho-blue) by Morpho Labs, extended for the Lido Lending product and imported by the product repository as a subrepository.
The core `src/Morpho.sol` is renamed to `src/LidoLend.sol`. Everything else keeps upstream names and is edited in place where the fork requires it.

## Fork point

- Upstream: `morpho-org/morpho-blue`, branch `main`, commit `1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a` (verified ancestor of upstream `main`).
- The core file is forked as `src/LidoLend.sol`. Every inherited file keeps its upstream path.

## Layout rule

Inherited files are edited in place under their upstream names. The per-path diff to the fork point is the change record.
New files exist only for entities with no upstream counterpart: `ILidoLend.sol`, `ILidoLendMarketController.sol`, the controller mocks, `TestProxy.sol`, the fork test suites, and the fork documents with their tooling (`SPECIFICATION.md`, `TEST_PLAN.md`, this file, `tools/`).
The core is the single rename (`Morpho.sol` → `LidoLend.sol`): its name is deploy-facing (verification, ABI artifacts, audits) and the upstream name is the upstream brand. Nothing else meets both conditions, so nothing else is renamed.
The modification record (GPL-2.0 §2(a)) is the git history anchored to the fork point plus this document. `SECURITY.md` routes vulnerability reports to Lido.

## Reproducing the diff

```sh
git diff -M 1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a HEAD -- src/
git diff --find-renames=20% 1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a HEAD -- src/Morpho.sol src/LidoLend.sol
```

## Core changes (`src/LidoLend.sol`)

- Proxy setup: the core runs behind an `OssifiableProxy` (the proxy lives in the product repo).
  The owner is set by a one-shot `initialize(newOwner)` instead of the constructor, and the implementation petrifies itself in its constructor.
  `DOMAIN_SEPARATOR` is computed on every call from the current chain id and address, so EIP-712 signatures bind to the proxy.
- Market creation: only the owner can create markets, whereas upstream creation is permissionless.
  `createMarket(params)` creates a regular Morpho market. `createMarket(params, controller, enableSettlement)` creates one with a controller and, optionally, `settle` enabled — neither choice can be changed later.
  `enableIrm` / `enableLltv` are removed: `createMarket` enables the market's IRM and LLTV itself, emitting `EnableIrm` / `EnableLltv` on first use.
- New per-market settings are stored in their own mappings. `MarketParams` is never extended, because its shape defines the market id that integrators compute off-chain.
- Controller hooks: every state-changing action (`supply`, `withdraw`, `borrow`, `repay`, `supplyCollateral`, `withdrawCollateral`, `liquidate`, `accrueInterest`, `settle`) dispatches the market controller's `on(...)` hook, which may revert to reject the action.
  While any controller hook is executing, re-entering any hooked action reverts with `HOOK_REENTRANCY`. The lock is a single global flag checked in the dispatch, so this also blocks actions on a different market or one with no controller. A no-controller market is otherwise unaffected, since it dispatches no hook of its own.
  The lock ends before state writes and Morpho callbacks, so upstream callback patterns keep working. `flashLoan` and `setAuthorization` / `setAuthorizationWithSig` are not locked, since they cannot interfere with the action in flight.
- `settle(...)`: lets a lender exit by canceling a borrower's debt against the lender's supply shares, capped at the part of the lender's supply that ordinary withdraw liquidity cannot serve.
  The cut is anchored on either `supplyShares` (a set amount of the lender's supply) or `borrowShares` (an exact count of the borrower's debt, which can close a position to zero).
  Enabled per market at creation.

## Interfaces and libraries

- `src/interfaces/IMorpho.sol` is edited in place: `enableIrm` / `enableLltv` are removed, and the inherited members whose fork behavior differs are annotated in place (`Warning` tags on the hooked actions and `createMarket`, `@dev` notes on `DOMAIN_SEPARATOR` and the enable views).
  There are no other signature changes; the exhaustive delta is the "Fork Delta" section of `SPECIFICATION.md`.
- `src/interfaces/ILidoLend.sol` mirrors Morpho's three-interface split. `ILidoLendBase` holds the fork-added members (`initialize`, `isInitialized`, the `createMarket` overload, `settle`, `marketController`, `isSettlementEnabled`). `ILidoLendStaticTyping` combines it with Morpho's tuple getters and is what the `LidoLend` contract inherits. `ILidoLend` combines it with the struct-returning `IMorpho`, so `ILidoLend(address(core))` works directly with the Morpho periphery libraries (`MorphoLib`, `MorphoBalancesLib`).
- Fork errors and events are appended in place to `ErrorsLib.sol` / `EventsLib.sol`. `MorphoStorageLib.sol` exposes the fork-added storage slots.
- ABI- and topic-bearing names are never renamed: the `onMorpho*` callbacks, `IMorphoCallbacks.sol`, and the upstream event names.

## Storage layout

Upstream slots 0–8 keep their positions. The fork appends `marketController` (slot 9), `isSettlementEnabled` (slot 10), and `isInitialized` (slot 11). The authoritative slot table lives in `SPECIFICATION.md` "Proxy And Storage", and the literal positions are pinned by `MorphoStorageLibTest::testStorageForkSlots`.

A new field must be appended after slot 11 (or packed alongside `isInitialized`). Reordering or inserting fields breaks proxy storage on upgrade.
The hook lock `_hookInProgress` is transient and occupies no persistent slot.

## Compatibility

- Drop-in for the user-facing surface: `MarketParams` / `Position` / `Market` shapes, market id derivation, `onBehalf` and authorization semantics, selectors, events, and views are upstream-exact. A market with no controller dispatches no hook of its own, but remains subject to the global hook lock (see "Core changes").
- Not drop-in on the admin surface: market creation is `onlyOwner`, `enableIrm` / `enableLltv` are gone ("enabled" now means "used by some created market", the allowlists remain enable-only).
- Vault caveat: on a market with a controller, hooks may veto `supply`/`withdraw`. Product controllers must not break the vault flows they intend to serve.
- The core is upgradeable: upstream's immutability-derived guarantees hold only as strongly as the proxy's upgrade governance, until the proxy is ossified.
- Solidity is bumped to `0.8.36` with `evm_version = "cancun"` (pinned in `foundry.toml`, below solc 0.8.36's `osaka` default). The hook lock needs transient storage (EIP-1153), introduced in Cancun, so Cancun is the lowest EVM the fork can target.

## Tests and verification

- Upstream Foundry tests are retained. The petrified core deploys in tests via `test/helpers/TestProxy.sol`.
- Fork tests: `test/integration/{Controller,Hooks,Initialize,Settle,Reentrancy}IntegrationTest.sol`, `test/integration/SettleMathTest.sol`, and `test/invariant/SettleInvariantTest.sol` (fuzzes `settle` against a solvency-enforcing controller mock). See `TEST_PLAN.md`.
- Deep fuzz runs: five inherited upstream tests (`testBorrowShares`, `testBorrowSharesOnBehalf`, `testWithdrawCollateral`, `testWithdrawCollateralOnBehalf`, `testToUint128Revert`) are `vm.assume`-heavy and hit Foundry's default rejection cap (65536) when `FOUNDRY_FUZZ_RUNS` is raised well past the default 256. This is inherited behavior, kept byte-identical to upstream rather than reworked; for deep campaigns raise the cap alongside the runs, e.g. `FOUNDRY_FUZZ_RUNS=65536 FOUNDRY_FUZZ_MAX_TEST_REJECTS=4194304 forge test` (verified clean at those settings).
- Certora: the inherited layer does not currently compile (`certora/helpers/MorphoHarness.sol` still imports the pre-fork `src/Morpho.sol`). The dead `enableIrm`/`enableLltv` rules are removed from `Reverts.spec`. Fork specs are TODO. The CI workflow stays manual-only until they pass, and the confs still pin `solc-0.8.19`.

## Syncing with upstream

Upstream is treated as effectively frozen. No routine sync is planned.
If a critical fix lands upstream, port it by hand via the per-path diff to the fork point, re-run `forge test`, re-check "Storage layout", and update this document.

## License

Inherited and fork-added files are `GPL-2.0-or-later`. The upstream `LICENSE` file and SPDX headers are preserved.

## Not core forks

Controllers, registries, oracle adapters, the ERC-4626 wrapper, proxy contracts, and deployment scripts live in the product repository.
The mocks and `TestProxy.sol` are test scaffolding, not core.
