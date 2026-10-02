// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeedTestBase} from "./helpers/FeedTestBase.sol";
import {LumineonPriceFeed} from "../src/LumineonPriceFeed.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

/// @dev All signatures use a local test key. The handler models accepted observations from the
///      inputs it submits, never by copying the observation returned by the feed. Approvals are
///      modelled per request ID: the owner binds one (requestId, questionHash) pair, a bound request
///      may be rejected any number of times and then accepted once, and a binding is never replaced.
contract LumineonFeedHandler is FeedTestBase {
    LumineonPriceFeed.Observation private expected;
    address[4] private actors;
    OracleAttestation.Attestation private lastAttestation;
    bytes private lastSignature;
    bytes32[] private acceptedRequests;

    // Ghost approvals: every ID the owner bound, its hash, and whether the feed has consumed it.
    bytes32[] private approvedIds;
    mapping(bytes32 requestId => bytes32 questionHash) private approvedHashOf;
    mapping(bytes32 requestId => bool consumed) private consumedGhost;
    bytes32[] private pending; // approved, not yet consumed
    bytes32[] private neverApproved; // IDs that were submitted without a binding and must stay unbound

    address public expectedOwner;
    address public expectedPendingOwner;
    uint256 public acceptedCount;
    uint256 public rejectedCount;
    uint256 public approvalCount;
    uint256 private nonce = 1_000; // setUp approved salt 1; handler salts never collide with it

    constructor(LumineonPriceFeed feed_, address owner_) {
        feed = feed_;
        expectedOwner = owner_;
        actors =
            [owner_, makeAddr("sequence-relayer-1"), makeAddr("sequence-relayer-2"), makeAddr("sequence-relayer-3")];
        // Mirror the binding FeedTestBase.setUp made, so the ghost model starts in sync with the feed.
        bytes32 initial = baseAttestation(11_577, T0, 1).requestId;
        _recordApproval(initial, APPROVED_QUESTION);
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

    function approvedCount() external view returns (uint256) {
        return approvedIds.length;
    }

    function approvedAt(uint256 index) external view returns (bytes32 requestId, bytes32 questionHash, bool consumed) {
        requestId = approvedIds[index];
        return (requestId, approvedHashOf[requestId], consumedGhost[requestId]);
    }

    function neverApprovedCount() external view returns (uint256) {
        return neverApproved.length;
    }

    function neverApprovedAt(uint256 index) external view returns (bytes32) {
        return neverApproved[index];
    }

    function questionAt(uint256 index) public pure returns (bytes32) {
        return index == 0 ? APPROVED_QUESTION : keccak256(abi.encode("sequence-approved-question", index));
    }

    // ------------------------------------------------------------------ actions

    function submitValid(uint256 priceSeed, uint256 choices, bool samePrice) external {
        // Advance monotonically, and exercise both late relay and long gaps between observations.
        vm.warp(vm.getBlockTimestamp() + bound(choices, 1, 2 days));
        uint256 now_ = vm.getBlockTimestamp();
        uint64 issued = uint64(now_ - bound(choices >> 32, 0, 1 days));
        if (issued <= expected.issuedAt) issued = expected.issuedAt + 1;
        uint256 price = samePrice && acceptedCount != 0 ? expected.priceCents : bound(priceSeed, 1, type(uint256).max);
        OracleAttestation.Attestation memory a = baseAttestation(price, issued, ++nonce);
        // Use a pending binding when one exists (including ones left by rejected relays), else bind a new ID.
        if (pending.length != 0) {
            a.requestId = pending[(choices >> 160) % pending.length];
            a.questionHash = approvedHashOf[a.requestId];
        } else {
            a.questionHash = questionAt((choices >> 160) % 8);
            _ownerApproves(a.requestId, a.questionHash);
        }
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
        _markConsumed(a.requestId);
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
        // Every invalid candidate has a new request ID; rejection must not consume it, and when the
        // ID was bound first the binding must survive for a later correct relay.
        // A new timestamp prevents the ordering guard from masking a bad signer or bad data.
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 now_ = vm.getBlockTimestamp();
        OracleAttestation.Attestation memory a =
            baseAttestation(bound(priceSeed, 1, type(uint256).max), uint64(now_), ++nonce);
        uint256 kind = choices % 10;
        if (kind == 9) {
            // Never bound: the approved hash alone admits nothing.
            neverApproved.push(a.requestId);
        } else {
            _ownerApproves(a.requestId, APPROVED_QUESTION);
        }
        if (kind == 0) a.questionHash = keccak256("never-approved-question"); // bound ID, other hash
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
        if (kind != 9) {
            assertEq(feed.approvedRequests(a.requestId), APPROVED_QUESTION, "rejection altered the binding");
        }
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
        _ownerApproves(a.requestId, APPROVED_QUESTION);
        // Use a still-live expiry to isolate ordering whenever the stored issue time is young.
        a.expiresAt = uint64(block.timestamp + 1 days);
        _reject(a, sign(a), actors[actorSeed % actors.length]);
        assertFalse(feed.usedRequests(a.requestId), "out-of-order request consumed");
    }

    function advanceTime(uint256 elapsed) external {
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, 3 days));
    }

    /// @dev Any actor tries to bind a request. A fresh ID succeeds only for the current owner; an ID
    ///      that is already bound (consumed or not) is refused for everyone, including the owner.
    function approveRequest(uint256 questionSeed, uint256 actorSeed, bool reuseExisting) external {
        address caller = actors[actorSeed % actors.length];
        bytes32 requestId;
        bool alreadyBound;
        if (reuseExisting) {
            requestId = approvedIds[(questionSeed >> 64) % approvedIds.length];
            alreadyBound = true;
        } else {
            requestId = baseAttestation(1, T0, ++nonce).requestId;
        }
        bytes32 questionHash = questionAt(questionSeed % 8);
        vm.prank(caller);
        (bool ok,) = address(feed).call(abi.encodeCall(feed.approveRequest, (requestId, questionHash)));
        bool authorized = caller == expectedOwner && !alreadyBound;
        assertEq(ok, authorized, "request approval authority or duplicate check");
        if (authorized) _recordApproval(requestId, questionHash);
        if (alreadyBound) {
            assertEq(feed.approvedRequests(requestId), approvedHashOf[requestId], "rebinding changed a binding");
        }
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

    // ------------------------------------------------------------------ internals

    function _ownerApproves(bytes32 requestId, bytes32 questionHash) private {
        vm.prank(expectedOwner);
        feed.approveRequest(requestId, questionHash);
        _recordApproval(requestId, questionHash);
    }

    function _recordApproval(bytes32 requestId, bytes32 questionHash) private {
        approvedIds.push(requestId);
        approvedHashOf[requestId] = questionHash;
        pending.push(requestId);
        ++approvalCount;
    }

    function _markConsumed(bytes32 requestId) private {
        consumedGhost[requestId] = true;
        for (uint256 i; i < pending.length; ++i) {
            if (pending[i] == requestId) {
                pending[i] = pending[pending.length - 1];
                pending.pop();
                return;
            }
        }
        revert("accepted request was not pending");
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
        selectors[5] = handler.approveRequest.selector;
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

    function invariant_bindingsArePermanentOwnerOnlyAndEachConsumedAtMostOnce() public view {
        assertEq(feed.owner(), handler.expectedOwner());
        assertEq(feed.pendingOwner(), handler.expectedPendingOwner());
        assertEq(feed.attester(), attester, "administration changed the attester");

        // Every binding the owner made is still exactly what it was, and it is consumed iff accepted.
        uint256 consumed;
        for (uint256 i; i < handler.approvedCount(); ++i) {
            (bytes32 requestId, bytes32 questionHash, bool wasConsumed) = handler.approvedAt(i);
            assertEq(feed.approvedRequests(requestId), questionHash, "binding changed or vanished");
            assertEq(feed.usedRequests(requestId), wasConsumed, "consumption disagrees with accepted set");
            if (wasConsumed) ++consumed;
        }
        assertEq(consumed, handler.acceptedCount(), "a consumed request was never accepted");
        assertEq(handler.requestCount(), handler.acceptedCount());
        for (uint256 i; i < handler.requestCount(); ++i) {
            assertTrue(feed.usedRequests(handler.requestAt(i)), "consumed request became reusable");
        }
        // IDs that were only ever relayed without a binding stay unbound and unconsumed.
        for (uint256 i; i < handler.neverApprovedCount(); ++i) {
            bytes32 requestId = handler.neverApprovedAt(i);
            assertEq(feed.approvedRequests(requestId), bytes32(0), "relaying created a binding");
            assertFalse(feed.usedRequests(requestId), "an unbound request was consumed");
        }
    }

    function test_handlerExercisesRefreshExpiryReplayBindingsAndOwnership() public {
        handler.submitValid(12345, 0, false); // consumes the setUp binding
        handler.replay(1);
        handler.submitOutOfOrder(2);
        for (uint256 kind; kind < 10; ++kind) {
            handler.submitInvalid(kind, 67890);
        }
        handler.advanceTime(2 days);
        invariant_observationMatchesAcceptedInputsAndReadsDoNotRenewIt();
        handler.startOwnershipTransfer(0, 1);
        handler.acceptOwnership(2); // wrong account must not take the pending role
        handler.acceptOwnership(1);
        handler.approveRequest(1, 0, false); // the former owner must have lost its power
        handler.approveRequest(1, 1, false);
        handler.approveRequest(1, 1, true); // rebinding an existing ID is refused even for the owner
        handler.submitValid(98765, uint256(1) << 160, true); // reuses a pending binding left by a rejection
        assertEq(handler.acceptedCount(), 2);
        assertEq(handler.rejectedCount(), 12);
        // setUp binding + submitOutOfOrder + nine bound invalid candidates + one owner approval.
        assertEq(handler.approvalCount(), 12);
        assertEq(handler.neverApprovedCount(), 1);
        assertEq(handler.expectedObservation().priceCents, 12345, "same-price refresh was skipped");
        invariant_observationMatchesAcceptedInputsAndReadsDoNotRenewIt();
        invariant_bindingsArePermanentOwnerOnlyAndEachConsumedAtMostOnce();
    }
}
