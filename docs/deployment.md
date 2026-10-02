# Deployment parameters and operator responsibilities

Deployment is done by IMD's deployer through ProjectFactory on Ethereum Sepolia (11155111) after
the independent review. No contributor signs a transaction; no key appears in this repository.

## Manifest facts (for `launch.json`)

| Item | Value |
|---|---|
| kind | `evm_project` |
| chain | Sepolia, 11155111 |
| launch token | `LaunchToken` (`src/LaunchToken.sol`), no constructor arguments, name `lumineon`, symbol `lumi`, 18 decimals |
| application contracts | exactly one: `LumineonPriceFeed` (`src/LumineonPriceFeed.sol`) |
| `LumineonPriceFeed` constructor | `(address owner_, address attester_)` |
| `owner_` | `$owner` (the requester's configured wallet). **Never** the factory's `msg.sender`: the factory is immutable and could never call `approveQuestion`, which would leave the feed permanently unable to accept any answer. |
| `attester_` | `0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982` (IMD attestation signer; `GET https://api.imd.fun/oracle/requests` → `attester`, and recovered from live signatures in `test/RealAttestationCompatibility.t.sol`) |
| pool | pairs `lumi` with native ETH; manifest fee 3000, tickSpacing 60, `initialPrice` `79228162514264337593543950336`; the factory supplies PoolInitializationGuard, LP and MerkleDistributor; the pool opens at the network's trading fee, not 0.3% |
| compiler | solc 0.8.26, optimizer 200 runs, EVM paris, `bytecode_hash = "none"`, `cbor_metadata = false` |

A draft `launch.json` with these values sits in the repository root for the manifest step to
confirm or replace.

Constructor types are factory-compatible (two addresses, nonpayable, no dynamic arguments). The
contract has no initializer: it is fully configured at construction and starts with no price.

### Things that would make the deployment inert

- Passing the factory or a zero/unknown wallet as `owner_`: nobody could approve a question.
- Passing a wrong attester: every real attestation would revert `InvalidSignature`.
- Verify both after deployment with `cast call <FEED> "owner()(address)"` and
  `cast call <FEED> "attester()(address)"` before paying for any oracle request.

## Operator responsibilities after deployment

1. **Record** the feed address and deployment transaction in `README.md` ("Live status").
2. **Request**: fill `consumer.verifyingContract` in `docs/oracle-request-template.json` with the feed
   address in lowercase and pay IMD for `oracle.request`. Keep `panelSize` 20, `quorum` 14,
   `toleranceBps` 0, `validForSeconds` 86400, `answerType` uint256, `chainId` 1 and the question text
   unchanged. The paid `/requests/quote` route refuses a checksummed consumer address.
3. **Approve**: read `questionHash` from `GET https://api.imd.fun/oracle/requests/<id>`, confirm the
   request's `question` is byte-identical to the template (its keccak256 is
   `LumineonPriceFeed.QUESTION_TEXT_HASH` = `0x3fbd772da2fd23d430b982d57a8e50a2e9a72e51764c7029881b4f30cabcce77`),
   then call `approveQuestion(questionHash)` from the owner wallet.
4. **Relay**: once the request is `attested` and within 24 hours of `issuedAt`, run
   `node tools/prepare-update.mjs attestation.json --feed <FEED>` and send the calldata from any wallet.
   A dry run with `cast call` costs nothing and returns the exact revert reason if something is off.
5. **Verify**: `PriceUpdated` event in the transaction, `priceCents()` returns the value,
   `isFresh()` is true.
6. **Repeat** for each new request. Each one needs its own approval; approvals are permanent.

## Trust and limits, restated for the reviewer

- The owner is the question approver and nothing else. It cannot set, change or delete a price.
- The attester is a single IMD-operated key. If IMD rotates it, this feed needs a redeployment; there
  is no setter on purpose.
- A freshness window of 24 hours from `issuedAt` means the feed goes stale without a daily request.
  Stale reads revert on the strict path and are flagged on the lenient path; history is kept.
- The feed holds no ETH or tokens (no `receive`/`fallback`), has no `selfdestruct`, `delegatecall`
  or proxy, and depends on no external contract at runtime.
