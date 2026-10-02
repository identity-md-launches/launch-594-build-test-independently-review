// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LumineonPriceFeed} from "../../src/LumineonPriceFeed.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";

/// @dev Shared fixture. The signing key here is a TEST key (vm.addr(TEST_ATTESTER_PK)); the deployed
///      configuration pins IMD's real attester, which no test key can impersonate.
abstract contract FeedTestBase is Test {
    uint256 internal constant TEST_ATTESTER_PK = 0xA11CE000000000000000000000000000000000000000000000000000000000A1;
    uint256 internal constant ROGUE_PK = 0xB0B0000000000000000000000000000000000000000000000000000000000B0B;

    // A plausible 2026 timestamp; tests warp around it. Nothing depends on it being round.
    uint64 internal constant T0 = 1_790_947_696;

    bytes32 internal constant APPROVED_QUESTION = keccak256("imd pinned request: lumineon v psa10 #1");
    bytes32 internal constant OTHER_QUESTION = keccak256("imd pinned request: something else");

    address internal attester;
    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer");
    LumineonPriceFeed internal feed;

    function setUp() public virtual {
        attester = vm.addr(TEST_ATTESTER_PK);
        vm.chainId(11_155_111);
        vm.warp(T0 + 600);
        feed = new LumineonPriceFeed(owner, attester);
        approve(baseAttestation(11_577, T0, 1));
    }

    // ------------------------------------------------------------------ attestation building

    /// @dev Explicit approval step, separate from signing and relaying so negative tests cannot
    ///      accidentally authorize the request they are testing.
    function approve(OracleAttestation.Attestation memory a) internal {
        vm.prank(owner);
        feed.approveRequest(a.requestId, a.questionHash);
    }

    function baseAttestation(uint256 priceCents, uint64 issuedAt, uint256 salt)
        internal
        pure
        returns (OracleAttestation.Attestation memory a)
    {
        a.requestId = bytes32(keccak256(abi.encode("request", salt))) & bytes32(type(uint256).max << 128);
        a.chainId = 1;
        a.questionHash = APPROVED_QUESTION;
        a.answerType = 3;
        a.answer = abi.encode(priceCents);
        a.figure = priceCents;
        a.fromBlock = 26_097_748;
        a.toBlock = 26_104_920;
        a.blockHash = keccak256(abi.encode("block", salt));
        a.panelJobId = bytes32(keccak256(abi.encode("job", salt))) & bytes32(type(uint256).max << 128);
        a.panelSize = 20;
        a.quorum = 14;
        a.agreed = 14;
        a.issuedAt = issuedAt;
        a.expiresAt = issuedAt + 86_400;
    }

    function signFor(
        uint256 pk,
        uint256 domainChainId,
        address verifyingContract,
        OracleAttestation.Attestation memory a
    ) internal pure returns (bytes memory) {
        bytes32 separator = OracleAttestation.domainSeparator(domainChainId, verifyingContract);
        bytes32 structHash = _hashStructMemory(a);
        bytes32 d = keccak256(abi.encodePacked("\x19\x01", separator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    function sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        return signFor(TEST_ATTESTER_PK, block.chainid, address(feed), a);
    }

    function submit(OracleAttestation.Attestation memory a, bytes memory sig) internal {
        vm.prank(relayer);
        feed.submitAttestation(a, sig);
    }

    function submitSigned(OracleAttestation.Attestation memory a) internal {
        submit(a, sign(a));
    }

    /// @dev Memory twin of the library's calldata hashStruct, kept independent on purpose: a mismatch
    ///      between the two would fail every signing test.
    function _hashStructMemory(OracleAttestation.Attestation memory a) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                abi.encode(
                    OracleAttestation.ATTESTATION_TYPEHASH,
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
}
