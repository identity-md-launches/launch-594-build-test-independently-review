// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeedTestBase} from "./helpers/FeedTestBase.sol";
import {LumineonPriceFeed} from "../src/LumineonPriceFeed.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

/// @dev All signatures use a local test key. The handler models accepted observations from the
///      inputs it submits, never by copying the observation returned by the feed.
contract LumineonFeedHandler is FeedTestBase {
    LumineonPriceFeed.Observation private expected;
    address[4] private actors;
    OracleAttestation.Attestation private lastAttestation;
    bytes private lastSignature;
    bytes32[] private acceptedRequests;

    address public expectedOwner;
    address public expectedPendingOwner;
    bool[8] public expectedApprovals;
    uint256 public acceptedCount;
    uint256 public rejectedCount;
    uint256 private nonce;

    constructor(LumineonPriceFeed feed_, address owner_) {
        feed = feed_;
        expectedOwner = owner_;
        actors =
            [owner_, makeAddr("sequence-relayer-1"), makeAddr("sequence-relayer-2"), makeAddr("sequence-relayer-3")];
        expectedApprovals[0] = true;
    }

    function expectedObservation() external view returns (LumineonPriceFeed.Observation memory) {
        return expected;
    }

    function requestCount() external view returns (uint256) {
        return acceptedRequests.length;
    }

    function requestAt(uint256 index) external view returns (bytes32) {
        return acceptedRequests[index];
    }

    function questionAt(uint256 index) public pure returns (bytes32) {
        return index == 0 ? APPROVED_QUESTION : keccak256(abi.encode("sequence-approved-question", index));
    }

    function submitValid(uint256 priceSeed, uint256 choices, bool samePrice) external {
        // Advance monotonically, and exercise both late relay and long gaps between observations.
        vm.warp(vm.getBlockTimestamp() + bound(choices, 1, 2 days));
        uint256 now_ = vm.getBlockTimestamp();
        uint64 issued = uint64(now_ - bound(choices >> 32, 0, 1 days));
        if (issued <= expected.issuedAt) issued = expected.issuedAt + 1;
        uint256 price = samePrice && acceptedCount != 0 ? expected.priceCents : bound(priceSeed, 1, type(uint256).max);
        OracleAttestation.Attestation memory a = baseAttestation(price, issued, ++nonce);
        uint256 questionIndex = (choices >> 160) % 8;
        a.questionHash = questionAt(expectedApprovals[questionIndex] ? questionIndex : 0);
        a.expiresAt = issued + uint64(bound(choices >> 64, now_ - issued, 3 days));
        a.panelSize = uint16(bound(choices >> 96, 20, type(uint16).max));
        a.quorum = uint16(bound(choices >> 112, 14, a.panelSize));
        a.agreed = uint16(bound(choices >> 128, a.quorum, a.panelSize));
        bytes memory sig = sign(a);
        vm.prank(actors[(choices >> 192) % actors.length]);
        feed.submitAttestation(a, sig);

        // These are postconditions, so unexpected handler reverts must fail the invariant run.
        assertGt(a.issuedAt, expected.issuedAt, "accepted issuance did not increase");
        assertFalse(_alreadyAccepted(a.requestId), "request accepted twice");
        acceptedRequests.push(a.requestId);
        ++acceptedCount;
        expected = LumineonPriceFeed.Observation({
            priceCents: price,
            requestId: a.requestId,
            questionHash: a.questionHash,
            panelJobId: a.panelJobId,
            issuedAt: a.issuedAt,
            expiresAt: a.expiresAt,
            receivedAt: uint64(now_),
            panelSize: a.panelSize,
            quorum: a.quorum,
            agreed: a.agreed
        });
        lastAttestation = a;
        lastSignature = sig;
    }

    function submitInvalid(uint256 choices, uint256 priceSeed) external {
        // Every invalid candidate has a new request ID; rejection must not consume it.
        // A new timestamp prevents the ordering guard from masking a bad signer or bad data.
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 now_ = vm.getBlockTimestamp();
        OracleAttestation.Attestation memory a =
            baseAttestation(bound(priceSeed, 1, type(uint256).max), uint64(now_), ++nonce);
        uint256 kind = choices % 9;
        if (kind == 0) a.questionHash = keccak256("never-approved-question");
        if (kind == 1) a.chainId = 11_155_111;
        if (kind == 2) a.agreed = 13;
        if (kind == 3) a.answer = hex"01";
        if (kind == 4) a.figure = a.figure == type(uint256).max ? 1 : a.figure + 1;
        if (kind == 5) {
            a.issuedAt = uint64(now_ - 2);
            a.expiresAt = uint64(now_ - 1);
        }
        if (kind == 6) {
            a.issuedAt = uint64(now_ + 1);
            a.expiresAt = a.issuedAt + 1 days;
        }
        if (kind == 7) {
            a.issuedAt = uint64(now_ - 1 days - 1);
            a.expiresAt = uint64(now_ + 1 days);
        }
        bytes memory sig = kind == 8 ? signFor(ROGUE_PK, block.chainid, address(feed), a) : sign(a);
        _reject(a, sig, actors[(choices >> 8) % actors.length]);
        assertFalse(feed.usedRequests(a.requestId), "rejection consumed a fresh request ID");
    }

    function replay(uint256 actorSeed) external {
        if (acceptedCount == 0) return;
        _reject(lastAttestation, lastSignature, actors[actorSeed % actors.length]);
        assertTrue(feed.usedRequests(expected.requestId), "replay cleared the consumed request");
    }

    function submitOutOfOrder(uint256 actorSeed) external {
        if (acceptedCount == 0) return;
        uint64 issued = expected.issuedAt - uint64(bound(actorSeed >> 8, 0, 1 days));
        OracleAttestation.Attestation memory a = baseAttestation(1, issued, ++nonce);
        // Use a still-live expiry to isolate ordering whenever the stored issue time is young.
        a.expiresAt = uint64(block.timestamp + 1 days);
        _reject(a, sign(a), actors[actorSeed % actors.length]);
        assertFalse(feed.usedRequests(a.requestId), "out-of-order request consumed");
    }

    function advanceTime(uint256 elapsed) external {
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, 3 days));
    }

    function approveQuestion(uint256 questionSeed, uint256 actorSeed) external {
        uint256 index = questionSeed % expectedApprovals.length;
        address caller = actors[actorSeed % actors.length];
        vm.prank(caller);
        (bool ok,) = address(feed).call(abi.encodeCall(feed.approveQuestion, (questionAt(index))));
        bool authorized = caller == expectedOwner && !expectedApprovals[index];
        assertEq(ok, authorized, "question approval authority or duplicate check");
        if (authorized) expectedApprovals[index] = true;
    }

    function startOwnershipTransfer(uint256 actorSeed, uint256 successorSeed) external {
        address caller = actors[actorSeed % actors.length];
        // Include zero alongside the four accounts, without discarding fuzz inputs.
        address successor = successorSeed % 5 == 4 ? address(0) : actors[successorSeed % 5];
        vm.prank(caller);
        (bool ok,) = address(feed).call(abi.encodeCall(feed.transferOwnership, (successor)));
        bool authorized = caller == expectedOwner && successor != address(0);
        assertEq(ok, authorized, "ownership proposal authority or zero-address check");
        if (authorized) expectedPendingOwner = successor;
    }

    function acceptOwnership(uint256 actorSeed) external {
        address caller = actors[actorSeed % actors.length];
        vm.prank(caller);
        (bool ok,) = address(feed).call(abi.encodeCall(feed.acceptOwnership, ()));
        bool authorized = caller == expectedPendingOwner;
        assertEq(ok, authorized, "only the current proposed owner may accept");
        if (authorized) {
            expectedOwner = caller;
            expectedPendingOwner = address(0);
        }
    }

    function _reject(OracleAttestation.Attestation memory a, bytes memory sig, address caller) private {
        (LumineonPriceFeed.Observation memory before_,) = feed.latestObservation();
        bool hadObservation = feed.hasObservation();
        vm.prank(caller);
        (bool ok,) = address(feed).call(abi.encodeCall(feed.submitAttestation, (a, sig)));
        assertFalse(ok, "invalid or previously accepted observation was accepted");
        (LumineonPriceFeed.Observation memory after_,) = feed.latestObservation();
        assertEq(abi.encode(after_), abi.encode(before_), "rejected relay changed stored observation");
        assertEq(feed.hasObservation(), hadObservation, "rejected relay changed existence flag");
        ++rejectedCount;
    }

    function _alreadyAccepted(bytes32 request) private view returns (bool) {
        for (uint256 i; i < acceptedRequests.length; ++i) {
            if (acceptedRequests[i] == request) return true;
        }
        return false;
    }
}

/// @dev Covers temporal and authorization state transitions even though this feed holds no funds.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LumineonPriceFeedInvariantTest is FeedTestBase {
    LumineonFeedHandler private handler;

    function setUp() public override {
        super.setUp();
        handler = new LumineonFeedHandler(feed, owner);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.submitValid.selector;
        selectors[1] = handler.submitInvalid.selector;
        selectors[2] = handler.replay.selector;
        selectors[3] = handler.submitOutOfOrder.selector;
        selectors[4] = handler.advanceTime.selector;
        selectors[5] = handler.approveQuestion.selector;
        selectors[6] = handler.startOwnershipTransfer.selector;
        selectors[7] = handler.acceptOwnership.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_observationMatchesAcceptedInputsAndReadsDoNotRenewIt() public view {
        LumineonPriceFeed.Observation memory expected = handler.expectedObservation();
        (LumineonPriceFeed.Observation memory actual, bool fresh) = feed.latestObservation();
        bool exists = handler.acceptedCount() != 0;
        assertEq(abi.encode(actual), abi.encode(expected), "history differs from the last accepted input");
        assertEq(feed.hasObservation(), exists);
        uint256 deadline = uint256(expected.issuedAt) + 24 hours;
        if (expected.expiresAt < deadline) deadline = expected.expiresAt;
        bool shouldBeFresh = exists && block.timestamp <= deadline;
        assertEq(fresh, shouldBeFresh);
        assertEq(feed.isFresh(), shouldBeFresh);
        assertEq(feed.observationAge(), exists ? block.timestamp - expected.issuedAt : type(uint256).max);

        (bool ok, bytes memory result) = address(feed).staticcall(abi.encodeCall(feed.priceCents, ()));
        assertEq(ok, shouldBeFresh, "strict reader disagrees with independent time model");
        if (shouldBeFresh) {
            (uint256 price, uint64 issued) = abi.decode(result, (uint256, uint64));
            assertEq(price, expected.priceCents);
            assertEq(issued, expected.issuedAt);
        } else if (!exists) {
            assertEq(result, abi.encodeWithSelector(LumineonPriceFeed.NoObservation.selector));
        } else {
            assertEq(
                result,
                abi.encodeWithSelector(
                    LumineonPriceFeed.StalePrice.selector, expected.issuedAt, expected.expiresAt, block.timestamp
                )
            );
        }
        (actual,) = feed.latestObservation();
        assertEq(abi.encode(actual), abi.encode(expected), "reading renewed or erased history");
    }

    function invariant_onlyOwnerApprovesAndEveryAcceptedRequestRemainsConsumed() public view {
        assertEq(feed.owner(), handler.expectedOwner());
        assertEq(feed.pendingOwner(), handler.expectedPendingOwner());
        assertEq(feed.attester(), attester, "administration changed the attester");
        for (uint256 i; i < 8; ++i) {
            assertEq(feed.approvedQuestions(handler.questionAt(i)), handler.expectedApprovals(i));
        }
        assertEq(handler.requestCount(), handler.acceptedCount());
        for (uint256 i; i < handler.requestCount(); ++i) {
            assertTrue(feed.usedRequests(handler.requestAt(i)), "consumed request became reusable");
        }
    }

    function test_handlerExercisesRefreshExpiryReplayAndOwnership() public {
        handler.submitValid(12345, 0, false);
        handler.replay(1);
        handler.submitOutOfOrder(2);
        for (uint256 kind; kind < 9; ++kind) {
            handler.submitInvalid(kind, 67890);
        }
        handler.advanceTime(2 days);
        invariant_observationMatchesAcceptedInputsAndReadsDoNotRenewIt();
        handler.startOwnershipTransfer(0, 1);
        handler.acceptOwnership(2); // wrong account must not take the pending role
        handler.acceptOwnership(1);
        handler.approveQuestion(1, 0); // the former owner must have lost its power
        handler.approveQuestion(1, 1);
        handler.submitValid(98765, uint256(1) << 160, true);
        assertEq(handler.acceptedCount(), 2);
        assertEq(handler.rejectedCount(), 11);
        assertEq(handler.expectedObservation().priceCents, 12345, "same-price refresh was skipped");
        invariant_observationMatchesAcceptedInputsAndReadsDoNotRenewIt();
        invariant_onlyOwnerApprovesAndEveryAcceptedRequestRemainsConsumed();
    }
}
