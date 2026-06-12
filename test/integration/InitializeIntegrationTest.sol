// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";

import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";

contract InitializeIntegrationTest is BaseTest {
    function testCannotReinitializeProxy() public {
        vm.expectRevert(bytes(ErrorsLib.ALREADY_INITIALIZED));
        LidoLend(address(morpho)).initialize(OWNER);
    }

    function testImplementationIsPetrified() public {
        LidoLend impl = new LidoLend();
        vm.expectRevert(bytes(ErrorsLib.ALREADY_INITIALIZED));
        impl.initialize(OWNER);
    }

    function testDomainSeparatorResolvesToProxy() public {
        bytes32 expected = keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(morpho)));
        assertEq(morpho.DOMAIN_SEPARATOR(), expected, "domain separator must use the proxy address");
    }

    function testDomainSeparatorDiffersFromImplementation() public {
        LidoLend impl = new LidoLend();
        assertTrue(
            morpho.DOMAIN_SEPARATOR() != impl.DOMAIN_SEPARATOR(),
            "proxy and implementation must derive different domain separators"
        );
    }
}
