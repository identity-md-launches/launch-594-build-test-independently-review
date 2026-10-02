// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LumineonPriceFeed} from "../src/LumineonPriceFeed.sol";

/// @notice Deployment parameters for Sepolia. The production path is IMD's ProjectFactory driven by
///         launch.json; this script exists so the same constructor arguments can be simulated locally
///         and so a reviewer can see every value in one place. It reads no keys.
library DeployConfig {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
    uint256 internal constant LOCAL_CHAIN_ID = 31_337;

    /// @dev IMD attestation signer, as reported by `GET https://api.imd.fun/oracle/requests` (field
    ///      `attester`) and as recovered from live attestation signatures on 2026-10-02.
    address internal constant IMD_ATTESTER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
}

contract Deploy is Script {
    error UnexpectedChain(uint256 actual, uint256 expected);
    error UnsupportedChain(uint256 chainId);
    error OwnerRequired();

    /// @notice Simulation entry point. Optional environment:
    ///         EXPECTED_CHAIN_ID  0 (default) skips the chain check; otherwise must equal block.chainid
    ///                            and be 31337 or 11155111.
    ///         FEED_OWNER         question approver; required when EXPECTED_CHAIN_ID is non-zero.
    ///                            With EXPECTED_CHAIN_ID=0 a placeholder (address(1)) is used so the
    ///                            script can be dry-run offline with no configuration at all.
    function run() external returns (LaunchToken token, LumineonPriceFeed feed) {
        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        address owner = vm.envOr("FEED_OWNER", address(0));
        if (expected != 0) {
            if (expected != block.chainid) revert UnexpectedChain(block.chainid, expected);
            if (expected != DeployConfig.SEPOLIA_CHAIN_ID && expected != DeployConfig.LOCAL_CHAIN_ID) {
                revert UnsupportedChain(expected);
            }
            if (owner == address(0)) revert OwnerRequired();
        } else if (owner == address(0)) {
            owner = address(1);
        }
        vm.startBroadcast();
        (token, feed) = deploy(owner, DeployConfig.IMD_ATTESTER);
        vm.stopBroadcast();
    }

    /// @notice The deployment itself, callable from tests with explicit arguments.
    function deploy(address owner, address attester) public returns (LaunchToken token, LumineonPriceFeed feed) {
        token = new LaunchToken();
        feed = new LumineonPriceFeed(owner, attester);
    }
}
