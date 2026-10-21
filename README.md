# LidoLend

`LidoLend` is the shared lending core used by the Lido Lend product. It is a fork of [Morpho Blue](https://github.com/morpho-org/morpho-blue). One contract stores many isolated markets. Each market has its own loan and collateral tokens, positions, oracle, interest-rate model (IRM), and liquidation loan-to-value (LLTV), while all markets use the same accounting logic.

Lenders supply a market's loan token. Borrowers provide collateral and borrow that loan token. Liquidators reduce unhealthy debt. The inherited Morpho rules define this accounting.

This fork adds four protocol boundaries:

| Change | Purpose |
| --- | --- |
| Owner-gated market creation | The owner creates each market and binds its controller and settlement setting at creation. |
| Controller hooks | A market-specific controller may accept or reject each hooked market action. |
| `settle` | Burns a supply owner's shares to cancel exact borrower debt shares and sends the calculated collateral to a chosen receiver. |
| Proxy initialization | The core can run behind a proxy while keeping EIP-712 signatures bound to the proxy address and chain. |

## Start here

Read [SPECIFICATION.md](SPECIFICATION.md) first. It explains the system model, runtime behavior, settlement math, storage layout, and trust assumptions. Use [API_REFERENCE.md](API_REFERENCE.md) for the generated contract and controller API.

Maintainer and audit references:

- [FORK_NOTES.md](FORK_NOTES.md) records the source delta from Morpho Blue.
- [TEST_PLAN.md](TEST_PLAN.md) maps requirements to Foundry tests.
- [certora/README.md](certora/README.md) describes the formal-verification model and its assumptions.
- [SECURITY.md](SECURITY.md) gives the private vulnerability-reporting route.

The source is authoritative. [`morpho-blue-whitepaper.pdf`](morpho-blue-whitepaper.pdf) explains the inherited design, and [SPECIFICATION.md](SPECIFICATION.md) documents this fork.

## Repository boundary

[`src/LidoLend.sol`](src/LidoLend.sol) is the core contract. It is the fork of upstream `src/Morpho.sol`. Fork-specific interfaces are [`ILidoLend.sol`](src/interfaces/ILidoLend.sol) and [`ILidoLendMarketController.sol`](src/interfaces/ILidoLendMarketController.sol).

Deployment code, production proxy contracts, production controllers, vaults, oracles, and operational role assignments are outside this repository and are not specified here.

## Development

The repository uses [Foundry](https://book.getfoundry.sh/getting-started/installation).

From a checkout with its submodules initialized:

```sh
forge build
forge test
```

Run `make doc` after changing NatSpec. It builds the Solidity abstract syntax tree and regenerates [API_REFERENCE.md](API_REFERENCE.md).

## Audits

The [`audits/`](audits/) directory contains reports inherited from upstream. Each report covers only the commit and scope named in that report. Their presence does not imply coverage of later upstream changes or the Lido fork changes.

## License

The core contracts use `GPL-2.0-or-later`. Individual SPDX headers govern each file; one retained test helper uses `GPL-3.0-or-later`. See [LICENSE](LICENSE) for the repository license terms and the historical BUSL notice.
