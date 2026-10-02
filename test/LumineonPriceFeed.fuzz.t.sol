// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeedTestBase} from "./helpers/FeedTestBase.sol";
import {LumineonPriceFeed} from "../src/LumineonPriceFeed.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

contract LumineonPriceFeedFuzzTest is FeedTestBase {
    function testFuzz_anyPositivePriceWithinWindowIsStored(uint256 priceCents, uint32 ageSeconds, uint64 validity)
        public
    {
        priceCents = bound(priceCents, 1, type(uint256).max);
        ageSeconds = uint32(bound(ageSeconds, 0, 24 hours));
        validity = uint64(bound(validity, ageSeconds, 30 days));
        uint64 issued = uint64(block.timestamp) - ageSeconds;
        OracleAttestation.Attestation memory a = baseAttestation(priceCents, issued, 11);
        approve(a);
        a.expiresAt = issued + validity;
        submitSigned(a);
        (uint256 cents, uint64 issuedAt) = feed.priceCents();
        assertEq(cents, priceCents);
        assertEq(issuedAt, issued);
        assertTrue(feed.isFresh());
    }

    function testFuzz_panelCountsBelowFloorsAreRejected(uint16 panelSize, uint16 quorum, uint16 agreed) public {
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 12);
        approve(a);
        a.panelSize = panelSize;
        a.quorum = quorum;
        a.agreed = agreed;
        bool valid = panelSize >= 20 && quorum >= 14 && quorum <= panelSize && agreed <= panelSize && agreed >= quorum;
        if (valid) {
            submitSigned(a);
            (LumineonPriceFeed.Observation memory o,) = feed.latestObservation();
            assertEq(o.panelSize, panelSize);
            assertEq(o.quorum, quorum);
            assertEq(o.agreed, agreed);
        } else {
            bytes memory sig = sign(a);
            vm.prank(relayer);
            (bool ok,) = address(feed).call(abi.encodeCall(feed.submitAttestation, (a, sig)));
            assertFalse(ok, "invalid counts accepted");
            assertFalse(feed.hasObservation());
        }
    }

    function testFuzz_onlyTheConfiguredAttesterIsAccepted(uint256 pk) public {
        pk = bound(pk, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        vm.assume(pk != TEST_ATTESTER_PK);
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 13);
        approve(a);
        bytes memory sig = signFor(pk, block.chainid, address(feed), a);
        vm.expectRevert(LumineonPriceFeed.InvalidSignature.selector);
        submit(a, sig);
    }

    function testFuzz_otherDomainsAreRejected(uint256 chainId, address verifyingContract) public {
        vm.assume(chainId != block.chainid || verifyingContract != address(feed));
        OracleAttestation.Attestation memory a = baseAttestation(11_577, T0, 14);
        approve(a);
        bytes memory sig = signFor(TEST_ATTESTER_PK, chainId, verifyingContract, a);
        vm.expectRevert(LumineonPriceFeed.InvalidSignature.selector);
        submit(a, sig);
    }

    function testFuzz_issueTimeMustStrictlyIncrease(uint32 firstAge, uint32 secondAge) public {
        firstAge = uint32(bound(firstAge, 0, 12 hours));
        secondAge = uint32(bound(secondAge, 0, 12 hours));
        uint64 now_ = uint64(block.timestamp);
        approve(baseAttestation(100, now_ - firstAge, 15));
        submitSigned(baseAttestation(100, now_ - firstAge, 15));
        OracleAttestation.Attestation memory b = baseAttestation(200, now_ - secondAge, 16);
        approve(b);
        if (secondAge < firstAge) {
            submitSigned(b);
            (uint256 cents,) = feed.priceCents();
            assertEq(cents, 200);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(LumineonPriceFeed.NotNewerThanStored.selector, now_ - secondAge, now_ - firstAge)
            );
            submit(b, sign(b));
        }
    }

    function testFuzz_freshnessIsPureFunctionOfTime(uint32 elapsed) public {
        approve(baseAttestation(11_577, T0, 17));
        submitSigned(baseAttestation(11_577, T0, 17));
        elapsed = uint32(bound(elapsed, 0, 3 days));
        vm.warp(T0 + elapsed);
        bool expectFresh = elapsed <= 24 hours; // expiresAt is T0 + 86400 too
        assertEq(feed.isFresh(), expectFresh);
        (LumineonPriceFeed.Observation memory o, bool fresh) = feed.latestObservation();
        assertEq(fresh, expectFresh);
        assertEq(o.priceCents, 11_577, "history never erased");
        if (!expectFresh) {
            vm.expectRevert(
                abi.encodeWithSelector(LumineonPriceFeed.StalePrice.selector, T0, T0 + 86_400, uint256(T0 + elapsed))
            );
            feed.priceCents();
        }
    }

    function testFuzz_answerBytesMustEncodeFigureExactly(bytes calldata answer, uint256 figure) public {
        vm.assume(figure != 0);
        OracleAttestation.Attestation memory a = baseAttestation(figure, T0, 18);
        approve(a);
        a.answer = answer;
        bool wellFormed = answer.length == 32 && abi.decode(answer, (uint256)) == figure;
        bytes memory sig = sign(a);
        vm.prank(relayer);
        (bool ok,) = address(feed).call(abi.encodeCall(feed.submitAttestation, (a, sig)));
        assertEq(ok, wellFormed);
    }
}
