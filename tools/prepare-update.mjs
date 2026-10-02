#!/usr/bin/env node
// Prepare LumineonPriceFeed.submitAttestation calldata from IMD's attestation API response.
//
//   node tools/prepare-update.mjs <attestation.json> [--feed 0x...] [--chain 11155111] [--now <unix>]
//
// <attestation.json> is the body of GET https://api.imd.fun/oracle/requests/<id>/attestation
// (save it with curl). The script never signs, never asks for a key and never talks to a chain.
// It prints the ABI-encoded calldata plus a `cast send` line for an external wallet (hardware
// wallet, keystore or WalletConnect-capable tool), and a list of every reason the contract would
// reject the attestation that can be judged offline.
//
// No dependencies: ABI encoding is written out by hand and keccak-256 is implemented below so the
// function selector is computed, not pasted. test/LumineonPriceFeed.t.sol pins the same selector.

import { readFileSync } from "node:fs";

// ----------------------------------------------------------------------------- keccak-256
const RC = [
  1n, 0x8082n, 0x800000000000808an, 0x8000000080008000n, 0x808bn, 0x80000001n,
  0x8000000080008081n, 0x8000000000008009n, 0x8an, 0x88n, 0x80008009n, 0x8000000an,
  0x8000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x80000001n, 0x8000000080008008n,
];
const ROT = [
  [0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14],
];
const M64 = (1n << 64n) - 1n;
const rotl = (x, n) => n === 0 ? x : ((x << BigInt(n)) | (x >> BigInt(64 - n))) & M64;

function keccakF(s) {
  for (let round = 0; round < 24; round++) {
    const c = [0n, 0n, 0n, 0n, 0n];
    for (let x = 0; x < 5; x++) c[x] = s[x] ^ s[x + 5] ^ s[x + 10] ^ s[x + 15] ^ s[x + 20];
    for (let x = 0; x < 5; x++) {
      const d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1);
      for (let y = 0; y < 25; y += 5) s[x + y] ^= d;
    }
    const b = new Array(25).fill(0n);
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(s[x + 5 * y], ROT[x][y]);
      }
    }
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        s[x + 5 * y] = b[x + 5 * y] ^ ((~b[((x + 1) % 5) + 5 * y]) & M64 & b[((x + 2) % 5) + 5 * y]);
      }
    }
    s[0] ^= RC[round];
  }
}

export function keccak256(bytes) {
  const rate = 136;
  const padded = new Uint8Array(Math.ceil((bytes.length + 1) / rate) * rate);
  padded.set(bytes);
  padded[bytes.length] ^= 0x01;
  padded[padded.length - 1] ^= 0x80;
  const s = new Array(25).fill(0n);
  for (let off = 0; off < padded.length; off += rate) {
    for (let i = 0; i < rate / 8; i++) {
      let lane = 0n;
      for (let j = 7; j >= 0; j--) lane = (lane << 8n) | BigInt(padded[off + i * 8 + j]);
      s[i] ^= lane;
    }
    keccakF(s);
  }
  const out = new Uint8Array(32);
  for (let i = 0; i < 4; i++) {
    let lane = s[i];
    for (let j = 0; j < 8; j++) { out[i * 8 + j] = Number(lane & 0xffn); lane >>= 8n; }
  }
  return out;
}

// ----------------------------------------------------------------------------- helpers
const hex = (u8) => "0x" + Array.from(u8, (b) => b.toString(16).padStart(2, "0")).join("");
const fromHex = (h) => {
  const s = h.startsWith("0x") ? h.slice(2) : h;
  if (s.length % 2) throw new Error(`odd-length hex: ${h}`);
  return Uint8Array.from(s.match(/../g) ?? [], (b) => parseInt(b, 16));
};
const utf8 = (s) => new TextEncoder().encode(s);
const word = (v) => BigInt(v).toString(16).padStart(64, "0");
const bytes32Word = (h) => {
  const s = fromHex(h);
  if (s.length !== 32) throw new Error(`expected 32 bytes, got ${s.length}: ${h}`);
  return hex(s).slice(2);
};
const ANSWER_TYPE = { bool: 0, address: 1, bytes32: 2, uint256: 3, "address[]": 4, "bytes32[]": 5 };

function encodeSubmitAttestation(m, signature) {
  const answerType = typeof m.answerType === "string" ? ANSWER_TYPE[m.answerType] : Number(m.answerType);
  if (answerType === undefined) throw new Error(`unknown answerType ${m.answerType}`);
  const answer = fromHex(m.answer);
  const sig = fromHex(signature);

  // Tuple (dynamic because of `bytes answer`): 15 head words, answer tail.
  const head = [
    bytes32Word(m.requestId), word(m.chainId), bytes32Word(m.questionHash), word(answerType),
    word(15 * 32), // offset of `answer` inside the tuple
    word(m.figure), word(m.fromBlock), word(m.toBlock), bytes32Word(m.blockHash), bytes32Word(m.panelJobId),
    word(m.panelSize), word(m.quorum), word(m.agreed), word(m.issuedAt), word(m.expiresAt),
  ].join("");
  const dyn = (b) => word(b.length) + hex(b).slice(2).padEnd(Math.ceil(b.length / 32) * 32 * 2, "0");
  const tuple = head + dyn(answer);
  const tupleBytes = tuple.length / 2;
  const sigEnc = dyn(sig);
  const args = word(64) + word(64 + tupleBytes) + tuple + sigEnc;

  const selectorInput = "submitAttestation((bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";
  const selector = hex(keccak256(utf8(selectorInput))).slice(2, 10);
  return { calldata: "0x" + selector + args, selector: "0x" + selector, answerType, answer, sig };
}

// ----------------------------------------------------------------------------- main
function main() {
  const argv = process.argv.slice(2);
  const file = argv.find((a) => !a.startsWith("--"));
  const opt = (name, dflt) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : dflt; };
  if (!file) {
    console.error("usage: node tools/prepare-update.mjs <attestation.json> [--feed 0x...] [--chain 11155111] [--now unix]");
    process.exit(2);
  }
  const body = JSON.parse(readFileSync(file, "utf8"));
  const { domain, message: m, signature, signer } = body;
  if (!m || !signature) throw new Error("file is not an attestation response (needs message and signature)");

  const feed = (opt("--feed", domain?.verifyingContract) ?? "").toLowerCase();
  const chain = Number(opt("--chain", domain?.chainId ?? 11155111));
  const now = Number(opt("--now", Math.floor(Date.now() / 1000)));

  const enc = encodeSubmitAttestation(m, signature);
  const problems = [];
  const attester = "0x5598aa9146215bc13eb26f2c692ad1461fd32982";
  if (domain) {
    if (domain.name !== "IdentityMD Oracle" || String(domain.version) !== "2") problems.push(`domain is ${domain.name} v${domain.version}; the feed verifies "IdentityMD Oracle" v2`);
    if (Number(domain.chainId) !== chain) problems.push(`signed domain chainId ${domain.chainId} != consumer chain ${chain}`);
    if ((domain.verifyingContract ?? "").toLowerCase() !== feed) problems.push(`signed verifyingContract ${domain.verifyingContract} != feed ${feed} (was consumer set on the request?)`);
    if (/^0x0{40}$/.test(domain.verifyingContract ?? "")) problems.push("signed under IMD's default domain (verifyingContract 0x0): no consumer can accept it");
  }
  if (signer && signer.toLowerCase() !== attester) problems.push(`signer ${signer} is not the pinned attester ${attester}`);
  if (Number(m.chainId) !== 1) problems.push(`message chainId ${m.chainId} != QUESTION_CHAIN_ID 1`);
  if (enc.answerType !== 3) problems.push(`answerType ${m.answerType} is not uint256`);
  if (enc.answer.length !== 32) problems.push(`answer is ${enc.answer.length} bytes, not 32`);
  else if (BigInt(hex(enc.answer)) !== BigInt(m.figure)) problems.push(`answer ${BigInt(hex(enc.answer))} != figure ${m.figure}`);
  if (BigInt(m.figure) === 0n) problems.push("figure is zero");
  if (Number(m.panelSize) < 20) problems.push(`panelSize ${m.panelSize} < 20`);
  if (Number(m.quorum) < 14) problems.push(`quorum ${m.quorum} < 14`);
  if (Number(m.quorum) > Number(m.panelSize) || Number(m.agreed) > Number(m.panelSize)) problems.push("inconsistent panel counts");
  if (Number(m.agreed) < Number(m.quorum)) problems.push(`agreed ${m.agreed} < quorum ${m.quorum}`);
  if (Number(m.expiresAt) < Number(m.issuedAt)) problems.push("expiresAt before issuedAt");
  if (Number(m.issuedAt) > now) problems.push(`issuedAt ${m.issuedAt} is in the future (now ${now})`);
  if (now > Number(m.expiresAt)) problems.push(`expired at ${m.expiresAt} (now ${now})`);
  if (now - Number(m.issuedAt) > 86400) problems.push(`issued ${now - Number(m.issuedAt)}s ago, over the 24h maximum`);
  if (enc.sig.length !== 65) problems.push(`signature is ${enc.sig.length} bytes, not 65`);

  const out = {
    feed, chain, selector: enc.selector,
    requestId: m.requestId, questionHash: m.questionHash, priceCents: String(m.figure),
    priceUsd: (Number(m.figure) / 100).toFixed(2), issuedAt: Number(m.issuedAt), expiresAt: Number(m.expiresAt),
    issuedAtIso: new Date(Number(m.issuedAt) * 1000).toISOString(),
    panel: { panelSize: m.panelSize, quorum: m.quorum, agreed: m.agreed },
    calldata: enc.calldata,
    offlineChecks: problems.length ? problems : ["all offline checks pass"],
    stillCheckedOnChain: [
      "approvedQuestions(questionHash) must be true (owner approves it first)",
      "usedRequests(requestId) must be false",
      "issuedAt must be strictly newer than the stored observation",
      "signature must verify against the deployed feed's DOMAIN_SEPARATOR",
    ],
  };
  console.log(JSON.stringify(out, null, 2));
  console.log("\n# Owner step (once per request), from the owner's wallet:");
  console.log(`cast send ${feed || "<FEED>"} "approveQuestion(bytes32)" ${m.questionHash} --rpc-url <SEPOLIA_RPC> --ledger   # or --keystore / --interactive`);
  console.log("\n# Relay step (anyone), raw calldata so no ABI file is needed:");
  console.log(`cast send ${feed || "<FEED>"} ${enc.calldata} --rpc-url <SEPOLIA_RPC> --ledger   # or --keystore / --interactive`);
  console.log("\n# Dry run first (no wallet needed):");
  console.log(`cast call ${feed || "<FEED>"} ${enc.calldata} --rpc-url <SEPOLIA_RPC>`);
  if (problems.length) process.exitCode = 1;
}

if (import.meta.url === `file://${process.argv[1]}`) main();
