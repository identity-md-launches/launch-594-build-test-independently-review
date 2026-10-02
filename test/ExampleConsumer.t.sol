// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeedTestBase} from "./helpers/FeedTestBase.sol";
import {ExampleConsumer} from "./helpers/ExampleConsumer.sol";
import {ILumineonPriceFeed} from "../src/interfaces/ILumineonPriceFeed.sol";
import {LumineonPriceFeed} from "../src/LumineonPriceFeed.sol";

contract ExampleConsumerTest is FeedTestBase {
    ExampleConsumer internal consumer;

    function setUp() public override {
        super.setUp();
        consumer = new ExampleConsumer(ILumineonPriceFeed(address(feed)));
    }

    function test_strictReadRevertsWhenEmpty() public {
        vm.expectRevert(LumineonPriceFeed.NoObservation.selector);
        consumer.requireAffordable(1_000_000);
        vm.expectRevert(LumineonPriceFeed.NoObservation.selector);
        consumer.priceDollars();
        (uint256 cents, bool fresh, uint64 issuedAt) = consumer.lastKnownPrice();
        assertEq(cents, 0);
        assertFalse(fresh);
        assertEq(issuedAt, 0);
    }

    function test_consumerReadsFreshPrice() public {
        submitSigned(baseAttestation(11_577, T0, 21));
        assertEq(consumer.requireAffordable(12_000), 11_577);
        assertEq(consumer.priceDollars(), 115);
        (uint256 cents, bool fresh, uint64 issuedAt) = consumer.lastKnownPrice();
        assertEq(cents, 11_577);
        assertTrue(fresh);
        assertEq(issuedAt, T0);
        vm.expectRevert(abi.encodeWithSelector(ExampleConsumer.PriceAboveBudget.selector, 11_577, 10_000));
        consumer.requireAffordable(10_000);
    }

    function test_strictReadRevertsWhenStaleButLenientStillReports() public {
        submitSigned(baseAttestation(11_577, T0, 22));
        vm.warp(T0 + 25 hours);
        vm.expectRevert(
            abi.encodeWithSelector(LumineonPriceFeed.StalePrice.selector, T0, T0 + 86_400, uint256(T0 + 25 hours))
        );
        consumer.requireAffordable(1_000_000);
        (uint256 cents, bool fresh,) = consumer.lastKnownPrice();
        assertEq(cents, 11_577);
        assertFalse(fresh);
    }
}
