// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OracleAttestation} from "../../src/OracleAttestation.sol";

/// @dev Exposes the library over calldata so tests can hash and recover without a feed.
contract AttestationHarness {
    function domainSeparator(uint256 chainId, address verifyingContract) external pure returns (bytes32) {
        return OracleAttestation.domainSeparator(chainId, verifyingContract);
    }

    function hashStruct(OracleAttestation.Attestation calldata a) external pure returns (bytes32) {
        return OracleAttestation.hashStruct(a);
    }

    function digest(bytes32 separator, OracleAttestation.Attestation calldata a) external pure returns (bytes32) {
        return OracleAttestation.digest(separator, a);
    }

    function recover(bytes32 messageDigest, bytes calldata signature) external pure returns (address) {
        return OracleAttestation.recover(messageDigest, signature);
    }
}
