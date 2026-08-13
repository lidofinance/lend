# Morpho Blue fork notes

This document records the fork point and the source, ABI, and storage differences from Morpho Blue. Runtime behavior belongs in [SPECIFICATION.md](SPECIFICATION.md); executable coverage belongs in [TEST_PLAN.md](TEST_PLAN.md).

## Fork point

- Upstream repository: [`morpho-org/morpho-blue`](https://github.com/morpho-org/morpho-blue).
- Upstream commit: [`1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a`](https://github.com/morpho-org/morpho-blue/tree/1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a).
- Upstream core: `src/Morpho.sol`.
- Fork core: [`src/LidoLend.sol`](src/LidoLend.sol).

The rename changes the core contract and artifact name. Other inherited files keep their upstream paths and names.

## Reproduce the source delta

Run these commands from the repository root after making the fork-point commit available locally. `HEAD` is the downstream revision under review.

```sh
git diff -M 1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a HEAD -- src/
git diff --find-renames=20% 1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a HEAD -- src/Morpho.sol src/LidoLend.sol
```

## Source footprint

Inherited files are modified in place. Fork-only files are added only when no upstream file provides the required surface.

| Area | Change |
| --- | --- |
| Core | `src/Morpho.sol` becomes `src/LidoLend.sol`; controller hooks, settlement, owner-only creation, and initialization are added. |
| Core interface | [`ILidoLend.sol`](src/interfaces/ILidoLend.sol) adds the fork members while preserving the inherited typed-interface split. |
| Controller interface | [`ILidoLendMarketController.sol`](src/interfaces/ILidoLendMarketController.sol) defines the hook events and payloads. |
| Existing interfaces | `IMorpho.sol` removes `enableIrm` and `enableLltv` and documents changed behavior on inherited members. |
| Libraries | `ErrorsLib` removes the obsolete IRM/LLTV enablement errors and adds fork errors; fork events are appended to `EventsLib`; `MorphoStorageLib` exposes the appended slots. |
| Tests | Applicable upstream tests remain; tests for the removed enable functions and old creation guards are replaced. Fork integration, math, incidence, reentrancy, and invariant coverage is added. |

Retained inherited ABI members keep their names, including the `onMorpho*` callbacks and upstream events. The core contract is renamed, `enableIrm` and `enableLltv` are removed, and fork-specific members are added as listed above.

## Storage layout

The nine upstream slots retain their positions. The fork appends:

| Slot | Field |
| --- | --- |
| 9 | `marketController` |
| 10 | `isSettlementEnabled` |
| 11 | `isInitialized` |

New persistent fields must be appended after slot 11 or packed without changing existing offsets. `_hookInProgress` is transient and uses no persistent slot.

## Compatibility boundary

- `MarketParams`, `Position`, `Market`, market-id derivation, user action signatures, and inherited views keep their upstream ABI and data shapes. Authorization storage, signatures, and checks on inherited actions are unchanged; an authorization also grants the fork-added ability to call `settle` for the authorizer.
- Market creation is not admin-compatible with upstream: it is owner-only, and the separate IRM and LLTV enable functions are removed.
- The core is intended to run behind an external proxy. Immutability guarantees from upstream apply only after that proxy can no longer be upgraded.
- Solidity is pinned to 0.8.36 and the EVM target is Cancun because the hook lock uses transient storage.

## Upstream updates

The fork-point commit remains the comparison base. Port upstream fixes selectively, record each port in git history and this delta when its source, ABI, or storage inventory changes, then run the full test suite and recheck storage and ABI compatibility.
