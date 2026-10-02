# Independent review: Lumineon Price Feed

Scope: `src/LumineonPriceFeed.sol`, `src/OracleAttestation.sol`, `src/LaunchToken.sol`,
`script/Deploy.s.sol`, the test suite, `tools/prepare-update.mjs`, `docs/oracle-request-template.json`
and the draft `launch.json`. Method: read every entry point against the eth-security and
solidity-security-review checklists supplied with the task, reproduce each concern with a test or a
command, and record the disposition. Original build checks: `forge build`, `forge test` (67 tests, 256 fuzz runs
each), `forge fmt --check`, `forge script` dry runs, `cast calldata` / `cast keccak` cross-checks of
the Node tool. Slither and Mythril were not available in this environment. Passing tests are not an
audit; the original review below was written by the same seat that built the code. The separate
revision review at the end records the subsequent findings, fixes, and independent agent checks.

## Entry points and who may call them

| Function | Caller | State effect |
|---|---|---|
| `constructor(owner_, attester_)` | factory | sets owner, attester, domain separator; reverts on zero |
| `approveRequest(bytes32,bytes32)` | owner only | binds one actual `requestId` to its `questionHash`, permanent |
| `transferOwnership(address)` / `acceptOwnership()` | owner / pending owner | two-step handover |
| `submitAttestation(Attestation, bytes)` | anyone | stores an observation only after all checks |
| readers | anyone | none |

No `receive`, no `fallback`, no payable function, no `selfdestruct`, `delegatecall` or proxy
(`test_feedHoldsNoEthAndRejectsIt`; `Project.protected.t.sol` scans the runtime for `0xf4/0xf2/0xff`).

## Findings

### F1. Question binding depends on an off-chain step by the owner — accepted design, documented

IMD's `questionHash` covers the pinned request, not the question text (verified: identical text,
different windows, different hashes; ~450 candidate preimages including JSON and ABI encodings of the
request fields did not reproduce it). The contract therefore cannot verify the question itself and
relies on the owner checking each request's text and full policy before approving its ID/hash pair.
Consequences the requester must accept:

- A careless owner can approve a request with a different question or relaxed policy. The blast
  radius is one request's single signed answer, now enforced by approval of both its ID and hash plus
  replay protection. Hash-only approval was insufficient: distinct requests can share a hash while
  changing tolerance or guards, which v2 does not sign. See the revision review below.
- The owner can refuse to approve, which is a liveness control, not a price control. The owner
  cannot write a price. `test_ownerCannotSetPriceOrForgeAttestation`.

Disposition: documented in README and `docs/deployment.md`; the template plus `QUESTION_TEXT_HASH`
give the owner a byte-exact text check; the full request settings also need inspection. If IMD later
signs a canonical question identity and the complete required policy, a future redeployment could
remove the role.

### F2. Attester is a single immutable key — accepted, documented

Rotation by IMD requires redeployment. A setter was deliberately not added (it would be a
price-control power). `test_rejectsUnauthorizedSigner`, `testFuzz_onlyTheConfiguredAttesterIsAccepted`.

### F3. The real attestation on record cannot update any consumer — informational

Request `ac82ce11…` was signed under IMD's default domain (`verifyingContract` 0x0) and with
`toleranceBps` 100. The feed refuses it (`test_sepoliaFeedRefusesDefaultDomainAttestation`) and the
tool flags it. A new request from the template with `consumer` set is required. Not a defect.

### F4. Signed `chainId` field pinned to 1 — accepted

If IMD ever lets panel-evidence questions pin a Sepolia window, requests made with `chainId`
11155111 would be refused (`WrongQuestionChain`). The template pins 1, so this is a consistency
check rather than a limitation today. Documented.

### F5. Freshness boundary semantics — verified

Accepted while `now - issuedAt <= 24h` and `now <= expiresAt`; fresh under the same rule. Exactly at
both boundaries the observation is accepted and fresh; one second later it is stale
(`test_acceptsAtExactMaxAgeAndAtExpiry`, `testFuzz_freshnessIsPureFunctionOfTime`). A shorter signed
validity wins over the 24h rule (`test_freshnessHonoursSignedExpiryBeforeMaxAge`); a longer one does
not extend it (`test_rejectsOlderThanMaxAgeEvenIfUnexpired`).

### F6. Replay and ordering — verified

`requestId` is consumed before any effect; a reused id with a newer `issuedAt` is still refused
(`test_rejectsReusedRequestIdWithNewerIssueTime`). Equal `issuedAt` is refused, so two attestations
signed in the same second cannot both land; the second must wait for a newer signature. This is the
"strictly newer" rule the brief asks for.

### F7. Signature handling — verified

65-byte `r||s||v` only, `s` restricted to the lower half, `v ∈ {27, 28}`, `ecrecover` zero result
refused (`test_recoverRejectsMalformedSignatures`, `test_rejectsGarbageSignature`). ERC-1271 is not
supported on purpose: the attester is an EOA.

### F8. Encoding compatibility — verified against IMD's own signature

`test_recoversImdAttesterFromRealSignature` recovers `0x5598…2982` from a version-2 attestation IMD
produced on 2026-10-02 for this very question. The struct hash is built in two `abi.encode` halves;
since `answer` is pre-hashed every field is a single static word, so the concatenation is
byte-identical to one encoding. The memory twin in `FeedTestBase` is an independent re-derivation.

### F9. Malformed answers — verified

`answer` must be exactly 32 bytes and decode to `figure`; `figure` must be non-zero; `answerType`
must be 3. `testFuzz_answerBytesMustEncodeFigureExactly` covers arbitrary byte strings.

### F10. Node tool — verified

Hand-written keccak-256 matches `cast keccak` for lengths 0, 3, 135, 136, 137 and 500 bytes (around
the 136-byte rate boundary). Calldata for the real attestation matches `cast calldata` exactly; the
selector `0x383f5938` is pinned by `test_submitSelectorMatchesTooling`. The tool reads no key and
opens no connection.

### F11. Deploy script — verified

`run()` reads only `EXPECTED_CHAIN_ID` and an optional `FEED_OWNER`; it refuses a chain other than
31337/11155111 and a missing owner when a chain is expected; with `EXPECTED_CHAIN_ID=0` it dry-runs
with a placeholder owner. The factory path does not use the script; `launch.json` carries the same two
constructor arguments.

### F12. Launch token — verified against the protected floor

Fixed supply 10^27 to `msg.sender`, 18 decimals, no admin surface, exact transfers, no
`delegatecall`/`selfdestruct`. `test/LaunchToken.t.sol` plus `Token.protected.t.sol` semantics.

## What the tests do not cover

- Live behaviour on Sepolia: no deployment and no real relay yet (see README "Live status").
- Gas: not asserted (forge isolates calls; not meaningful here).
- Invariant/handler tests: the contract has a single state transition and the fuzz suite covers its
  inputs; a stateful invariant suite would add little.
- IMD-side failure modes (panel disagreement, refused question, attester outage) end with no
  attestation and therefore no state change; they are documented, not simulated.

## Open items for the deployer

- Confirm `$owner` resolves to the requester's wallet, not a platform address, before admission.
- Explorer verification of source after deployment.
- Record the deployed address, deployment transaction and first `PriceUpdated` in the README.


## Revision review — 2026-10-02

**9e2fad735d293be35dc871d3dc8bdd4a193a9b32a8dee4477e3c0ca828258c6a — fixed.**
The original hash-only approval accepted a correctly signed second request sharing the approved
hash without its own approval. Both regression tests in `test/RequestApproval.t.sol` failed against
the original implementation, before any observation and after the first observation.

A separate agent also repeated the two unpaid `POST https://api.imd.fun/requests/quote` calls at
14:24:49 UTC. With the template, consumer `0x1111111111111111111111111111111111111111` on Sepolia,
and mainnet window 26104818–26105117, these quote orders both returned HTTP 201, `paidAt: null`:

| Quote order ID (not oracle request ID) | Policy | Returned question hash |
|---|---|---|
| `61bcec40-7821-41df-b922-5dfc9b059747` | tolerance 0, template guards | `0xee262f936ec2f6bdbdc1590b41ed8d109cba6f019842fe73eb03ea6581b1deff` |
| `50158240-68f5-4c65-8c88-7a7297404bad` | tolerance 10000, guards absent | `0xee262f936ec2f6bdbdc1590b41ed8d109cba6f019842fe73eb03ea6581b1deff` |

The responses retained the different policies and had different input hashes. This verifies the
policy collision, not a live exploit: no quote was paid and no relaxed-policy signature or onchain
transaction was obtained. The local contract reproduction uses test signatures only.

`approveRequest(requestId, questionHash)` now binds one actual oracle request ID to its hash;
`submitAttestation` requires the exact pair. Zero values and replacing an existing binding are
rejected. Replay protection still allows only one accepted answer per ID. The owner must check the
specific request's text and full settings, including unsigned zero tolerance and guards; the runbook
explains actual oracle UUID provenance and encoding. Repeated requests with the same hash and price
need independent approvals and can refresh the feed. Permissionless relay remains available.

**a28e5c7b84a1c3c86f976042b62577fb814d09a233c7ad723d7fdfe6015bbb80 — fixed.**
Changing only the archived response's consumer metadata to a nonzero address reproduced exit 0 and
"all offline checks pass" on chain 1 without options, and again with only matching `--feed`.
The revised utility requires a valid nonzero independently supplied `--feed` and defaults expected
chain to Sepolia. It rejects a missing response domain and mismatched consumer/chain. These checks
validate metadata only; the contract still verifies the signature. The template and runbook use the
new pair approval and explicit Sepolia configuration.

**Independent agent review.** A separate agent in this session reviewed the revised contract,
utility, tests, ABI and operational docs without editing the implementation. No concrete findings
remained. It ran 49 targeted delivered Foundry tests and all 7 Node tests, plus 4 temporary
adversarial tests (two fuzzed with 256 cases each): different ID with approved hash, different hash
with approved ID, explicit approval then unchanged-price refresh and replay rejection, and invalid
signature leaving approval usable. All passed. The temporary tests were removed; the four delivered
request-approval regression tests remain. All three delivered ABIs matched compiled artifacts.

Final local checks: `forge build`, `forge test` (71 passed, zero failed/skipped, 256 cases per fuzz
test), `forge fmt --check`, and `node --test tools/prepare-update.test.mjs` (7 passed). Compiler remains
solc 0.8.26. This is local independent agent review, not an external audit. Deployment and real
attestation acceptance on Sepolia remain unverified; no live integration success is claimed.
