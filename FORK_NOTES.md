# Morpho Blue Fork Notes

This repository is a fork of [Morpho Blue](https://github.com/morpho-org/morpho-blue) by Morpho Labs.
The core market contract `src/Morpho.sol` is renamed to `src/LidoBlue.sol` (contract `Morpho` → `LidoBlue`) and extended for the Lido Lending product.
Everything else is inherited Morpho Blue source unless listed below.
The consumer repository (the Lido Lending product) imports this fork as a subrepository.

## Fork point

- Upstream repository: `morpho-org/morpho-blue`
- Branch: `main`
- Commit: `1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a`
- Upstream core file: `src/Morpho.sol`, forked as `src/LidoBlue.sol`
- Verified: the fork point commit is an ancestor of `morpho-org/morpho-blue` `main`.

## Reproducing the diff

The divergence is anchored to the fork point, so the exact change set is reproducible from git rather than from this prose.
The prose only records the rationale.
Optionally add the upstream remote first:

```sh
git remote add upstream https://github.com/morpho-org/morpho-blue.git
git fetch upstream
```

Full source diff against the fork point:

```sh
git diff -M 1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a HEAD -- src/
```

Forked core only, rename-aware (`Morpho.sol` → `LidoBlue.sol`):

```sh
git diff --find-renames=20% 1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a HEAD -- src/Morpho.sol src/LidoBlue.sol
```

The low rename threshold keeps the core shown as a single rename as the fork diverges.
Git's default (`-M50%`) falls back to delete-plus-add once similarity drops below half.
Both paths are named explicitly, so the low threshold cannot mis-pair unrelated files.

Files added by the fork:

```sh
git diff --diff-filter=A --name-only 1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a HEAD
```

This lists every added file, including test scaffolding and mocks, not only the core-support files called out under "Intentional core changes".

## License

- At the fork point, upstream `src/Morpho.sol` is marked `GPL-2.0-or-later`.
- This forked core and every fork-added file are marked `GPL-2.0-or-later`.
- The upstream `LICENSE` file and the SPDX headers of inherited files are preserved.

## Intentional core changes (`src/LidoBlue.sol`)

### Upgradeability

The core is meant to run behind an upgradeable proxy.
The proxy (an `OssifiableProxy`) lives in the consumer repository, not here.

- `DOMAIN_SEPARATOR` is reshaped from an `immutable` to a `view` function that recomputes from `address(this)`, so under delegatecall it resolves to the proxy address.
  The upstream `immutable` would bake the implementation address into bytecode and break EIP-712 isolation.
- A `bool _initialized` flag is appended to storage.
  The constructor sets it `true`, petrifying the implementation.
  A proxy starts at `false` and flips it on the first `initialize(address newOwner)` call.
- The fork-added mappings `marketController` and `deleverageEnabled` are appended after the upstream storage and before `_initialized`.
  New fields must be appended to keep upgrades layout-safe.

### Market creation

- Both `createMarket(MarketParams)` and the new overload `createMarket(MarketParams, address controller, bool enableDeleverage)` are `onlyOwner`.
  Upstream `createMarket` is permissionless.
- The overload atomically binds an optional per-market `controller` (checked against its `MARKET_ID`) and a per-market `deleverage` opt-in.
  Both are immutable for the life of the market.

### Controller hooks

- Every state-changing action (`supply`, `withdraw`, `borrow`, `repay`, `supplyCollateral`, `withdrawCollateral`, `liquidate`, `accrueInterest`, `deleverage`) dispatches the matching hook on the market's bound controller via the internal `_hook`.
  The controller may revert to reject the action.
- The hook executes under a transient reentrancy lock (`_hookInProgress`): while the controller call is in flight, the nine hooked actions and `flashLoan` revert with `HOOK_REENTRANCY`.
  The lock is released before the calling function writes its state and runs Morpho callbacks, so upstream callback patterns (e.g. a `supplyCollateral` callback that borrows) are unaffected.
  `setAuthorization` and `setAuthorizationWithSig` are deliberately not locked: the outer call's authorization check runs before the hook, so a mid-hook authorization change cannot affect the in-flight action.
- `flashLoan` is the deliberate exception: it dispatches no hook, since it nets to zero within the call and writes no position or market state.
  It is still locked out while another action's hook executes.
- A market with no controller behaves exactly as upstream.

### Deleverage

- Adds `deleverage(...)` as a core settlement primitive for fallback-exit workflows.
  It cancels a borrower's debt against a lender's supply shares when ordinary withdraw liquidity is insufficient.
  It is enabled per market.

### Supporting fork-added files

- `src/interfaces/ILidoBlue.sol` — typed surface of the fork (extends `IMorphoStaticTyping`).
- `src/interfaces/ILidoBlueMarketController.sol` — controller interface (hook entrypoint and read views).
- `src/libraries/LidoBlueErrorsLib.sol`, `src/libraries/LidoBlueEventsLib.sol` — fork-added errors and events.

## Storage layout

Upstream slots 0–8 keep their positions.
The fork appends its fields after them.
Upstream `DOMAIN_SEPARATOR` was an `immutable` (stored in bytecode, not storage), so the upstream layout is also slots 0–8.

```
slot  0  owner              address
slot  1  feeRecipient       address
slot  2  position           mapping(Id => mapping(address => Position))
slot  3  market             mapping(Id => Market)
slot  4  isIrmEnabled       mapping(address => bool)
slot  5  isLltvEnabled      mapping(uint256 => bool)
slot  6  isAuthorized       mapping(address => mapping(address => bool))
slot  7  nonce              mapping(address => uint256)
slot  8  idToMarketParams   mapping(Id => MarketParams)
slot  9  marketController   mapping(Id => address)                         (fork)
slot 10  deleverageEnabled  mapping(Id => bool)                            (fork)
slot 11  _initialized       bool                                          (fork)
```

A new field must be appended after slot 11 (or packed into slot 11 alongside `_initialized`).
Reordering or inserting fields breaks proxy storage on upgrade.
The reentrancy lock `_hookInProgress` is a `transient` variable: it lives in transient storage and occupies no persistent slot, so it does not appear in (or constrain) the layout above.

## Preserved upstream assumptions

- `MarketParams`, `Position`, and `Market` shapes and market id derivation are unchanged.
- `onBehalf` and authorization semantics are unchanged.
- `enableIrm` / `enableLltv` (monotonic, enable-only allowlists) are unchanged.
- `LidoBlue is IMorphoStaticTyping`, so Morpho-style vaults and tooling can treat the core as a drop-in.

## Removed or changed upstream assumptions

- Market creation is `onlyOwner` rather than permissionless.
- The Solidity version is bumped from upstream's `0.8.19` to `0.8.30` with `evm_version = "cancun"` (pinned in `foundry.toml`): the hook reentrancy lock uses transient storage, which needs Cancun.
  Upstream syncs land under a different compiler than they were audited with, and the core cannot be deployed to a chain without Cancun support.
- Reentering a locked entrypoint (the nine hooked actions and `flashLoan`) while a controller hook executes is rejected (see "Controller hooks"); upstream has no such lock (and no hooks).
- The core is no longer immutable.
  It runs behind an upgradeable proxy, so the upstream "enable-only, never disable" and fixed-rules guarantees hold only as strongly as the proxy's upgrade governance, until the proxy is ossified.

## Inherited tests, specs, and verification

- Upstream Foundry tests under `test/`, Certora material under `certora/`, and audits under `audits/` are retained as inherited baseline.
- Deploying the petrified core in tests goes through a minimal `test/helpers/TestProxy.sol`.
  The upstream constructor-based deployment is replaced accordingly.
- Fork-specific tests live in `test/integration/{Controller,Deleverage,Hooks,Initialize,Reentrancy}IntegrationTest.sol` on top of `test/BaseTestWithController.sol`.
- `test/invariant/DeleverageInvariantTest.sol` fuzzes `deleverage` against a solvency-enforcing controller (`src/mocks/EnforcingControllerMock.sol`): exact per-cut accounting deltas, collateral-value conservation, share conservation, and the bad-debt backstop.
- Upstream Certora specs are inherited as files but have not been re-verified against the modified core and may currently fail.
  Lido-specific specs for the controller-hook and `deleverage` paths are not yet added (TODO).
  The harnesses are updated to the renamed core (so the specs compile), but the Certora CI workflow is set to manual-only (`workflow_dispatch`) until the fork specs pass; restore its `push`/`pull_request` triggers then.
  The Certora confs (and the workflow's solc install) still pin `solc-0.8.19`; bump them to `0.8.30`/Cancun when re-enabling.

## Syncing with upstream

The fork is intentionally narrow, so upstream updates re-apply with minimal conflict.
All core changes live in `src/LidoBlue.sol`, and everything else fork-added is a new file (see "Reproducing the diff").

To pull an upstream update:

- Fetch the upstream commit or tag and review its diff to `src/Morpho.sol`.
- Re-apply those changes by hand to `src/LidoBlue.sol`.
  The rename (`Morpho.sol` → `LidoBlue.sol`) prevents a clean automatic merge of the core file.
- Re-check the storage layout against "Storage layout".
  Upstream slots 0–8 must keep their positions and the fork fields must stay appended.
  An upstream storage change needs a layout review before adoption.
- Re-run `forge test` and re-verify the inherited Certora specs against the merged core.
- Update the fork point commit and this document.

## Not core forks

Controllers, registries, oracle adapters, the ERC-4626 wrapper, proxy contracts, and deployment scripts live in the consumer repository, not here.
Within this repository, the test-only mocks (`src/mocks/ControllerMock.sol`, `src/mocks/ReentrantControllerMock.sol`, `src/mocks/EnforcingControllerMock.sol`, `test/helpers/TestProxy.sol`) are fork-added test scaffolding, not part of the core.
