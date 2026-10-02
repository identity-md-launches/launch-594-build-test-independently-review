// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title OracleAttestation
/// @notice EIP-712 encoding of an IdentityMD oracle attestation, schema version 2.
/// @dev Written against the typed data IMD's attestation route returns
///      (`GET https://api.imd.fun/oracle/requests/:id/attestation`) and the schema published at
///      https://imd.fun/docs/#oracle:
///
///        domain  = EIP712Domain(name "IdentityMD Oracle", version "2", chainId, verifyingContract)
///        message = OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,
///                    uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,
///                    bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,
///                    uint16 agreed,uint64 issuedAt,uint64 expiresAt)
///
///      IMD did not publish a downloadable `OracleAttestation.sol` at the time of writing (the docs
///      name the file, the API serves no route for it, and the launch repositories that consume
///      attestations re-implement the hashing inline). This library is therefore a from-spec
///      implementation. Its byte-compatibility with the real signer is proven by
///      `test/RealAttestationCompatibility.t.sol`, which recovers IMD's attester from a signature
///      the service actually produced.
///
///      Field meanings:
///        - `chainId` is the chain the question was asked ABOUT (the pinned window's chain), not
///          the chain the consumer runs on. The consumer's chain lives in the domain.
///        - `requestId` and `panelJobId` are UUIDs as sixteen raw bytes, left-aligned in bytes32.
///        - `answerType`: bool 0, address 1, bytes32 2, uint256 3, address[] 4, bytes32[] 5.
///        - `answer` is `abi.encode` of the typed value; `figure` is the numeric view of it.
///        - `questionHash` is computed by IMD over the pinned request. Empirically two requests
///          with identical question text but different pinned block windows carry different
///          hashes, so a consumer cannot derive it from the question text alone.
library OracleAttestation {
    struct Attestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    /// @dev answerType value IMD uses for a uint256 answer.
    uint8 internal constant ANSWER_TYPE_UINT256 = 3;

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant DOMAIN_NAME_HASH = keccak256("IdentityMD Oracle");
    bytes32 internal constant DOMAIN_VERSION_HASH = keccak256("2");

    bytes32 internal constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );

    /// @dev secp256k1 n / 2; signatures with a higher `s` are rejected (EIP-2 malleability).
    uint256 private constant _HALF_CURVE_ORDER = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    /// @notice EIP-712 domain separator for a consumer at `verifyingContract` on `chainId`.
    function domainSeparator(uint256 chainId, address verifyingContract) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, DOMAIN_NAME_HASH, DOMAIN_VERSION_HASH, chainId, verifyingContract));
    }

    /// @notice EIP-712 `hashStruct` of an attestation.
    /// @dev Encoded in two halves and concatenated: every field is one static word after hashing
    ///      `answer`, so the bytes are identical to a single `abi.encode` and the function stays off
    ///      stack-too-deep without viaIR.
    function hashStruct(Attestation calldata a) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                abi.encode(
                    ATTESTATION_TYPEHASH,
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
    }

    /// @notice Final EIP-712 digest the attester signs.
    function digest(bytes32 separator, Attestation calldata a) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", separator, hashStruct(a)));
    }

    /// @notice Recover the signer of a 65-byte `r || s || v` signature.
    /// @return signer The recovered address, or address(0) when the signature is malformed,
    ///         malleable (high `s`, `v` not 27/28) or does not recover.
    function recover(bytes32 messageDigest, bytes calldata signature) internal pure returns (address signer) {
        if (signature.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (uint256(s) > _HALF_CURVE_ORDER) return address(0);
        if (v != 27 && v != 28) return address(0);
        signer = ecrecover(messageDigest, v, r, s);
    }
}
