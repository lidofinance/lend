# Morpho Blue

Morpho Blue is a noncustodial lending protocol implemented for the Ethereum Virtual Machine.
Morpho Blue offers a new trustless primitive with increased efficiency and flexibility compared to existing lending platforms.
It provides permissionless risk management and permissionless market creation with oracle agnostic pricing.
It also enables higher collateralization factors, improved interest rates, and lower gas consumption.
The protocol is designed to be a simple, immutable, and governance-minimized base layer that allows for a wide variety of other layers to be built on top.
Morpho Blue also offers a convenient developer experience with a singleton implementation, callbacks, free flash loans, and account management features.

## This fork

This repository (`morpho-lido-blue`) is a fork of [Morpho Blue](https://github.com/morpho-org/morpho-blue) by Morpho Labs, adapted for the Lido Lending product and imported by the product repository as a subrepository.
The core contract `src/Morpho.sol` is renamed to `src/LidoLend.sol` and extended with optional per-market controllers, controller action hooks, a `redeemCollateral` settlement primitive, and an upgradeable-proxy initializer.
Unlike upstream, market creation is owner-gated in this fork (the description above applies to upstream Morpho Blue).

Inherited Morpho Blue source files are used under `GPL-2.0-or-later`.
Lido Lending modifications, the exact upstream fork point, and the preserved/changed assumptions are documented in [`FORK_NOTES.md`](./FORK_NOTES.md).

## Whitepaper

The protocol is described in detail in the [Morpho Blue Whitepaper](./morpho-blue-whitepaper.pdf).

## Repository Structure

[`LidoLend.sol`](./src/LidoLend.sol) contains most of the source code of the forked core contract.
It relies on internal libraries in the [`src/libraries`](./src/libraries) subdirectory; the fork-added errors and events are appended in place to `ErrorsLib` and `EventsLib`.
The fork's typed interfaces are [`ILidoLend.sol`](./src/interfaces/ILidoLend.sol) (fork-added members) and [`ILidoLendMarketController.sol`](./src/interfaces/ILidoLendMarketController.sol); fork-behavior annotations on inherited members live in place in [`IMorpho.sol`](./src/interfaces/IMorpho.sol).

Libraries in the [`src/libraries/periphery`](./src/libraries/periphery) directory are not used by Morpho Blue.
They are useful helpers that integrators can reuse or adapt to their own needs.

The [`src/mocks`](./src/mocks) directory contains contracts designed exclusively for testing.

You'll find relevant comments in [`IMorpho.sol`](./src/interfaces/IMorpho.sol), notably a list of requirements about market dependencies.

## Developers

Compilation, testing and formatting with [forge](https://book.getfoundry.sh/getting-started/installation).

## Audits

All audits are stored in the [audits](./audits/) folder.

## Security

Report vulnerabilities in this repository or its deployments per [SECURITY.md](./SECURITY.md) (to Lido, not to upstream Morpho Labs).

## License

Files in this repository are publicly available under license `GPL-2.0-or-later`, see [`LICENSE`](./LICENSE).
The previous license (BUSL-1.1) can be found [here](https://github.com/morpho-org/morpho-blue/blob/1bcfbfdfa284597ae526d082dd34bcd182d15d27/LICENSE) for reference.
