// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";

import {ILidoLend} from "../../src/interfaces/ILidoLend.sol";

contract OnlyOwnerIntegrationTest is BaseTest {
    using MathLib for uint256;
    using MorphoLib for IMorpho;

    function testDeployWithAddressZero() public {
        address morphoImpl = address(new LidoLend());
        vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
        new TestProxy(morphoImpl, abi.encodeCall(LidoLend.initialize, (address(0))));
    }

    function testDeployEmitOwner() public {
        address morphoImpl = address(new LidoLend());
        vm.expectEmit();
        emit EventsLib.SetOwner(OWNER);
        new TestProxy(morphoImpl, abi.encodeCall(LidoLend.initialize, (OWNER)));
    }

    function testSetOwnerWhenNotOwner(address addressFuzz) public {
        vm.assume(addressFuzz != OWNER);

        vm.prank(addressFuzz);
        vm.expectRevert(bytes(ErrorsLib.NOT_OWNER));
        morpho.setOwner(addressFuzz);
    }

    function testSetOwnerAlreadySet() public {
        vm.prank(OWNER);
        vm.expectRevert(bytes(ErrorsLib.ALREADY_SET));
        morpho.setOwner(OWNER);
    }

    function testSetOwner(address newOwner) public {
        vm.assume(newOwner != OWNER);

        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.SetOwner(newOwner);
        morpho.setOwner(newOwner);

        assertEq(morpho.owner(), newOwner, "owner is not set");
    }

    function testCreateMarketWhenNotOwner(address addressFuzz, MarketParams memory marketParamsFuzz) public {
        vm.assume(addressFuzz != OWNER);

        vm.prank(addressFuzz);
        vm.expectRevert(bytes(ErrorsLib.NOT_OWNER));
        morpho.createMarket(marketParamsFuzz);
    }

    function testCreateMarketWithControllerWhenNotOwner(address addressFuzz, MarketParams memory marketParamsFuzz)
        public
    {
        vm.assume(addressFuzz != OWNER);

        vm.prank(addressFuzz);
        vm.expectRevert(bytes(ErrorsLib.NOT_OWNER));
        ILidoLend(address(morpho)).createMarket(marketParamsFuzz, address(0), false);
    }

    function testSetFeeWhenNotOwner(address addressFuzz, uint256 feeFuzz) public {
        vm.assume(addressFuzz != OWNER);

        vm.prank(addressFuzz);
        vm.expectRevert(bytes(ErrorsLib.NOT_OWNER));
        morpho.setFee(marketParams, feeFuzz);
    }

    function testSetFeeWhenMarketNotCreated(MarketParams memory marketParamsFuzz, uint256 feeFuzz) public {
        vm.assume(neq(marketParamsFuzz, marketParams));

        vm.prank(OWNER);
        vm.expectRevert(bytes(ErrorsLib.MARKET_NOT_CREATED));
        morpho.setFee(marketParamsFuzz, feeFuzz);
    }

    function testSetTooHighFee(uint256 feeFuzz) public {
        feeFuzz = bound(feeFuzz, MAX_FEE + 1, type(uint256).max);

        vm.prank(OWNER);
        vm.expectRevert(bytes(ErrorsLib.MAX_FEE_EXCEEDED));
        morpho.setFee(marketParams, feeFuzz);
    }

    function testSetFee(uint256 feeFuzz) public {
        feeFuzz = bound(feeFuzz, 1, MAX_FEE);

        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.SetFee(id, feeFuzz);
        morpho.setFee(marketParams, feeFuzz);

        assertEq(morpho.fee(id), feeFuzz);
    }

    function testSetFeeRecipientWhenNotOwner(address addressFuzz) public {
        vm.assume(addressFuzz != OWNER);

        vm.prank(addressFuzz);
        vm.expectRevert(bytes(ErrorsLib.NOT_OWNER));
        morpho.setFeeRecipient(addressFuzz);
    }

    function testSetFeeRecipient(address newFeeRecipient) public {
        vm.assume(newFeeRecipient != morpho.feeRecipient());

        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.SetFeeRecipient(newFeeRecipient);
        morpho.setFeeRecipient(newFeeRecipient);

        assertEq(morpho.feeRecipient(), newFeeRecipient);
    }
}
