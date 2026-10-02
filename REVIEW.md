# Independent review: Lumineon Price Feed

Scope: `src/LumineonPriceFeed.sol`, `src/OracleAttestation.sol`, `src/LaunchToken.sol`,
`script/Deploy.s.sol`, the test suite, `tools/prepare-update.mjs`, `docs/oracle-request-template.json`
and the draft `launch.json`. Method: read every entry point against the eth-security and
solidity-security-review checklists supplied with the task, reproduce each concern with a test or a
command, and record the disposition. Tools run: `forge build`, `forge test` (67 tests, 256 fuzz runs
each), `forge fmt --check`, `forge script` dry runs, `cast calldata` / `cast keccak` cross-checks of
the Node tool. Slither and Mythril were not available in this environment. Passing tests are not an
audit; this review was written by the same seat that built the code and a separate adversarial
review follows in the workflow.

## Entry points and who may call them

| Function | Caller | State effect |
|---|---|---|
| `constructor(owner_, attester_)` | factory | sets owner, attester, domain separator; reverts on zero |
| `approveQuestion(bytes32)` | owner only | marks one `questionHash` admissible, permanent |
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
relies on the owner approving each request's hash. Consequences the requester must accept:

- A careless owner can approve a request with a different question. The blast radius is one
  request's single signed answer (hash ↔ pinned request, replay-protected by `requestId`).
- The owner can refuse to approve, which is a liveness control, not a price control. The owner
  cannot write a price. `test_ownerCannotSetPriceOrForgeAttestation`.

Disposition: documented in README and `docs/deployment.md`; the template plus `QUESTION_TEXT_HASH`
give the owner a byte-exact check. If IMD later publishes a text-only question identifier in the
signed message, a redeploy could remove the role.

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
