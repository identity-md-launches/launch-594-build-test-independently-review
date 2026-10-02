# Lumineon Price Feed

A small Ethereum Sepolia contract that stores the price of **one** graded Pokémon card and lets other
contracts read it. The only thing that can change the price is a signed answer from the IdentityMD
(IMD) oracle: a panel of at least 20 independent IMD contributors reads PriceCharting, at least 14 of
them must agree on the same number, and IMD's attester signs the result. Anyone can relay that signed
answer to the contract. Nobody, including the deployer and the contract owner, can type a price in.

This is a testnet prototype. It holds no funds, is not upgradeable, and has no manual override.

| | |
|---|---|
| Project | Lumineon Price Feed |
| Application contract | `LumineonPriceFeed` (`src/LumineonPriceFeed.sol`) |
| Launch token | `LaunchToken` (`src/LaunchToken.sol`), name `lumineon`, symbol `lumi` |
| Chain | Ethereum Sepolia, chain ID 11155111 |
| Deployed address | **not yet deployed**: filled in by IMD's deployer after review (see "Live status") |

## What the number means

The feed represents exactly:

- **Card:** Lumineon V, English Pokémon TCG, Crown Zenith: Galarian Gallery, card number GG39/GG70
- **Grade:** PSA 10
- **Currency:** US dollars, stored as an unsigned integer in **cents** (11577 means $115.77)
- **Source:** the headline price-guide estimate labelled "PSA 10" at
  <https://www.pricecharting.com/game/pokemon-crown-zenith/lumineon-v-gg39>

It is a published benchmark observation. It is not an individual sale, an asking price, a guaranteed
resale value, or an average across sources, and it excludes shipping, taxes and fees. All of this is
readable from the contract (`CARD_NAME`, `SET_NAME`, `CARD_NUMBER`, `GRADING_COMPANY`, `GRADE`,
`CURRENCY`, `DENOMINATION`, `PRICE_SOURCE_URL`, `PRICE_DEFINITION`, `description()`).

The stored `issuedAt` is **when IMD signed the panel's answer**. It is not the date of any card sale;
PriceCharting's own estimate may be based on older sales.

## How an update happens

```
requester pays IMD        IMD panel (20 seats)        IMD attester            anyone              LumineonPriceFeed
 oracle.request  ───────►  reads PriceCharting ────►  signs EIP-712 ───────►  relays calldata ──►  verifies, stores, emits
 (template below)          ≥14 must agree             (version 2 schema)      (external wallet)    PriceUpdated
                                      ▲
      owner approves the request's questionHash (once per request, before relay)
```

1. The requester submits the oracle request in `docs/oracle-request-template.json` to IMD
   (`oracle.request`, see <https://imd.fun/docs/#oracle-body>), with `consumer.verifyingContract`
   set to the deployed feed address in lowercase and `consumer.chainId` 11155111.
2. IMD immediately shows the request's `questionHash` at `GET https://api.imd.fun/oracle/requests/<id>`.
   The feed **owner** calls `approveQuestion(questionHash)`. This can and should happen before the
   panel has answered, so the owner never picks an answer, only a question.
3. When the request reads `attested`, anyone downloads
   `GET https://api.imd.fun/oracle/requests/<id>/attestation`, runs `tools/prepare-update.mjs` on it,
   and sends the printed calldata to the feed from any wallet.
4. The contract checks everything below and, if it all holds, stores the observation and emits
   `PriceUpdated`.

### What the contract verifies on every relay

| Check | Revert |
|---|---|
| `questionHash` was approved by the owner | `QuestionNotApproved` |
| signed `chainId` field is 1 (the chain the request's window is pinned on; see template) | `WrongQuestionChain` |
| `answerType` is 3 (uint256) | `WrongAnswerType` |
| `answer` is exactly 32 bytes and decodes to `figure` | `MalformedAnswer`, `AnswerFigureMismatch` |
| price is positive | `ZeroPrice` |
| `panelSize >= 20`, `quorum >= 14`, `quorum <= panelSize`, `agreed <= panelSize`, `agreed >= quorum` | `InsufficientPanel`, `InsufficientQuorum`, `InconsistentCounts`, `InsufficientAgreement` |
| `issuedAt <= expiresAt`, `issuedAt <= now`, `now <= expiresAt`, `now - issuedAt <= 24h` | `InvalidValidity`, `IssuedInFuture`, `AttestationExpired`, `AttestationTooOld` |
| `requestId` never used before | `RequestAlreadyUsed` |
| `issuedAt` strictly newer than the stored observation | `NotNewerThanStored` |
| EIP-712 signature by the pinned IMD attester over **this contract's** domain (Sepolia + this address) | `InvalidSignature` |

A newly signed observation with the **same** price as before is accepted: it is newer, so it refreshes
freshness.

### Reading the feed

- `priceCents() → (cents, issuedAt)`: strict. Reverts `NoObservation()` before the first update and
  `StalePrice(issuedAt, expiresAt, now)` once the observation is older than 24 hours from issuance or
  past its signed `expiresAt`.
- `latestObservation() → (Observation, fresh)`: lenient. Always returns the last stored observation
  (zeros when there is none) together with a freshness flag. History is never erased by expiry.
- `isFresh()`, `hasObservation()`, `observationAge()`.

Reading never changes state, so nothing a reader does can renew freshness.

The `Observation` struct holds `priceCents`, `requestId`, `questionHash`, `panelJobId`, `issuedAt`,
`expiresAt`, `receivedAt` (block time of the relay), `panelSize`, `quorum`, `agreed`.

`test/helpers/ExampleConsumer.sol` is a small contract that reads the feed both ways; its tests show the
strict reader reverting when empty or stale while the lenient reader still returns history.

## Roles and trust assumptions

| Who | Can | Cannot |
|---|---|---|
| IMD attester (`attester`, immutable, `0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982`) | Produce the only signatures the feed accepts | Bypass panel floors, age rules, replay or question approval |
| Owner (`owner`, set from the requester's `$owner`, two-step transferable) | `approveQuestion(bytes32)`; `transferOwnership` / `acceptOwnership` | Set a price, forge or replay an attestation, revoke an approval, change the attester, pause, upgrade, withdraw anything |
| Anyone | `submitAttestation`, all readers | Change state without a valid attestation |

**Why an owner exists at all.** IMD's `questionHash` covers the whole pinned request, not just the
question text: on 2026-10-02 two requests with byte-identical text but different pinned block windows
carried different hashes (`13a914c0…` → `0xa0db6dd1…`, `9b688860…` → `0xf15ed26e…`), and the hash of
the raw question text does not match either. So the contract cannot hard-code one hash, and it cannot
recompute the hash from the signed message. Without a binding, anyone could pay IMD for *any*
question whose `consumer` is this feed (for example "what is 2+2") and relay a valid signature. The
owner's approval is what binds the feed to the card question; the owner should compare the request's
text to the template (its keccak256 is `QUESTION_TEXT_HASH`) before approving.

**Repeated requests stay compatible** because every request made from the template has the same
text, the same `consumer`, and the same panel settings; only the window and the hash differ, and the
owner approves each new hash. Each hash identifies one pinned request, so a mistaken approval admits
at most that one request's single signed answer, which is why there is no revoke.

**Residual trust.** The owner can decline to approve a request it dislikes, and the owner key is a
single key. IMD's attester is a single key operated by IMD. The panel reads a third-party website;
the feed reports what PriceCharting published, not what the card is worth.

## Launch token

`LaunchToken` is the fixed-supply ERC-20 IMD's project launch requires: name `lumineon`, symbol
`lumi`, 18 decimals, exactly 1,000,000,000 tokens minted once to the deploying factory, no owner,
mint, pause, fee or upgrade functions. The factory splits that supply by its own policy (10% to the
swarm, the rest to the requester's pool and wallet). The price feed never reads, holds or moves the
token, and keeps working whatever happens to the token's pool. The brief asked for nothing more of the
token than its name and symbol, and nothing more was added.

## Build and test (offline)

Foundry with solc 0.8.26 (pinned in `foundry.toml`, `evm_version = "paris"`, optimizer 200 runs,
`bytecode_hash = "none"`). `lib/forge-std` is vendored as plain files; there are no remote dependencies.

```bash
forge build
forge test
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline   # local dry run, no keys
```

67 tests pass (`forge test -vv` for the list). Coverage, by file:

- `test/LumineonPriceFeed.t.sol`: two successive updates, unchanged-price refresh, permissionless
  relay, boundary at exactly 24h and at `expiresAt`, signed expiry shorter than 24h, reads never renew
  freshness, unauthorized signer, garbage signature, wrong domain chain, wrong verifying contract
  (IMD default domain and a sibling feed), wrong `chainId` field, tampered fields, unapproved
  question, approve-then-relay, owner-only approval, duplicate/zero approval, two-step ownership,
  owner cannot set a price, small panel, low quorum, agreed below quorum, inconsistent counts, wrong
  answer type, malformed answer bytes, answer/figure conflict, zero price, expired, older than 24h with
  a long IMD validity, future-issued, expiry before issue, replay, reused request id, out-of-order
  older/equal issue time, stale feed accepting a newer attestation, selector pin, no ETH accepted.
- `test/LumineonPriceFeed.fuzz.t.sol`: random prices/ages/validities, random panel counts against the
  floor rules, random signer keys, random domains, strict ordering of issue times, freshness as a pure
  function of time, arbitrary answer bytes versus figure.
- `test/RealAttestationCompatibility.t.sol`: recovers IMD's real attester from a real version-2
  attestation (request `ac82ce11-8ed0-48ef-bbba-49eea11c23b1`, fetched 2026-10-02, saved in
  `docs/examples/`), shows any field change breaks recovery, shows a Sepolia feed refuses that
  default-domain signature, and exercises malformed/malleable signatures.
- `test/ExampleConsumer.t.sol`, `test/LaunchToken.t.sol`, `test/Deploy.t.sol`.

Test signatures come from a throwaway key inside the tests (`FeedTestBase.TEST_ATTESTER_PK`); the
deployed configuration pins IMD's real attester, which no test key can impersonate.

## Oracle integration details

- Library: `src/OracleAttestation.sol`, written from the schema at <https://imd.fun/docs/#oracle>
  (domain `IdentityMD Oracle` version `2`; typed struct with fifteen fields). IMD's docs name an
  official `OracleAttestation.sol` but at the time of writing no download route exists on `imd.fun`
  or `api.imd.fun`, and the launch repositories that consume attestations re-implement the hashing
  inline. Compatibility was therefore proven against a **real signature** rather than assumed:
  `test_recoversImdAttesterFromRealSignature` recovers `0x5598…2982` from IMD's own attestation.
- Attester: `0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982`, reported by
  `GET https://api.imd.fun/oracle/requests` (field `attester`) and recovered from live signatures.
  No `network.json` was supplied with this task, so this value comes from the API; the manifest
  passes it as a constructor argument where a reviewer can see it.
- Domain: the contract computes `DOMAIN_SEPARATOR` from `block.chainid` and `address(this)`, so the
  oracle request **must** carry `consumer: {chainId: 11155111, verifyingContract: <feed, lowercase>}`.
  A request without it is signed under IMD's default domain (`verifyingContract` 0x0) and can never be
  relayed; the saved real attestation is exactly such a case and the tool reports it.
- Signed `chainId` field: the template pins the request to chain 1 because IMD requires a chain with
  a configured RPC to pin a window, and the price itself is web evidence. The contract requires 1 in
  that field (`QUESTION_CHAIN_ID`) so a request made from a different template is refused.

## Preparing an update from IMD's API response

```bash
curl -s https://api.imd.fun/oracle/requests/<REQUEST_ID>/attestation > attestation.json
node tools/prepare-update.mjs attestation.json --feed <FEED_ADDRESS> --chain 11155111
```

The script has no dependencies and never touches a key or a network. It prints the decoded price,
the ABI-encoded `submitAttestation` calldata (its selector is `0x383f5938`), every rejection reason it
can judge offline, and ready-to-edit commands:

```bash
# owner, once per request
cast send <FEED> "approveQuestion(bytes32)" <QUESTION_HASH> --rpc-url <SEPOLIA_RPC> --ledger
# anyone, after the request is attested (dry-run with `cast call` first)
cast send <FEED> <CALLDATA> --rpc-url <SEPOLIA_RPC> --ledger
```

Use `--ledger`, `--trezor`, `--keystore <file>` or `--interactive` so the key stays in the wallet.
Any wallet that can send raw calldata (Safe, Frame, Rabby "custom data") works the same way. Never
paste a private key into a shell or this repository.

## Live status

**Locally tested:** everything in the tables above, plus byte-compatibility with a real IMD signature.

**Not yet verified live:** no `LumineonPriceFeed` is deployed yet, no oracle request has been made
with this feed as `consumer`, and no attestation has been accepted on-chain. The real request
`ac82ce11…` proves IMD's panel can answer this exact question (20 seats, 14 agreed, $115.77 on
2026-10-02), but it was signed for the default domain and cannot update any consumer. The live price
integration should be described as succeeded only after a `PriceUpdated` event exists on Sepolia.

After IMD's deployer publishes the launch, record here: feed address, deployment transaction, the
first approved `questionHash`, and the first `PriceUpdated` transaction.

## Out of scope

Website, watcher, scheduler, automated relayer and paid oracle requests are not part of this
delivery. The feed is ready to receive real attestations as soon as it is deployed and a request is
made from the template.

## Files

```
src/LumineonPriceFeed.sol              the feed
src/OracleAttestation.sol              EIP-712 v2 library
src/LaunchToken.sol                    lumineon / lumi
src/interfaces/ILumineonPriceFeed.sol  reader interface for consumers
script/Deploy.s.sol                    constructor arguments in one place; local simulation only
test/                                  Foundry tests (see above)
tools/prepare-update.mjs               attestation JSON → calldata
docs/oracle-request-template.json      the exact request to pay IMD for
docs/deployment.md                     manifest parameters and operator responsibilities
docs/abi/*.json                        ABI exports
docs/examples/real-attestation-*.json  IMD's real attestation of this question
REVIEW.md                              independent review
```
