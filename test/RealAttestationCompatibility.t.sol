// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {LumineonPriceFeed} from "../src/LumineonPriceFeed.sol";
import {AttestationHarness} from "./helpers/AttestationHarness.sol";

/// @notice Proves the from-spec library is byte-compatible with IMD's real signer.
/// @dev Fixture: `GET https://api.imd.fun/oracle/requests/ac82ce11-8ed0-48ef-bbba-49eea11c23b1/attestation`,
///      fetched 2026-10-02. It is a real version-2 attestation of this very card question, signed by
///      IMD's attester under the service's DEFAULT domain (chainId 1, verifyingContract 0x0) because
///      that request named no consumer. It therefore proves encoding compatibility, and also that a
///      Sepolia feed correctly refuses it (wrong domain) until a request is made with
///      `consumer = {chainId: 11155111, verifyingContract: <feed>}`.
contract RealAttestationCompatibilityTest is Test {
    address internal constant IMD_ATTESTER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    bytes32 internal constant REAL_QUESTION_HASH = 0x0716e25b7e0736da38b3671c138b25da76141b849730204431cb796203226e4b;

    AttestationHarness internal harness;

    function setUp() public {
        harness = new AttestationHarness();
    }

    function realAttestation() internal pure returns (OracleAttestation.Attestation memory a) {
        a.requestId = 0xac82ce118ed048efbbba49eea11c23b100000000000000000000000000000000;
        a.chainId = 1;
        a.questionHash = REAL_QUESTION_HASH;
        a.answerType = 3;
        a.answer = hex"0000000000000000000000000000000000000000000000000000000000002d39";
        a.figure = 11_577;
        a.fromBlock = 26_097_748;
        a.toBlock = 26_104_920;
        a.blockHash = 0x4ef47415f617a1ef7dcb2ef8db8d8aeaaabb2058eb537fd128bad04fc2206e1c;
        a.panelJobId = 0xedd0a4f1fe3e4fe9b5a259e1fdb09e7700000000000000000000000000000000;
        a.panelSize = 20;
        a.quorum = 14;
        a.agreed = 14;
        a.issuedAt = 1_790_947_696;
        a.expiresAt = 1_791_034_096;
    }

    function realSignature() internal pure returns (bytes memory) {
        return hex"40c87b410c28ba3cef15a9561903c6f6a5325dad7ae72bf56d9899221b64998d6f4899aa4ddbdca2df5a98f0b5b3144651b51cc57d323ab27dc407b8f377203c1c";
    }

    function test_recoversImdAttesterFromRealSignature() public view {
        bytes32 separator = harness.domainSeparator(1, address(0));
        bytes32 d = harness.digest(separator, realAttestation());
        address signer = harness.recover(d, realSignature());
        assertEq(signer, IMD_ATTESTER, "library encoding does not match IMD's signer");
    }

    function test_realAnswerDecodesToFigure() public pure {
        OracleAttestation.Attestation memory a = realAttestation();
        assertEq(abi.decode(a.answer, (uint256)), a.figure);
        assertEq(a.figure, 11_577); // USD 115.77 at the time of the request
    }

    function test_anyFieldChangeBreaksRecovery() public view {
        bytes32 separator = harness.domainSeparator(1, address(0));
        OracleAttestation.Attestation memory a = realAttestation();
        a.figure = 11_578;
        assertTrue(harness.recover(harness.digest(separator, a), realSignature()) != IMD_ATTESTER);
        a = realAttestation();
        a.agreed = 15;
        assertTrue(harness.recover(harness.digest(separator, a), realSignature()) != IMD_ATTESTER);
        a = realAttestation();
        a.answer = abi.encode(uint256(11_578));
        assertTrue(harness.recover(harness.digest(separator, a), realSignature()) != IMD_ATTESTER);
    }

    function test_sepoliaFeedRefusesDefaultDomainAttestation() public {
        vm.chainId(11_155_111);
        vm.warp(1_790_947_696 + 3600);
        address owner = makeAddr("owner");
        LumineonPriceFeed feed = new LumineonPriceFeed(owner, IMD_ATTESTER);
        vm.prank(owner);
        feed.approveQuestion(REAL_QUESTION_HASH);
        // Everything but the domain is valid; the signature was made for (1, 0x0), not (11155111, feed).
        vm.expectRevert(LumineonPriceFeed.InvalidSignature.selector);
        feed.submitAttestation(realAttestation(), realSignature());
        assertFalse(feed.hasObservation());
    }

    function test_feedDomainSeparatorMatchesLibrary() public {
        vm.chainId(11_155_111);
        LumineonPriceFeed feed = new LumineonPriceFeed(makeAddr("owner"), IMD_ATTESTER);
        assertEq(feed.DOMAIN_SEPARATOR(), harness.domainSeparator(11_155_111, address(feed)));
        assertEq(
            OracleAttestation.ATTESTATION_TYPEHASH,
            keccak256(
                "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
            )
        );
    }

    function test_recoverRejectsMalformedSignatures() public view {
        bytes32 separator = harness.domainSeparator(1, address(0));
        bytes32 d = harness.digest(separator, realAttestation());
        bytes memory sig = realSignature();
        // wrong length
        assertEq(harness.recover(d, hex"1234"), address(0));
        // v outside 27/28
        bytes memory badV = bytes.concat(sig);
        badV[64] = 0x00;
        assertEq(harness.recover(d, badV), address(0));
        // high-s malleated twin of the same signature
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory malleated = abi.encodePacked(r, bytes32(n - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        assertEq(harness.recover(d, malleated), address(0));
    }
}
