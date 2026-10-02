This contribution adds adversarial tests to the accepted implementation. Application source,
deployment configuration, and dependencies are unchanged. No new dependency or network access is
needed to run the tests.

Run the repository checks with:

```sh
forge build
forge test
```

For this bounded task, build output and cache were kept in the disposable scratch directory:

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache
```

Local result on Foundry 1.8.3 / Solidity 0.8.26: build succeeds; **97 tests pass, zero fail,
zero skip**. Foundry groups the two invariant functions in each invariant test contract into one
campaign. The new fuzz tests each run 1,000 cases. Run counts and invariant depth are declared
inline in the Solidity files, so they also apply to an ordinary `forge test`.

Revision note (2026-10-02): the implementation replaced hash-only `approveQuestion(bytes32)` with
per-request `approveRequest(requestId, questionHash)`. The adversarial and invariant suites below
were ported to that binding model and extended to test it: an approved ID with another hash and an
approved hash with another ID are both refused, a binding is never replaced or revoked (not even by
the owner, not even after use), several requests sharing one hash each need their own approval and
are each consumed once, and approval of a pair never stands in for a signature over that pair.

| Test file | Added coverage |
| --- | --- |
| `LumineonPriceFeed.adversarial.t.sol` | Twenty invalid-update cases checked after an existing observation and an owner-approved request, exact revert reasons, preservation of all stored observation fields, bindings and replay state, and a successful corrected retry for each request. Also covers replay laundering through rebinding or another hash, cross-request signature reuse between two approved pairs, repeated requests sharing one hash, a 1,000-run fuzz of the exact-pair rule over random IDs and hashes, one-cent and maximum uint256 prices, delayed receipt versus issuance-based freshness, every non-uint256 answer type, answer encoding lengths, high-s signatures, signature-byte fuzzing, and replacement of a pending owner followed by binding rights moving to the accepted owner. |
| `RealAttestationCompatibility.t.sol` | Changes each of the fifteen signed fields and every domain component independently against the recorded real IMD signature. This fixture does not use the local signing key or recompute a matching signature with the implementation being tested. |
| `LumineonPriceFeed.invariant.t.sol` | Four actors exercise valid/new/unchanged-price observations, malformed or unauthorized submissions (bound ID with wrong hash, unbound ID with the approved hash, and eight other faults), replay, ordering, time, request bindings by any actor including rebinding attempts, and ownership handoffs. Ghost state models the entire observation from submitted inputs, every binding the owner made, permanent consumption of accepted requests, IDs that must stay unbound, and ownership. Bindings left by rejected relays are later consumed by valid ones. Every step checks strict/lenient reads, freshness, retained history, and that each binding is unchanged and consumed exactly when accepted. 256 runs of 64 calls: 16,384 handler calls. |
| `LaunchToken.adversarial.t.sol` | Zero, one-unit, full-supply and maximum-integer transfer boundaries; self-transfers; finite and unlimited approval replacement/revocation; unauthorized spending; and rollback after a failed delegated transfer. |
| `LaunchToken.invariant.t.sol` | Four actors exercise transfers, approvals, delegated spending, revocation, and invalid operations. Independent ghost balances and allowances check exact fixed-supply conservation and failure atomicity after every step. 256 runs of 96 calls: 24,576 handler calls. |

Both invariant campaigns select only their handler actions and use `fail-on-revert = true`.
Expected contract failures are caught explicitly; an unexpected handler failure fails the run.
Inputs are bounded, timestamps move forward, and all actors and signing keys are local fixtures.
Neither suite writes environment variables, forks a chain, uses FFI, or reads discarded task inputs.

The existing tests retain coverage of two successive observations, an unchanged-price refresh,
empty and stale consumers, constructors, factory-style ownership, metadata, and the initial real
attestation compatibility check.

A separate review of the implementation and added tests found no reproducible contract defect
requiring a findings report. The review also checked the documented v2 schema against the
[IMD oracle documentation](https://imd.fun/docs/#oracle), checked that the request-template text
hash matches `QUESTION_TEXT_HASH`, and compared the utility's encoded fixture calldata with
`cast calldata`. These checks do not establish that the trusted signer configuration will remain
current or that a live relay has succeeded.

The recorded real signature proves offline encoding compatibility. Its default domain cannot
update this consumer. Test-key attestations exercise local feed behavior only. No deployed
Sepolia address, deployment transaction, paid request, or onchain acceptance is claimed here;
deployment and the first real consumer-bound attestation remain launch-pipeline work.
