// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";

import {TestProxy} from "../helpers/TestProxy.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {EventsLib} from "../../src/libraries/EventsLib.sol";

contract InitializeIntegrationTest is BaseTest {
    // The full lifecycle on one fresh, uninitialized proxy: starts uninitialized, rejects a zero owner,
    // initializes exactly once (setting the owner and emitting SetOwner), then never again.
    function testInitializeLifecycleOnFreshProxy() public {
        LidoLend fresh = LidoLend(address(new TestProxy(address(new LidoLend()), hex"")));
        assertFalse(fresh.isInitialized(), "fresh proxy starts uninitialized");

        vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
        fresh.initialize(address(0));

        vm.expectEmit(true, true, true, true, address(fresh));
        emit EventsLib.SetOwner(OWNER);
        fresh.initialize(OWNER);

        assertTrue(fresh.isInitialized(), "initialized");
        assertEq(fresh.owner(), OWNER, "owner set");

        vm.expectRevert(bytes(ErrorsLib.ALREADY_INITIALIZED));
        fresh.initialize(OWNER);
    }

    // The shared proxy was initialized atomically through the TestProxy constructor's initData — the
    // production deployment path — and cannot be re-initialized to seize ownership.
    function testCannotReinitializeProxy() public {
        vm.expectRevert(bytes(ErrorsLib.ALREADY_INITIALIZED));
        LidoLend(address(morpho)).initialize(OWNER);
    }

    function testImplementationIsPetrified() public {
        LidoLend impl = new LidoLend();
        assertTrue(impl.isInitialized(), "constructor locks the implementation");
        assertEq(impl.owner(), address(0), "implementation has no owner");
        vm.expectRevert(bytes(ErrorsLib.ALREADY_INITIALIZED));
        impl.initialize(OWNER);
    }

    // The EIP-712 domain binds to the live `address(this)` and `block.chainid`: the proxy and the
    // implementation each derive their own separator, and a chain split moves the proxy's separator to
    // the new chain id.
    function testDomainSeparatorBindsToAddressAndChainId() public {
        LidoLend impl = new LidoLend();
        assertEq(
            morpho.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(morpho))),
            "proxy separator binds to the proxy address"
        );
        assertEq(
            impl.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(impl))),
            "implementation separator binds to its own address"
        );

        uint256 forkedChainId = block.chainid + 1;
        vm.chainId(forkedChainId);
        assertEq(
            morpho.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(DOMAIN_TYPEHASH, forkedChainId, address(morpho))),
            "separator tracks the live chain id"
        );
    }
}
