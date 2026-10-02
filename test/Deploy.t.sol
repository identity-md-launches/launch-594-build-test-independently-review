// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy, DeployConfig} from "../script/Deploy.s.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LumineonPriceFeed} from "../src/LumineonPriceFeed.sol";

contract DeployTest is Test {
    function test_deployFunctionProducesConfiguredContracts() public {
        vm.chainId(DeployConfig.SEPOLIA_CHAIN_ID);
        address owner = makeAddr("requester");
        Deploy d = new Deploy();
        (LaunchToken token, LumineonPriceFeed feed) = d.deploy(owner, DeployConfig.IMD_ATTESTER);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(address(d)), 10 ** 27, "token mints to its deployer");
        assertEq(feed.owner(), owner);
        assertEq(feed.attester(), DeployConfig.IMD_ATTESTER);
        assertFalse(feed.hasObservation(), "deploys with no price");
        assertFalse(feed.isFresh());
        assertEq(feed.MIN_PANEL_SIZE(), 20);
        assertEq(feed.MIN_QUORUM(), 14);
        assertEq(feed.MAX_AGE(), 24 hours);
    }

    function test_attesterConstantIsTheLiveImdSigner() public pure {
        // Reported by GET https://api.imd.fun/oracle/requests (field `attester`) on 2026-10-02 and
        // recovered from a real signature in RealAttestationCompatibility.t.sol.
        assertEq(DeployConfig.IMD_ATTESTER, 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982);
    }

    function test_constructorRejectsZeroConfiguration() public {
        vm.expectRevert(LumineonPriceFeed.InvalidConfiguration.selector);
        new LumineonPriceFeed(address(0), DeployConfig.IMD_ATTESTER);
        vm.expectRevert(LumineonPriceFeed.InvalidConfiguration.selector);
        new LumineonPriceFeed(makeAddr("o"), address(0));
    }

    function test_factoryStyleDeploymentDoesNotGrantFactoryAnyRole() public {
        address factory = makeAddr("ProjectFactory");
        address owner = makeAddr("requester");
        vm.prank(factory);
        LumineonPriceFeed feed = new LumineonPriceFeed(owner, DeployConfig.IMD_ATTESTER);
        assertEq(feed.owner(), owner);
        vm.prank(factory);
        vm.expectRevert(LumineonPriceFeed.NotOwner.selector);
        feed.approveQuestion(bytes32(uint256(1)));
    }
}
