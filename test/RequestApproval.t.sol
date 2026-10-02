// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeedTestBase} from "./helpers/FeedTestBase.sol";
import {LumineonPriceFeed} from "../src/LumineonPriceFeed.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

/// @notice Regression for approval reuse across distinct IMD requests sharing a question hash.
/// @dev IMD v2 does not sign toleranceBps or guards. The owner must check those settings for
///      each request ID; these local signatures model a second request with unchecked settings.
contract RequestApprovalTest is FeedTestBase {
    function test_rejectsUnapprovedRequestWithApprovedHashBeforeFirstObservation() public {
        OracleAttestation.Attestation memory uncheckedRequest = baseAttestation(11_577, T0, 2);
        _assertUnapprovedRequestRejected(uncheckedRequest);
        assertFalse(feed.hasObservation());
    }

    function test_rejectsUnapprovedRequestWithApprovedHashAfterObservation() public {
        OracleAttestation.Attestation memory approved = baseAttestation(11_577, T0, 1);
        submitSigned(approved);
        OracleAttestation.Attestation memory uncheckedRequest = baseAttestation(11_577, T0 + 1, 2);
        _assertUnapprovedRequestRejected(uncheckedRequest);
        (LumineonPriceFeed.Observation memory stored,) = feed.latestObservation();
        assertEq(stored.requestId, approved.requestId);
        assertEq(stored.issuedAt, approved.issuedAt);
    }

    function test_rejectedRequestCanRefreshUnchangedPriceAfterItsOwnApproval() public {
        submitSigned(baseAttestation(11_577, T0, 1));
        OracleAttestation.Attestation memory next = baseAttestation(11_577, T0 + 1, 2);
        _assertUnapprovedRequestRejected(next);
        approve(next);
        submitSigned(next);
        (LumineonPriceFeed.Observation memory stored, bool fresh) = feed.latestObservation();
        assertEq(stored.priceCents, 11_577);
        assertEq(stored.requestId, next.requestId);
        assertEq(stored.issuedAt, T0 + 1);
        assertTrue(fresh);
    }

    function test_zeroHashCannotMatchUnapprovedRequestDefault() public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 2);
        a.questionHash = bytes32(0);
        _assertUnapprovedRequestRejected(a);
        a.requestId = bytes32(0);
        _assertUnapprovedRequestRejected(a);
        a.questionHash = APPROVED_QUESTION;
        _assertUnapprovedRequestRejected(a);
        assertFalse(feed.hasObservation());
    }

    function _assertUnapprovedRequestRejected(OracleAttestation.Attestation memory a) internal {
        bytes memory sig = sign(a);
        vm.prank(relayer);
        (bool accepted,) = address(feed).call(abi.encodeCall(feed.submitAttestation, (a, sig)));
        assertFalse(accepted, "a distinct request needs its own approval even when its question hash matches");
        assertFalse(feed.usedRequests(a.requestId), "rejection must not consume the request");
    }
}
