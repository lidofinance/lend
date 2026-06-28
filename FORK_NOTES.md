# Morpho Blue Fork Notes

This repository is a fork of [Morpho Blue](https://github.com/morpho-org/morpho-blue) by Morpho Labs, extended for the Lido Lending product and imported by the product repository as a subrepository.
The core `src/Morpho.sol` is renamed to `src/LidoLend.sol`; everything else keeps upstream names and is edited in place where the fork requires it.

## Fork point

- Upstream: `morpho-org/morpho-blue`, branch `main`, commit `1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a` (verified ancestor of upstream `main`).
- The core file is forked as `src/LidoLend.sol`; every other path matches upstream.

## Layout rule

Inherited files are edited in place under their upstream names; the per-path diff to the fork point is the change record.
New files exist only for entities with no upstream counterpart: `ILidoLend.sol`, `ILidoLendMarketController.sol`, the controller mocks, `TestProxy.sol`.
The core is the single rename (`Morpho.sol` → `LidoLend.sol`): its name is deploy-facing (verification, ABI artifacts, audits) and the upstream name is the upstream brand; nothing else meets both conditions, so nothing else is renamed.
The modification record (GPL-2.0 §2(a)) is the git history anchored to the fork point plus this document; `SECURITY.md` routes vulnerability reports to Lido.

## Reproducing the diff

```sh
git diff -M 1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a HEAD -- src/
git diff --find-renames=20% 1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a HEAD -- src/Morpho.sol src/LidoLend.sol
```

## Core changes (`src/LidoLend.sol`)

- Proxy setup: the core runs behind an `OssifiableProxy` (the proxy lives in the product repo).
  The owner is set by a one-shot `initialize(newOwner)` instead of the constructor, and the implementation petrifies itself in its constructor.
  `DOMAIN_SEPARATOR` is computed on every call from the current chain id and address, so EIP-712 signatures bind to the proxy.
- Market creation: only the owner can create markets; upstream it is permissionless.
  `createMarket(params)` creates a regular Morpho market; `createMarket(params, controller, enableSettlement)` creates one with a controller and, optionally, `settle` enabled — neither choice can be changed later.
  `enableIrm` / `enableLltv` are removed: `createMarket` enables the market's IRM and LLTV itself, emitting `EnableIrm` / `EnableLltv` on first use.
- New per-market settings are stored in their own mappings; `MarketParams` is never extended, because its shape defines the market id that integrators compute off-chain.
- Controller hooks: every state-changing action (`supply`, `withdraw`, `borrow`, `repay`, `supplyCollateral`, `withdrawCollateral`, `liquidate`, `accrueInterest`, `settle`) dispatches the market controller's `on(...)` hook, which may revert to reject the action.
  While a controller hook is executing, the hooked actions revert with `HOOK_REENTRANCY`; the check lives in the hook dispatch, so a market without a controller is never affected.
  The lock ends before state writes and Morpho callbacks, so upstream callback patterns keep working; `flashLoan` and `setAuthorization` / `setAuthorizationWithSig` are not locked, since they cannot interfere with the action in flight.
- `settle(...)`: lets a lender exit by canceling a borrower's debt against the lender's supply shares when ordinary withdraw liquidity is exhausted.
  The cut is anchored on either `supplyShares` (a set amount of the lender's supply) or `borrowShares` (an exact count of the borrower's debt, which can close a position to zero).
  Enabled per market at creation.

## Interfaces and libraries

- `src/interfaces/IMorpho.sol` is edited in place: `enableIrm` / `enableLltv` are removed, and every inherited member whose fork behavior differs carries a `Warning` annotation.
  There are no other signature changes; a member without a fork `Warning` behaves exactly as upstream.
- `src/interfaces/ILidoLend.sol` mirrors Morpho's three-interface split. `ILidoLendBase` holds the fork-added members (`initialize`, `isInitialized`, the `createMarket` overload, `settle`, `marketController`, `isSettlementEnabled`). `ILidoLendStaticTyping` combines it with Morpho's tuple getters and is what the `LidoLend` contract inherits. `ILidoLend` combines it with the struct-returning `IMorpho`, so `ILidoLend(address(core))` works directly with the Morpho periphery libraries (`MorphoLib`, `MorphoBalancesLib`).
- Fork errors and events are appended in place to `ErrorsLib.sol` / `EventsLib.sol` (`/* FORK-ADDED */` sections); `MorphoStorageLib.sol` exposes the fork-added storage slots.
- ABI- and topic-bearing names are never renamed: the `onMorpho*` callbacks, `IMorphoCallbacks.sol`, and the upstream event names.

## Storage layout

Upstream slots 0–8 keep their positions; the fork appends after them.

```
slot  0  owner                address
slot  1  feeRecipient         address
slot  2  position             mapping(Id => mapping(address => Position))
slot  3  market               mapping(Id => Market)
slot  4  isIrmEnabled         mapping(address => bool)
slot  5  isLltvEnabled        mapping(uint256 => bool)
slot  6  isAuthorized         mapping(address => mapping(address => bool))
slot  7  nonce                mapping(address => uint256)
slot  8  idToMarketParams     mapping(Id => MarketParams)
slot  9  marketController     mapping(Id => address)                    (fork)
slot 10  isSettlementEnabled  mapping(Id => bool)                       (fork)
slot 11  isInitialized        bool                                      (fork)
```

A new field must be appended after slot 11 (or packed alongside `isInitialized`); reordering or inserting fields breaks proxy storage on upgrade.
The hook lock `_hookInProgress` is transient and occupies no persistent slot.

## Compatibility

- Drop-in for the user-facing surface: `MarketParams` / `Position` / `Market` shapes, market id derivation, `onBehalf` and authorization semantics, selectors, events, and views are upstream-exact, and a market with no controller behaves exactly as upstream.
- Not drop-in on the admin surface: market creation is `onlyOwner`, `enableIrm` / `enableLltv` are gone ("enabled" now means "used by some created market"; the allowlists remain enable-only).
- Vault caveat: on a market with a controller, hooks may veto `supply`/`withdraw`; product controllers must not break the vault flows they intend to serve.
- The core is upgradeable: upstream's immutability-derived guarantees hold only as strongly as the proxy's upgrade governance, until the proxy is ossified.
- Solidity is bumped to `0.8.35` with `evm_version = "cancun"` (pinned in `foundry.toml`): the hook lock needs transient storage.

## Tests and verification

- Upstream Foundry tests are retained; the petrified core deploys in tests via `test/helpers/TestProxy.sol`.
- Fork tests: `test/integration/{Controller,Hooks,Initialize,Settle,Reentrancy}IntegrationTest.sol` and `test/invariant/SettleInvariantTest.sol` (fuzzes `settle` against a solvency-enforcing controller mock).
- Certora: the inherited layer does not currently compile (`certora/helpers/MorphoHarness.sol` still imports the pre-fork `src/Morpho.sol`); the dead `enableIrm`/`enableLltv` rules are removed from `Reverts.spec`; fork specs are TODO; the CI workflow stays manual-only until they pass, and the confs still pin `solc-0.8.19`.

## Syncing with upstream

Upstream is treated as effectively frozen; no routine sync is planned.
If a critical fix lands upstream, port it by hand via the per-path diff to the fork point, re-run `forge test`, re-check "Storage layout", and update this document.

## License

Inherited and fork-added files are `GPL-2.0-or-later`; the upstream `LICENSE` file and SPDX headers are preserved.

## Not core forks

Controllers, registries, oracle adapters, the ERC-4626 wrapper, proxy contracts, and deployment scripts live in the product repository.
The mocks and `TestProxy.sol` are test scaffolding, not core.
