# LidoLend

LidoLend is the lending core of the Lido Lending product: a fork of [Morpho Blue](https://github.com/morpho-org/morpho-blue) by Morpho Labs that keeps Morpho's isolated-market accounting and adds per-market controller hooks, a `settle` primitive, owner-gated market creation, and an upgradeable-proxy initializer.

This repository holds the core contract with its interfaces, libraries, and tests. Contracts are not deployed from here: [`lidofinance/lido-lend-markets`](https://github.com/lidofinance/lido-lend-markets) imports this repository as a subrepository and owns deployment, the proxy, the market controllers, and the rest of the product.

## Documentation

- [`SPECIFICATION.md`](./SPECIFICATION.md) — the normative specification of the fork's behavior, with the generated API reference.
- [`FORK_NOTES.md`](./FORK_NOTES.md) — the fork record: the upstream pin, layout rules, the delta, and how to reproduce the diff.
- [`TEST_PLAN.md`](./TEST_PLAN.md) — the property-to-test map and coverage.
- [`morpho-blue-whitepaper.pdf`](./morpho-blue-whitepaper.pdf) — normative for the inherited Morpho Blue behavior.

## Repository structure

[`LidoLend.sol`](./src/LidoLend.sol) is the core — upstream `src/Morpho.sol`, renamed; every other inherited file keeps its upstream path. The fork's own interfaces are [`ILidoLend.sol`](./src/interfaces/ILidoLend.sol) and [`ILidoLendMarketController.sol`](./src/interfaces/ILidoLendMarketController.sol). [`src/libraries/periphery`](./src/libraries/periphery) holds helper libraries for integrators, and [`src/mocks`](./src/mocks) contracts designed exclusively for testing.

## Developers

Compilation, testing, and formatting with [forge](https://book.getfoundry.sh/getting-started/installation). `make doc` regenerates the API Reference section of `SPECIFICATION.md`.

## Audits

The [audits](./audits/) folder contains the upstream Morpho Blue audits, covering the inherited code at the fork point. The fork's changes are not covered by them.

## Security

Report vulnerabilities in this repository or its deployments per [SECURITY.md](./SECURITY.md) (to Lido, not to upstream Morpho Labs).

## License

Files in this repository are publicly available under license `GPL-2.0-or-later`, see [`LICENSE`](./LICENSE).
The previous license (BUSL-1.1) can be found [here](https://github.com/morpho-org/morpho-blue/blob/1bcfbfdfa284597ae526d082dd34bcd182d15d27/LICENSE) for reference.
