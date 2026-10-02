// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeedTestBase} from "./helpers/FeedTestBase.sol";
import {LumineonPriceFeed} from "../src/LumineonPriceFeed.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

contract LumineonPriceFeedTest is FeedTestBase {
    event PriceUpdated(
        bytes32 indexed requestId,
        bytes32 indexed questionHash,
        uint256 priceCents,
        uint64 issuedAt,
        uint64 expiresAt,
        uint64 receivedAt,
        uint16 panelSize,
        uint16 quorum,
        uint16 agreed,
        address relayer
    );
    event QuestionApproved(bytes32 indexed questionHash, address indexed approver);

    // ------------------------------------------------------------------ empty state

    function test_startsEmpty() public {
        assertFalse(feed.hasObservation());
        assertFalse(feed.isFresh());
        assertEq(feed.observationAge(), type(uint256).max);
        (LumineonPriceFeed.Observation memory o, bool fresh) = feed.latestObservation();
        assertFalse(fresh);
        assertEq(o.priceCents, 0);
        assertEq(o.requestId, bytes32(0));
        vm.expectRevert(LumineonPriceFeed.NoObservation.selector);
        feed.priceCents();
    }

    function test_metadataDescribesTheCard() public view {
        assertEq(feed.CARD_NAME(), "Lumineon V");
        assertEq(feed.SET_NAME(), "Crown Zenith: Galarian Gallery");
        assertEq(feed.CARD_NUMBER(), "GG39/GG70");
        assertEq(feed.LANGUAGE(), "English");
        assertEq(feed.GRADING_COMPANY(), "PSA");
        assertEq(feed.GRADE(), 10);
        assertEq(feed.CURRENCY(), "USD");
        assertEq(feed.PRICE_SOURCE_URL(), "https://www.pricecharting.com/game/pokemon-crown-zenith/lumineon-v-gg39");
        assertEq(feed.QUESTION_CHAIN_ID(), 1);
        assertEq(feed.ANSWER_TYPE(), 3);
        assertGt(bytes(feed.description()).length, 60);
        assertGt(bytes(feed.PRICE_DEFINITION()).length, 20);
    }

    // ------------------------------------------------------------------ happy paths

    function test_twoSuccessiveValidUpdates() public {
        OracleAttestation.Attestation memory a1 = baseAttestation(11_577, T0, 1);
        vm.expectEmit(true, true, false, true);
        emit PriceUpdated(
            a1.requestId, APPROVED_QUESTION, 11_577, T0, T0 + 86_400, uint64(block.timestamp), 20, 14, 14, relayer
        );
        submitSigned(a1);

        (LumineonPriceFeed.Observation memory o, bool fresh) = feed.latestObservation();
        assertTrue(fresh);
        assertTrue(feed.hasObservation());
        assertEq(o.priceCents, 11_577);
        assertEq(o.requestId, a1.requestId);
        assertEq(o.questionHash, APPROVED_QUESTION);
        assertEq(o.panelJobId, a1.panelJobId);
        assertEq(o.issuedAt, T0);
        assertEq(o.expiresAt, T0 + 86_400);
        assertEq(o.receivedAt, uint64(block.timestamp));
        assertEq(o.panelSize, 20);
        assertEq(o.quorum, 14);
        assertEq(o.agreed, 14);
        assertTrue(feed.usedRequests(a1.requestId));
        (uint256 cents, uint64 issuedAt) = feed.priceCents();
        assertEq(cents, 11_577);
        assertEq(issuedAt, T0);

        // Six hours later a newer attestation with a different price and fuller agreement.
        vm.warp(T0 + 6 hours + 17);
        OracleAttestation.Attestation memory a2 = baseAttestation(12_050, T0 + 6 hours, 2);
        a2.agreed = 19;
        submitSigned(a2);
        (o, fresh) = feed.latestObservation();
        assertTrue(fresh);
        assertEq(o.priceCents, 12_050);
        assertEq(o.requestId, a2.requestId);
        assertEq(o.issuedAt, T0 + 6 hours);
        assertEq(o.receivedAt, T0 + 6 hours + 17);
        assertEq(o.agreed, 19);
        assertEq(feed.observationAge(), 17);
    }

    function test_unchangedPriceRefreshesFreshness() public {
        submitSigned(baseAttestation(11_577, T0, 1));
        // Go stale: 24h + 1s after issuance.
        vm.warp(T0 + 24 hours + 1);
        assertFalse(feed.isFresh());
        vm.expectRevert(
            abi.encodeWithSelector(LumineonPriceFeed.StalePrice.selector, T0, T0 + 86_400, uint256(T0 + 24 hours + 1))
        );
        feed.priceCents();

        // Same price, newly signed observation: accepted and fresh again.
        OracleAttestation.Attestation memory a2 = baseAttestation(11_577, T0 + 24 hours, 2);
        submitSigned(a2);
        assertTrue(feed.isFresh());
        (uint256 cents, uint64 issuedAt) = feed.priceCents();
        assertEq(cents, 11_577);
        assertEq(issuedAt, T0 + 24 hours);
        (LumineonPriceFeed.Observation memory o,) = feed.latestObservation();
        assertEq(o.requestId, a2.requestId);
    }

    function test_anyoneMayRelay() public {
        OracleAttestation.Attestation memory a = baseAttestation(9_999, T0, 7);
        bytes memory sig = sign(a);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        feed.submitAttestation(a, sig);
        (LumineonPriceFeed.Observation memory o,) = feed.latestObservation();
        assertEq(o.priceCents, 9_999);
    }

    function test_acceptsAtExactMaxAgeAndAtExpiry() public {
        // Issued exactly MAX_AGE ago, expiresAt == now: still accepted.
        OracleAttestation.Attestation memory a = baseAttestation(5_000, uint64(block.timestamp) - 24 hours, 3);
        a.expiresAt = uint64(block.timestamp);
        submitSigned(a);
        assertTrue(feed.isFresh());
        vm.warp(block.timestamp + 1);
        assertFalse(feed.isFresh(), "one second past expiry is stale");
    }

    function test_freshnessHonoursSignedExpiryBeforeMaxAge() public {
        OracleAttestation.Attestation memory a = baseAttestation(5_000, T0, 4);
        a.expiresAt = T0 + 3600; // IMD validForSeconds 3600
        submitSigned(a);
        vm.warp(T0 + 3601);
        assertFalse(feed.isFresh(), "signed expiry passed");
        (LumineonPriceFeed.Observation memory o, bool fresh) = feed.latestObservation();
        assertFalse(fresh);
        assertEq(o.priceCents, 5_000, "history survives expiry");
    }

    function test_readingNeverRenewsFreshness() public {
        submitSigned(baseAttestation(5_000, T0, 5));
        vm.warp(T0 + 23 hours);
        for (uint256 i; i < 5; ++i) {
            feed.priceCents();
            feed.latestObservation();
            feed.isFresh();
        }
        vm.warp(T0 + 24 hours + 1);
        assertFalse(feed.isFresh());
        (LumineonPriceFeed.Observation memory o,) = feed.latestObservation();
        assertEq(o.issuedAt, T0);
        assertEq(o.receivedAt, T0 + 600);
    }

    // ------------------------------------------------------------------ signer and domain

    function test_rejectsUnauthorizedSigner() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        bytes memory sig = signFor(ROGUE_PK, block.chainid, address(feed), a);
        vm.expectRevert(LumineonPriceFeed.InvalidSignature.selector);
        submit(a, sig);
        assertFalse(feed.hasObservation());
    }

    function test_rejectsGarbageSignature() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        vm.expectRevert(LumineonPriceFeed.InvalidSignature.selector);
        submit(a, hex"deadbeef");
        vm.expectRevert(LumineonPriceFeed.InvalidSignature.selector);
        submit(a, new bytes(65));
    }

    function test_rejectsWrongDomainChain() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        bytes memory sig = signFor(TEST_ATTESTER_PK, 1, address(feed), a); // mainnet domain
        vm.expectRevert(LumineonPriceFeed.InvalidSignature.selector);
        submit(a, sig);
    }

    function test_rejectsWrongVerifyingContract() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        bytes memory sig = signFor(TEST_ATTESTER_PK, block.chainid, address(0), a); // IMD default domain
        vm.expectRevert(LumineonPriceFeed.InvalidSignature.selector);
        submit(a, sig);
        LumineonPriceFeed other = new LumineonPriceFeed(owner, attester);
        sig = signFor(TEST_ATTESTER_PK, block.chainid, address(other), a); // another consumer
        vm.expectRevert(LumineonPriceFeed.InvalidSignature.selector);
        submit(a, sig);
    }

    function test_rejectsWrongQuestionChainField() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        a.chainId = 11_155_111;
        vm.expectRevert(abi.encodeWithSelector(LumineonPriceFeed.WrongQuestionChain.selector, uint256(11_155_111)));
        submit(a, sign(a));
    }

    function test_tamperedFieldAfterSigningIsRejected() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        bytes memory sig = sign(a);
        a.figure = 20_000;
        a.answer = abi.encode(uint256(20_000));
        vm.expectRevert(LumineonPriceFeed.InvalidSignature.selector);
        submit(a, sig);
    }

    // ------------------------------------------------------------------ question binding

    function test_rejectsUnapprovedQuestion() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        a.questionHash = OTHER_QUESTION;
        vm.expectRevert(abi.encodeWithSelector(LumineonPriceFeed.QuestionNotApproved.selector, OTHER_QUESTION));
        submit(a, sign(a));
    }

    function test_ownerApprovesNewQuestionThenRelayWorks() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        a.questionHash = OTHER_QUESTION;
        bytes memory sig = sign(a);
        vm.expectRevert(abi.encodeWithSelector(LumineonPriceFeed.QuestionNotApproved.selector, OTHER_QUESTION));
        submit(a, sig);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit QuestionApproved(OTHER_QUESTION, owner);
        feed.approveQuestion(OTHER_QUESTION);
        assertTrue(feed.approvedQuestions(OTHER_QUESTION));
        submit(a, sig);
        assertTrue(feed.hasObservation());
    }

    function test_onlyOwnerApproves() public {
        vm.prank(relayer);
        vm.expectRevert(LumineonPriceFeed.NotOwner.selector);
        feed.approveQuestion(OTHER_QUESTION);
        vm.prank(attester);
        vm.expectRevert(LumineonPriceFeed.NotOwner.selector);
        feed.approveQuestion(OTHER_QUESTION);
    }

    function test_approveRejectsZeroAndDuplicates() public {
        vm.startPrank(owner);
        vm.expectRevert(LumineonPriceFeed.InvalidConfiguration.selector);
        feed.approveQuestion(bytes32(0));
        vm.expectRevert(LumineonPriceFeed.QuestionAlreadyApproved.selector);
        feed.approveQuestion(APPROVED_QUESTION);
        vm.stopPrank();
    }

    function test_twoStepOwnershipTransfer() public {
        address next = makeAddr("next");
        vm.prank(relayer);
        vm.expectRevert(LumineonPriceFeed.NotOwner.selector);
        feed.transferOwnership(next);

        vm.prank(owner);
        vm.expectRevert(LumineonPriceFeed.ZeroAddress.selector);
        feed.transferOwnership(address(0));

        vm.prank(owner);
        feed.transferOwnership(next);
        assertEq(feed.owner(), owner, "unchanged until accepted");
        assertEq(feed.pendingOwner(), next);

        vm.prank(relayer);
        vm.expectRevert(LumineonPriceFeed.NotPendingOwner.selector);
        feed.acceptOwnership();

        vm.prank(next);
        feed.acceptOwnership();
        assertEq(feed.owner(), next);
        assertEq(feed.pendingOwner(), address(0));

        vm.prank(owner);
        vm.expectRevert(LumineonPriceFeed.NotOwner.selector);
        feed.approveQuestion(OTHER_QUESTION);
        vm.prank(next);
        feed.approveQuestion(OTHER_QUESTION);
    }

    function test_ownerCannotSetPriceOrForgeAttestation() public {
        OracleAttestation.Attestation memory a = baseAttestation(1, T0, 1);
        bytes memory sig = signFor(ROGUE_PK, block.chainid, address(feed), a);
        vm.prank(owner);
        vm.expectRevert(LumineonPriceFeed.InvalidSignature.selector);
        feed.submitAttestation(a, sig);
        // No other state-changing entry point exists for a price.
        (bool ok,) = address(feed).call(abi.encodeWithSignature("setPrice(uint256)", 1));
        assertFalse(ok);
    }

    // ------------------------------------------------------------------ panel evidence

    function test_rejectsSmallPanel() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        a.panelSize = 19;
        a.quorum = 14;
        a.agreed = 14;
        vm.expectRevert(abi.encodeWithSelector(LumineonPriceFeed.InsufficientPanel.selector, uint16(19)));
        submit(a, sign(a));
    }

    function test_rejectsLowQuorum() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        a.quorum = 13;
        a.agreed = 20;
        vm.expectRevert(abi.encodeWithSelector(LumineonPriceFeed.InsufficientQuorum.selector, uint16(13)));
        submit(a, sign(a));
    }

    function test_rejectsAgreedBelowQuorum() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        a.agreed = 13;
        vm.expectRevert(
            abi.encodeWithSelector(LumineonPriceFeed.InsufficientAgreement.selector, uint16(13), uint16(14))
        );
        submit(a, sign(a));
    }

    function test_rejectsInconsistentCounts() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        a.panelSize = 20;
        a.quorum = 21;
        a.agreed = 21;
        vm.expectRevert(
            abi.encodeWithSelector(LumineonPriceFeed.InconsistentCounts.selector, uint16(20), uint16(21), uint16(21))
        );
        submit(a, sign(a));
        a = baseAttestation(11_577, T0, 1);
        a.agreed = 21;
        vm.expectRevert(
            abi.encodeWithSelector(LumineonPriceFeed.InconsistentCounts.selector, uint16(20), uint16(14), uint16(21))
        );
        submit(a, sign(a));
    }

    // ------------------------------------------------------------------ malformed data

    function test_rejectsWrongAnswerType() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        a.answerType = 0; // bool
        vm.expectRevert(abi.encodeWithSelector(LumineonPriceFeed.WrongAnswerType.selector, uint8(0)));
        submit(a, sign(a));
    }

    function test_rejectsMalformedAnswerBytes() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        a.answer = hex"2d39";
        vm.expectRevert(LumineonPriceFeed.MalformedAnswer.selector);
        submit(a, sign(a));
        a.answer = "";
        vm.expectRevert(LumineonPriceFeed.MalformedAnswer.selector);
        submit(a, sign(a));
        a.answer = abi.encode(uint256(11_577), uint256(1));
        vm.expectRevert(LumineonPriceFeed.MalformedAnswer.selector);
        submit(a, sign(a));
    }

    function test_rejectsAnswerFigureConflict() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        a.figure = 11_578;
        vm.expectRevert(
            abi.encodeWithSelector(LumineonPriceFeed.AnswerFigureMismatch.selector, uint256(11_577), uint256(11_578))
        );
        submit(a, sign(a));
    }

    function test_rejectsZeroPrice() public {
        OracleAttestation.Attestation memory a = baseAttestation(0, T0, 1);
        vm.expectRevert(LumineonPriceFeed.ZeroPrice.selector);
        submit(a, sign(a));
    }

    // ------------------------------------------------------------------ time

    function test_rejectsExpired() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        a.expiresAt = uint64(block.timestamp) - 1;
        vm.expectRevert(
            abi.encodeWithSelector(LumineonPriceFeed.AttestationExpired.selector, a.expiresAt, block.timestamp)
        );
        submit(a, sign(a));
    }

    function test_rejectsOlderThanMaxAgeEvenIfUnexpired() public {
        uint64 issued = uint64(block.timestamp) - 24 hours - 1;
        OracleAttestation.Attestation memory a = baseAttestation(11_577, issued, 1);
        a.expiresAt = issued + 30 days; // long IMD validity does not override the feed's 24h rule
        vm.expectRevert(abi.encodeWithSelector(LumineonPriceFeed.AttestationTooOld.selector, issued, block.timestamp));
        submit(a, sign(a));
    }

    function test_rejectsFutureIssued() public {
        uint64 issued = uint64(block.timestamp) + 1;
        OracleAttestation.Attestation memory a = baseAttestation(11_577, issued, 1);
        vm.expectRevert(abi.encodeWithSelector(LumineonPriceFeed.IssuedInFuture.selector, issued, block.timestamp));
        submit(a, sign(a));
    }

    function test_rejectsExpiryBeforeIssue() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        a.expiresAt = T0 - 1;
        vm.expectRevert(abi.encodeWithSelector(LumineonPriceFeed.InvalidValidity.selector, T0, T0 - 1));
        submit(a, sign(a));
    }

    function test_rejectsReplay() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        bytes memory sig = sign(a);
        submit(a, sig);
        vm.warp(block.timestamp + 10);
        vm.expectRevert(abi.encodeWithSelector(LumineonPriceFeed.RequestAlreadyUsed.selector, a.requestId));
        submit(a, sig);
    }

    function test_rejectsReusedRequestIdWithNewerIssueTime() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 1);
        submitSigned(a);
        OracleAttestation.Attestation memory b = baseAttestation(12_000, T0 + 100, 2);
        b.requestId = a.requestId;
        vm.warp(T0 + 200);
        vm.expectRevert(abi.encodeWithSelector(LumineonPriceFeed.RequestAlreadyUsed.selector, a.requestId));
        submit(b, sign(b));
    }

    function test_rejectsOutOfOrderOlderAttestation() public {
        submitSigned(baseAttestation(11_577, T0, 1));
        OracleAttestation.Attestation memory older = baseAttestation(10_000, T0 - 1, 2);
        vm.expectRevert(abi.encodeWithSelector(LumineonPriceFeed.NotNewerThanStored.selector, T0 - 1, T0));
        submit(older, sign(older));
        OracleAttestation.Attestation memory same = baseAttestation(10_000, T0, 3);
        vm.expectRevert(abi.encodeWithSelector(LumineonPriceFeed.NotNewerThanStored.selector, T0, T0));
        submit(same, sign(same));
        (LumineonPriceFeed.Observation memory o,) = feed.latestObservation();
        assertEq(o.priceCents, 11_577);
    }

    function test_staleFeedStillAcceptsNewerAttestation() public {
        submitSigned(baseAttestation(11_577, T0, 1));
        vm.warp(T0 + 10 days);
        assertFalse(feed.isFresh());
        OracleAttestation.Attestation memory a = baseAttestation(8_000, T0 + 10 days - 1 hours, 2);
        submitSigned(a);
        assertTrue(feed.isFresh());
        (uint256 cents,) = feed.priceCents();
        assertEq(cents, 8_000);
    }

    // ------------------------------------------------------------------ interface shape

    function test_submitSelectorMatchesTooling() public pure {
        // tools/prepare-update.mjs computes this selector itself; this pins the signature it must match.
        assertEq(
            bytes4(
                keccak256(
                    "submitAttestation((bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)"
                )
            ),
            LumineonPriceFeed.submitAttestation.selector
        );
        assertEq(LumineonPriceFeed.submitAttestation.selector, bytes4(0x383f5938));
    }

    function test_feedHoldsNoEthAndRejectsIt() public {
        (bool ok,) = address(feed).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(feed).balance, 0);
    }
}
