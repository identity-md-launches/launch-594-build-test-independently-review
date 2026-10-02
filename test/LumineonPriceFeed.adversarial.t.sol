// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeedTestBase} from "./helpers/FeedTestBase.sol";
import {LumineonPriceFeed} from "../src/LumineonPriceFeed.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

contract LumineonPriceFeedAdversarialTest is FeedTestBase {
    function test_everyRejectionPreservesHistoryAndAllowsCorrectedRequest() public {
        submitSigned(baseAttestation(11_577, T0, 1));
        for (uint256 fault; fault < 20; ++fault) {
            // Each failed relay starts with a populated feed and an owner-approved request, then
            // retries the same request ID correctly. Approval precedes the fault so every rejection
            // below is caused by the fault itself and not by a missing binding.
            OracleAttestation.Attestation memory valid =
                baseAttestation(12_001 + fault, T0 + uint64(fault) + 1, fault + 2);
            approve(valid);
            (OracleAttestation.Attestation memory invalid, bytes memory expected) = _invalidCandidate(fault, valid);
            bytes memory sig = sign(invalid);
            if (fault == 15) sig = hex"deadbeef";
            if (fault == 16) sig = signFor(ROGUE_PK, block.chainid, address(feed), invalid);
            if (fault == 17) sig = signFor(TEST_ATTESTER_PK, 1, address(feed), invalid);
            _rejectWithoutChangingState(invalid, sig, expected);
            assertFalse(feed.usedRequests(valid.requestId), "failed relay consumed the request");

            submitSigned(valid);
            (LumineonPriceFeed.Observation memory stored, bool fresh) = feed.latestObservation();
            assertEq(stored.requestId, valid.requestId);
            assertEq(stored.priceCents, valid.figure);
            assertTrue(fresh);
        }
    }

    function _invalidCandidate(uint256 fault, OracleAttestation.Attestation memory original)
        private
        view
        returns (OracleAttestation.Attestation memory a, bytes memory expected)
    {
        // Deep copy: corrupting a dynamic answer must never mutate the valid retry fixture.
        a = abi.decode(abi.encode(original), (OracleAttestation.Attestation));
        if (fault == 0) {
            // Approved request ID, but a hash other than the one the owner bound to it.
            a.questionHash = OTHER_QUESTION;
            expected =
                abi.encodeWithSelector(LumineonPriceFeed.RequestNotApproved.selector, a.requestId, OTHER_QUESTION);
        } else if (fault == 19) {
            // Approved hash, but a request ID the owner never approved (one bit of the UUID flipped).
            a.requestId ^= bytes32(uint256(1) << 128);
            expected =
                abi.encodeWithSelector(LumineonPriceFeed.RequestNotApproved.selector, a.requestId, a.questionHash);
        } else if (fault == 1) {
            a.chainId = 11_155_111;
            expected = abi.encodeWithSelector(LumineonPriceFeed.WrongQuestionChain.selector, a.chainId);
        } else if (fault == 2) {
            a.answerType = 0;
            expected = abi.encodeWithSelector(LumineonPriceFeed.WrongAnswerType.selector, a.answerType);
        } else if (fault == 3) {
            a.answer = bytes.concat(a.answer, hex"00");
            expected = abi.encodeWithSelector(LumineonPriceFeed.MalformedAnswer.selector);
        } else if (fault == 4) {
            a.figure += 1;
            expected =
                abi.encodeWithSelector(LumineonPriceFeed.AnswerFigureMismatch.selector, original.figure, a.figure);
        } else if (fault == 5) {
            a.answer = abi.encode(uint256(0));
            a.figure = 0;
            expected = abi.encodeWithSelector(LumineonPriceFeed.ZeroPrice.selector);
        } else if (fault == 6) {
            a.panelSize = 19;
            expected = abi.encodeWithSelector(LumineonPriceFeed.InsufficientPanel.selector, a.panelSize);
        } else if (fault == 7) {
            a.quorum = 13;
            expected = abi.encodeWithSelector(LumineonPriceFeed.InsufficientQuorum.selector, a.quorum);
        } else if (fault == 8 || fault == 9) {
            if (fault == 8) a.quorum = 21;
            else a.agreed = 21;
            expected =
                abi.encodeWithSelector(LumineonPriceFeed.InconsistentCounts.selector, a.panelSize, a.quorum, a.agreed);
        } else if (fault == 10) {
            // The signed quorum matters even when 14 panel members agree.
            a.quorum = 15;
            expected = abi.encodeWithSelector(LumineonPriceFeed.InsufficientAgreement.selector, a.agreed, a.quorum);
        } else if (fault == 11) {
            a.expiresAt = a.issuedAt - 1;
            expected = abi.encodeWithSelector(LumineonPriceFeed.InvalidValidity.selector, a.issuedAt, a.expiresAt);
        } else if (fault == 12) {
            a.issuedAt = uint64(block.timestamp + 1);
            expected = abi.encodeWithSelector(LumineonPriceFeed.IssuedInFuture.selector, a.issuedAt, block.timestamp);
        } else if (fault == 13) {
            a.expiresAt = uint64(block.timestamp - 1);
            expected =
                abi.encodeWithSelector(LumineonPriceFeed.AttestationExpired.selector, a.expiresAt, block.timestamp);
        } else if (fault == 14) {
            a.issuedAt = uint64(block.timestamp - 24 hours - 1);
            expected = abi.encodeWithSelector(LumineonPriceFeed.AttestationTooOld.selector, a.issuedAt, block.timestamp);
        } else if (fault == 18) {
            (LumineonPriceFeed.Observation memory old,) = feed.latestObservation();
            a.issuedAt = old.issuedAt;
            expected = abi.encodeWithSelector(LumineonPriceFeed.NotNewerThanStored.selector, a.issuedAt, old.issuedAt);
        } else {
            expected = abi.encodeWithSelector(LumineonPriceFeed.InvalidSignature.selector);
        }
    }

    function test_replayCannotBeLaunderedThroughRebindingOrAnotherHash() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        submitSigned(a);

        // A consumed request keeps its binding: the owner cannot rebind it to another hash, so a
        // re-signed answer for the same ID under a different hash never reaches the replay check.
        vm.prank(owner);
        vm.expectRevert(LumineonPriceFeed.RequestAlreadyApproved.selector);
        feed.approveRequest(a.requestId, OTHER_QUESTION);
        assertEq(feed.approvedRequests(a.requestId), APPROVED_QUESTION);
        OracleAttestation.Attestation memory relabelled = abi.decode(abi.encode(a), (OracleAttestation.Attestation));
        relabelled.questionHash = OTHER_QUESTION;
        relabelled.issuedAt += 1;
        relabelled.figure = 20_000;
        relabelled.answer = abi.encode(relabelled.figure);
        _rejectWithoutChangingState(
            relabelled,
            sign(relabelled),
            abi.encodeWithSelector(LumineonPriceFeed.RequestNotApproved.selector, a.requestId, OTHER_QUESTION)
        );

        // Re-signed under the bound hash with a newer time and a new price: still the same request ID.
        a.issuedAt += 1;
        a.figure = 20_000;
        a.answer = abi.encode(a.figure);
        _rejectWithoutChangingState(
            a, sign(a), abi.encodeWithSelector(LumineonPriceFeed.RequestAlreadyUsed.selector, a.requestId)
        );
    }

    function test_approvalOfAPairCannotAuthenticateAnotherRequestsSignature() public {
        OracleAttestation.Attestation memory first = baseAttestation(11_577, T0, 1);
        OracleAttestation.Attestation memory second = baseAttestation(11_577, T0, 2);
        second.questionHash = OTHER_QUESTION;
        approve(second);
        bytes memory firstSignature = sign(first);
        bytes memory secondSignature = sign(second);

        // Both pairs are approved; a signature made over one request never authenticates the other.
        _rejectWithoutChangingState(
            second, firstSignature, abi.encodeWithSelector(LumineonPriceFeed.InvalidSignature.selector)
        );
        _rejectWithoutChangingState(
            first, secondSignature, abi.encodeWithSelector(LumineonPriceFeed.InvalidSignature.selector)
        );
        assertFalse(feed.usedRequests(first.requestId));
        assertFalse(feed.usedRequests(second.requestId));

        // Each request is then accepted with its own signature, in issuance order, sharing no hash.
        submit(first, firstSignature);
        second.issuedAt += 1;
        submit(second, sign(second));
        (LumineonPriceFeed.Observation memory stored,) = feed.latestObservation();
        assertEq(stored.requestId, second.requestId);
        assertEq(stored.questionHash, OTHER_QUESTION);
    }

    function test_manyRequestsMayShareOneHashButEachNeedsItsOwnApprovalAndIsUsedOnce() public {
        // Repeated requests for the same card carry the same hash; each is approved and consumed on its own.
        for (uint256 i = 1; i <= 4; ++i) {
            OracleAttestation.Attestation memory a = baseAttestation(11_577, T0 + uint64(i), i);
            if (i == 1) {
                // Approved in setUp; its approval does not extend to the later IDs.
                assertEq(feed.approvedRequests(a.requestId), APPROVED_QUESTION);
            } else {
                _rejectWithoutChangingState(
                    a,
                    sign(a),
                    abi.encodeWithSelector(
                        LumineonPriceFeed.RequestNotApproved.selector, a.requestId, APPROVED_QUESTION
                    )
                );
                approve(a);
            }
            submitSigned(a);
            (LumineonPriceFeed.Observation memory stored, bool fresh) = feed.latestObservation();
            assertEq(stored.requestId, a.requestId);
            assertEq(stored.issuedAt, T0 + uint64(i));
            assertTrue(fresh);
        }
        for (uint256 i = 1; i <= 4; ++i) {
            OracleAttestation.Attestation memory again = baseAttestation(11_577, T0 + 10, i);
            _rejectWithoutChangingState(
                again,
                sign(again),
                abi.encodeWithSelector(LumineonPriceFeed.RequestAlreadyUsed.selector, again.requestId)
            );
            assertEq(feed.approvedRequests(again.requestId), APPROVED_QUESTION, "use must not erase the binding");
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_onlyTheExactApprovedPairIsAdmitted(bytes32 requestId, bytes32 questionHash, uint256 flip) public {
        // Pin non-zero values with bound rather than discarding runs; zero is covered by unit tests.
        requestId = bytes32(bound(uint256(requestId), 1, type(uint256).max));
        questionHash = bytes32(bound(uint256(questionHash), 1, type(uint256).max));
        bytes32 difference = bytes32(bound(flip, 1, type(uint256).max));
        // The fuzzer may replay the setUp-approved ID from the dictionary; move off it instead of discarding.
        if (feed.approvedRequests(requestId) != bytes32(0)) requestId = keccak256(abi.encode(requestId));
        vm.prank(owner);
        feed.approveRequest(requestId, questionHash);
        assertEq(feed.approvedRequests(requestId), questionHash);

        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        a.requestId = requestId;
        a.questionHash = questionHash ^ difference;
        _rejectWithoutChangingState(
            a, sign(a), abi.encodeWithSelector(LumineonPriceFeed.RequestNotApproved.selector, requestId, a.questionHash)
        );
        a.requestId = requestId ^ difference;
        a.questionHash = questionHash;
        if (feed.approvedRequests(a.requestId) == bytes32(0)) {
            _rejectWithoutChangingState(
                a,
                sign(a),
                abi.encodeWithSelector(LumineonPriceFeed.RequestNotApproved.selector, a.requestId, questionHash)
            );
        }
        a.requestId = requestId;
        submitSigned(a);
        (LumineonPriceFeed.Observation memory stored,) = feed.latestObservation();
        assertEq(stored.requestId, requestId);
        assertEq(stored.questionHash, questionHash);
    }

    function test_oneCentAndMaximumUintPriceAreStoredWithoutNarrowing() public {
        submitSigned(baseAttestation(1, T0, 1));
        (uint256 cents,) = feed.priceCents();
        assertEq(cents, 1);
        OracleAttestation.Attestation memory maximum = baseAttestation(type(uint256).max, T0 + 1, 2);
        approve(maximum);
        submitSigned(maximum);
        (cents,) = feed.priceCents();
        assertEq(cents, type(uint256).max);
    }

    function test_signedExpiryDoesNotTurnReceiptTimeIntoIssuanceTime() public {
        // Only one second of freshness remains at receipt, despite a far-future signed expiry.
        uint64 issued = uint64(vm.getBlockTimestamp() - 24 hours + 1);
        OracleAttestation.Attestation memory a = baseAttestation(11_577, issued, 1);
        a.expiresAt = type(uint64).max;
        submitSigned(a);
        vm.warp(uint256(issued) + 24 hours);
        assertTrue(feed.isFresh());
        vm.warp(uint256(issued) + 24 hours + 1);
        assertFalse(feed.isFresh());
        (LumineonPriceFeed.Observation memory history, bool fresh) = feed.latestObservation();
        assertFalse(fresh);
        assertEq(history.issuedAt, issued);
        assertEq(history.receivedAt, T0 + 600);
        assertEq(history.expiresAt, type(uint64).max);
        assertEq(feed.observationAge(), 24 hours + 1);
        vm.expectRevert(
            abi.encodeWithSelector(LumineonPriceFeed.StalePrice.selector, issued, a.expiresAt, vm.getBlockTimestamp())
        );
        feed.priceCents();
    }

    function test_allNonUintAnswerTypesAreRejected() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        for (uint256 answerType; answerType <= type(uint8).max; ++answerType) {
            if (answerType == 3) continue;
            a.answerType = uint8(answerType);
            _rejectWithoutChangingState(
                a, sign(a), abi.encodeWithSelector(LumineonPriceFeed.WrongAnswerType.selector, a.answerType)
            );
        }
        a.answerType = 3;
        submitSigned(a);
    }

    function test_truncatedAndPaddedAnswerEncodingsAreRejected() public {
        uint256[7] memory lengths = [uint256(0), 1, 31, 33, 63, 64, 96];
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        for (uint256 i; i < lengths.length; ++i) {
            a.answer = new bytes(lengths[i]);
            _rejectWithoutChangingState(a, sign(a), abi.encodeWithSelector(LumineonPriceFeed.MalformedAnswer.selector));
        }
        a.answer = abi.encode(a.figure);
        submitSigned(a);
    }

    function test_highSMalleableSignatureCannotConsumeRequest() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        bytes memory sig = sign(a);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        uint256 curveOrder = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory twin = abi.encodePacked(r, bytes32(curveOrder - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        _rejectWithoutChangingState(a, twin, abi.encodeWithSelector(LumineonPriceFeed.InvalidSignature.selector));
        assertFalse(feed.usedRequests(a.requestId));
        submit(a, sig);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_anyChangedSignatureByteCannotAuthenticate(uint256 position, uint8 changedBits) public {
        position = bound(position, 0, 64);
        changedBits = uint8(bound(changedBits, 1, 255));
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        bytes memory sig = sign(a);
        sig[position] ^= bytes1(changedBits);
        _rejectWithoutChangingState(a, sig, abi.encodeWithSelector(LumineonPriceFeed.InvalidSignature.selector));
        assertFalse(feed.usedRequests(a.requestId));
    }

    function test_replacedPendingOwnerCannotTakeControl() public {
        address replaced = makeAddr("replaced pending owner");
        address accepted = makeAddr("accepted pending owner");
        vm.startPrank(owner);
        feed.transferOwnership(replaced);
        feed.transferOwnership(accepted);
        vm.stopPrank();
        vm.startPrank(replaced);
        vm.expectRevert(LumineonPriceFeed.NotPendingOwner.selector);
        feed.acceptOwnership();
        vm.expectRevert(LumineonPriceFeed.NotOwner.selector);
        feed.approveRequest(bytes32(uint256(99)), OTHER_QUESTION);
        vm.stopPrank();
        vm.prank(accepted);
        feed.acceptOwnership();
        assertEq(feed.owner(), accepted);
        assertEq(feed.pendingOwner(), address(0));
        bytes32 firstRequest = baseAttestation(11_577, T0, 1).requestId;
        assertEq(feed.approvedRequests(firstRequest), APPROVED_QUESTION, "handover must keep earlier bindings");
        assertEq(feed.approvedRequests(bytes32(uint256(99))), bytes32(0));
        assertEq(feed.attester(), attester);
        submitSigned(baseAttestation(11_577, T0, 1));
        // Only the accepted owner may bind new requests after the handover.
        OracleAttestation.Attestation memory next = baseAttestation(11_577, T0 + 1, 2);
        vm.prank(owner);
        vm.expectRevert(LumineonPriceFeed.NotOwner.selector);
        feed.approveRequest(next.requestId, next.questionHash);
        vm.prank(accepted);
        feed.approveRequest(next.requestId, next.questionHash);
        submitSigned(next);
    }

    function _rejectWithoutChangingState(
        OracleAttestation.Attestation memory a,
        bytes memory sig,
        bytes memory expected
    ) private {
        bytes32 stateBefore = _stateDigest();
        bool wasUsed = feed.usedRequests(a.requestId);
        vm.prank(relayer);
        (bool success, bytes memory result) = address(feed).call(abi.encodeCall(feed.submitAttestation, (a, sig)));
        assertFalse(success, "invalid attestation accepted");
        assertEq(result, expected, "reverted for an unrelated reason");
        assertEq(_stateDigest(), stateBefore, "rejected relay altered feed state");
        assertEq(feed.usedRequests(a.requestId), wasUsed, "rejected relay altered replay state");
    }

    function _stateDigest() private view returns (bytes32) {
        (LumineonPriceFeed.Observation memory o, bool fresh) = feed.latestObservation();
        return keccak256(
            abi.encode(
                o, fresh, feed.hasObservation(), feed.owner(), feed.pendingOwner(), feed.usedRequests(o.requestId)
            )
        );
    }
}
