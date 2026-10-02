import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const tool = fileURLToPath(new URL("./prepare-update.mjs", import.meta.url));
const archivedResponse = JSON.parse(readFileSync(new URL("../docs/examples/real-attestation-ac82ce11.json", import.meta.url), "utf8"));
const FEED = "0x1111111111111111111111111111111111111111";
const OTHER_FEED = "0x2222222222222222222222222222222222222222";

// These domain variants test offline metadata checks only. The archived signature
// no longer authenticates a changed domain; cryptographic verification stays onchain.
function run({ feed = FEED, chain = 11155111, missingDomain = false } = {}, args = ["--feed", FEED]) {
  const body = structuredClone(archivedResponse);
  if (missingDomain) delete body.domain;
  else Object.assign(body.domain, { verifyingContract: feed, chainId: chain });
  const dir = mkdtempSync(join(tmpdir(), "lumineon-prepare-update-"));
  try {
    const path = join(dir, "attestation.json");
    writeFileSync(path, JSON.stringify(body));
    const result = spawnSync(process.execPath, [tool, path, ...args, "--now", "1790950000"], { encoding: "utf8" });
    assert.ifError(result.error);
    const jsonEnd = result.stdout.indexOf("\n#");
    return { ...result, output: jsonEnd < 0 ? null : JSON.parse(result.stdout.slice(0, jsonEnd)) };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("requires an independently supplied feed even when response names a consumer", () => {
  const result = run({ feed: OTHER_FEED, chain: 1 }, []);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /--feed is required/);
  assert.equal(result.stdout, "");
});

test("defaults expected chain to Sepolia when only the intended feed is supplied", () => {
  const result = run({ chain: 1 });
  assert.equal(result.status, 1);
  assert.equal(result.output.chain, 11155111);
  assert.ok(result.output.offlineChecks.includes("signed domain chainId 1 != consumer chain 11155111"));
});

test("rejects a response for a different consumer", () => {
  const result = run({ feed: OTHER_FEED });
  assert.equal(result.status, 1);
  assert.equal(result.output.feed, FEED);
  assert.ok(result.output.offlineChecks.some((problem) => problem.includes(`signed verifyingContract ${OTHER_FEED} != feed ${FEED}`)));
});

test("matching intended consumer and Sepolia metadata prepare request-specific approval", () => {
  const result = run();
  assert.equal(result.status, 0);
  assert.deepEqual(result.output.offlineChecks, ["all offline checks pass"]);
  assert.equal(result.output.selector, "0x383f5938");
  assert.ok(result.stdout.includes(`cast send ${FEED} "approveRequest(bytes32,bytes32)" ${archivedResponse.message.requestId} ${archivedResponse.message.questionHash}`));
  assert.ok(result.output.stillCheckedOnChain.some((check) => check.startsWith("approvedRequests(requestId) must equal questionHash")));
  assert.ok(result.output.stillCheckedOnChain.some((check) => check.includes("signature must verify")));
});

test("accepts explicitly supplied Sepolia chain configuration", () => {
  const result = run({}, ["--feed", FEED, "--chain", "11155111"]);
  assert.equal(result.status, 0);
  assert.equal(result.output.chain, 11155111);
});

test("rejects zero, malformed, or missing feed option values without producing commands", () => {
  for (const args of [["--feed", "0x" + "0".repeat(40)], ["--feed", "0xabc"], ["--feed"]]) {
    const result = run({}, args);
    assert.equal(result.status, 2);
    assert.equal(result.stdout, "");
  }
});

test("missing signed domain cannot pass offline domain checks", () => {
  const result = run({ missingDomain: true });
  assert.equal(result.status, 1);
  assert.ok(result.output.offlineChecks.includes("response is missing its signed domain"));
});
