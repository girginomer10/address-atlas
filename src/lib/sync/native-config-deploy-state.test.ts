import { execFileSync, spawnSync } from "node:child_process";
import {
  chmodSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  unlinkSync,
  writeFileSync
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { nativeConfigDigest } from "./native-config-digest";
import type { NativeEndpointConfig } from "./native-config";

const repoRoot = resolve(import.meta.dirname, "../../..");
const stateTool = join(repoRoot, "server/sync/native-config-deploy-state.mjs");

describe("native config deployment high-water state", () => {
  let temporaryDirectory: string;
  let privateDirectory: string;
  let stateFile: string;

  beforeEach(() => {
    temporaryDirectory = realpathSync(mkdtempSync(join(tmpdir(), "address-atlas-config-state-")));
    privateDirectory = join(temporaryDirectory, "state");
    mkdirSync(privateDirectory, { mode: 0o700 });
    stateFile = join(privateDirectory, "native-config.json");
  });

  afterEach(() => {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  });

  it("fingerprints semantic JSON deterministically across object key order", () => {
    const first = fingerprint(validConfig());
    const second = fingerprint(reverseObjectKeys(validConfig()));
    const [, commandDigest] = first.split("|");

    expect(first).toMatch(/^5\|[0-9a-f]{64}\|1784505600000$/);
    expect(second).toBe(first);
    expect(commandDigest).toBe(nativeConfigDigest(validConfig() as unknown as NativeEndpointConfig));
  });

  it("changes the digest when same-version client-visible policy changes", () => {
    const first = fingerprint(validConfig());
    const changed = validConfig();
    changed.message = "maintenance";
    const second = fingerprint(changed);

    expect(second.split("|")[0]).toBe("5");
    expect(second).not.toBe(first);
  });

  it.each([
    null,
    [],
    { ...validConfig(), configVersion: 4 },
    { ...validConfig(), unknown: true },
    { ...validConfig(), updatedAt: "2026-02-31T00:00:00.000Z" },
    { ...validConfig(), updatedAt: "2620-01-01T00:00:00.000Z" },
    { ...validConfig(), minSupportedAppVersion: "2000000001.0" },
    { ...validConfig(), priceBaseUrl: "https://api.coingecko.com/other" },
    { ...validConfig(), chains: [] },
    { ...validConfig(), chains: { evil: { rpcUrl: "https://ethereum-rpc.publicnode.com" } } },
    { ...validConfig(), chains: { ethereum: { rpcUrl: "http://127.0.0.1" } } },
    { ...validConfig(), chains: { ethereum: { restUrl: "https://ethereum-rpc.publicnode.com" } } },
    { ...validConfig(), exchanges: { binance: { baseUrl: "https://example.invalid" } } }
  ])("rejects malformed or unsupported config %#", (config) => {
    const result = run(["fingerprint"], JSON.stringify(config));
    expect(result.status).toBe(65);
    expect(result.stdout).toBe("");
  });

  it("allows small clock skew but rejects an implausibly future-dated policy", () => {
    const withinSkew = validConfig();
    withinSkew.updatedAt = new Date(Date.now() + 4 * 60_000).toISOString();
    expect(run(["fingerprint"], JSON.stringify(withinSkew)).status).toBe(0);

    const beyondSkew = validConfig();
    beyondSkew.updatedAt = new Date(Date.now() + 6 * 60_000).toISOString();
    const result = run(["fingerprint"], JSON.stringify(beyondSkew));
    expect(result.status).toBe(65);
    expect(result.stderr).toContain("implausibly in the future");
  });

  it("gates a native release on production config and minimum app compatibility", () => {
    const accepted = run(["release-gate", "0.2.0", "5"], JSON.stringify(validConfig()));
    expect(accepted.status).toBe(0);
    expect(accepted.stdout).toMatch(/^5\|[0-9a-f]{64}\|1784505600000\n$/);

    const tooOldForPolicy = validConfig();
    tooOldForPolicy.minSupportedAppVersion = "0.3.0";
    expect(run(["release-gate", "0.2.0", "5"], JSON.stringify(tooOldForPolicy)).status).toBe(67);
    expect(run(["release-gate", "0.2.0", "6"], JSON.stringify(validConfig())).status).toBe(67);
    expect(run(["release-gate", "not-semver", "5"], JSON.stringify(validConfig())).status).toBe(65);
  });

  it("binds response headers to the exact config digest and serving revision", () => {
    const [, digest] = fingerprint(validConfig()).split("|");
    const revision = "a".repeat(40);
    const headers = join(privateDirectory, "headers.txt");
    writeFileSync(headers, [
      "HTTP/2 200",
      "content-type: application/json; charset=utf-8",
      "cache-control: no-store",
      `etag: \"sha256-${digest}\"`,
      `x-address-atlas-build-revision: ${revision}`,
      "",
      ""
    ].join("\r\n"), { mode: 0o600 });

    expect(run(["verify-response", headers, digest!, revision]).status).toBe(0);
    expect(run(["verify-response", headers, "b".repeat(64), revision]).status).toBe(67);
    expect(run(["verify-response", headers, digest!, "c".repeat(40)]).status).toBe(67);
    chmodSync(headers, 0o666);
    expect(run(["verify-response", headers, digest!, revision]).status).toBe(66);
  });

  it("writes, fsyncs, and reads a canonical owner-only state record", () => {
    const [version, digest, updatedAtEpochMs] = fingerprint(validConfig()).split("|");
    const revision = "0123456789abcdef0123456789abcdef01234567";
    const imageId = `sha256:${"a".repeat(64)}`;

    const written = execFileSync(
      process.execPath,
      [stateTool, "write", stateFile, version!, digest!, updatedAtEpochMs!, revision, imageId],
      { encoding: "utf8" }
    );
    const read = execFileSync(process.execPath, [stateTool, "read", stateFile], { encoding: "utf8" });

    expect(written).toBe(`${version}|${digest}|${updatedAtEpochMs}|${revision}|${imageId}\n`);
    expect(read).toBe(written);
    expect(readFileSync(stateFile, "utf8")).toBe([
      "{",
      '  "schemaVersion": 1,',
      `  "version": ${version},`,
      `  "digest": "${digest}",`,
      `  "updatedAtEpochMs": ${updatedAtEpochMs},`,
      `  "revision": "${revision}",`,
      `  "imageId": "${imageId}"`,
      "}",
      ""
    ].join("\n"));
  });

  it("refuses a future-dated receipt without poisoning a later valid write", () => {
    const result = run([
      "write",
      stateFile,
      "5",
      "a".repeat(64),
      String(Date.now() + 6 * 60_000),
      "b".repeat(40),
      `sha256:${"c".repeat(64)}`
    ]);
    expect(result.status).toBe(66);
    expect(result.stderr).toContain("implausibly in the future");
    expect(run(["read", stateFile]).status).toBe(66);

    const validWrite = run([
      "write",
      stateFile,
      "6",
      "d".repeat(64),
      "1784505600000",
      "e".repeat(40),
      `sha256:${"f".repeat(64)}`
    ]);
    expect(validWrite.status).toBe(0);
    expect(run(["read", stateFile]).stdout).toBe(validWrite.stdout);
  });

  it("rejects insecure parent permissions before creating state", () => {
    chmodSync(privateDirectory, 0o750);
    const [, digest, updatedAtEpochMs] = fingerprint(validConfig()).split("|");
    const result = run([
      "write",
      stateFile,
      "5",
      digest!,
      updatedAtEpochMs!,
      "0123456789abcdef0123456789abcdef01234567",
      `sha256:${"a".repeat(64)}`
    ]);

    expect(result.status).toBe(66);
    expect(result.stderr).toContain("parent must be owner-owned and private");
  });

  it("rejects a private leaf nested below an untrusted writable ancestor", () => {
    const writableAncestor = join(temporaryDirectory, "writable-ancestor");
    mkdirSync(writableAncestor, { mode: 0o700 });
    chmodSync(writableAncestor, 0o777);
    const privateLeaf = join(writableAncestor, "private-leaf");
    mkdirSync(privateLeaf, { mode: 0o700 });

    const result = run(["validate", join(privateLeaf, "state.json")]);
    expect(result.status).toBe(66);
    expect(result.stderr).toContain("group/other-writable directory");
  });

  it("rejects a state target or path component that is a symbolic link", () => {
    const target = join(privateDirectory, "target.json");
    writeFileSync(target, "{}\n", { mode: 0o600 });
    symlinkSync(target, stateFile);
    const targetResult = run(["read", stateFile]);
    expect(targetResult.status).toBe(66);

    unlinkSync(stateFile);
    const realParent = join(temporaryDirectory, "real-parent");
    mkdirSync(realParent, { mode: 0o700 });
    const linkedParent = join(temporaryDirectory, "linked-parent");
    symlinkSync(realParent, linkedParent);
    const componentResult = run(["read", join(linkedParent, "state.json")]);
    expect(componentResult.status).toBe(66);
    expect(componentResult.stderr).toContain("symbolic link");
  });

  it("rejects noncanonical or broadly readable existing state", () => {
    const state = {
      schemaVersion: 1,
      version: 5,
      digest: "a".repeat(64),
      updatedAtEpochMs: 1_784_505_600_000,
      revision: "b".repeat(40),
      imageId: `sha256:${"c".repeat(64)}`
    };
    writeFileSync(stateFile, JSON.stringify(state), { mode: 0o600 });
    expect(run(["read", stateFile]).status).toBe(66);

    writeFileSync(stateFile, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
    chmodSync(stateFile, 0o644);
    expect(run(["read", stateFile]).status).toBe(66);
  });

  it("rejects a canonical existing receipt whose timestamp is in the future", () => {
    const state = {
      schemaVersion: 1,
      version: 5,
      digest: "a".repeat(64),
      updatedAtEpochMs: Date.now() + 6 * 60_000,
      revision: "b".repeat(40),
      imageId: `sha256:${"c".repeat(64)}`
    };
    writeFileSync(stateFile, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });

    const result = run(["read", stateFile]);
    expect(result.status).toBe(66);
    expect(result.stderr).toContain("implausibly in the future");
  });

  it("persists only monotonic, provenance-bound first-install phases", () => {
    const installFile = join(privateDirectory, "install-state.json");
    const revision = "d".repeat(40);
    const imageId = `sha256:${"e".repeat(64)}`;
    const volume = "address-atlas-prod-postgres";

    expect(run([
      "install-write", installFile, "candidate-ready", revision, imageId, volume
    ]).status).toBe(0);
    expect(run(["install-read", installFile]).stdout.trim()).toBe(
      `candidate-ready|${revision}|${imageId}|${volume}`
    );
    expect(run([
      "install-write", installFile, "roles-ready", revision, imageId, volume
    ]).status).toBe(67);
    expect(run([
      "install-write", installFile, "schema-ready", revision, imageId, volume
    ]).status).toBe(0);
    expect(run([
      "install-write", installFile, "roles-ready", revision, imageId, volume
    ]).status).toBe(0);
    expect(run([
      "install-write", installFile, "roles-ready", revision, `sha256:${"f".repeat(64)}`, volume
    ]).status).toBe(67);
    expect(run([
      "install-delete", installFile, revision, imageId, "wrong-volume"
    ]).status).toBe(67);
    expect(run([
      "install-delete", installFile, revision, imageId, volume
    ]).status).toBe(0);
    expect(run(["install-read", installFile]).status).toBe(66);
  });

  function fingerprint(config: unknown) {
    return execFileSync(process.execPath, [stateTool, "fingerprint"], {
      encoding: "utf8",
      input: JSON.stringify(config)
    }).trim();
  }

  function run(args: string[], input?: string) {
    return spawnSync(process.execPath, [stateTool, ...args], { encoding: "utf8", input });
  }
});

function validConfig(): Record<string, unknown> {
  return {
    schemaVersion: 1,
    configVersion: 5,
    updatedAt: "2026-07-20T00:00:00.000Z",
    refreshAfterSeconds: 21_600,
    minSupportedAppVersion: "0.2.0",
    priceBaseUrl: "https://api.coingecko.com/api/v3/simple/price",
    chains: {
      bitcoin: { restUrl: "https://blockstream.info/api" },
      ethereum: { rpcUrl: "https://ethereum-rpc.publicnode.com" }
    },
    exchanges: {}
  };
}

function reverseObjectKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(reverseObjectKeys);
  if (value === null || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .reverse()
      .map(([key, nested]) => [key, reverseObjectKeys(nested)])
  );
}
