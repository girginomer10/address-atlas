import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

const repoRoot = resolve(import.meta.dirname, "../../..");
const verifier = join(repoRoot, "scripts/verify-live-native-config.sh");
const stateTool = join(repoRoot, "server/sync/native-config-deploy-state.mjs");
const sourceCommit = "c".repeat(40);
const serverRevision = sourceCommit;

describe("live production native-config release binding", () => {
  let directory: string;
  let fakeCurl: string;
  let body: string;
  let digest: string;

  beforeEach(() => {
    directory = realpathSync(mkdtempSync(join(tmpdir(), "address-atlas-live-release-")));
    body = JSON.stringify(validConfig());
    digest = execFileSync(process.execPath, [stateTool, "fingerprint"], {
      encoding: "utf8",
      input: body
    }).trim().split("|")[1]!;
    fakeCurl = join(directory, "curl");
    writeFileSync(fakeCurl, `#!/bin/sh
[ -z "\${FAKE_CURL_CALLED:-}" ] || printf '%s' called > "$FAKE_CURL_CALLED"
headers=''
output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dump-header) shift; headers="$1" ;;
    --output) shift; output="$1" ;;
  esac
  shift
done
[ -n "$headers" ] && [ -n "$output" ] || exit 70
printf '%s' "$FAKE_BODY" > "$output"
printf '%s\\r\\n' \\
  'HTTP/2 200' \\
  'content-type: application/json; charset=utf-8' \\
  'cache-control: no-store' \\
  "etag: \\"sha256-$FAKE_DIGEST\\"" \\
  "x-address-atlas-build-revision: $FAKE_REVISION" \\
  '' > "$headers"
`);
    chmodSync(fakeCurl, 0o755);
  });

  afterEach(() => {
    rmSync(directory, { recursive: true, force: true });
  });

  it("binds compatible policy, exact digest, and reviewed server ancestry", () => {
    const result = run();
    expect(result.status).toBe(0);
    expect(result.stdout.trim()).toBe(`5|${digest}|1784505600000|${serverRevision}`);
  });

  it("requires the exact previously approved binding on later release checks", () => {
    const expected = `5|${digest}|1784505600000|${serverRevision}`;
    expect(run(expected).status).toBe(0);
    expect(run(`${expected}-changed`).status).toBe(67);
  });

  it("rejects incompatible policy, response receipt drift, and unreviewed server ancestry", () => {
    const incompatible = validConfig();
    incompatible.minSupportedAppVersion = "0.3.0";
    expect(run(undefined, { FAKE_BODY: JSON.stringify(incompatible) }).status).toBe(67);
    expect(run(undefined, { FAKE_DIGEST: "b".repeat(64) }).status).toBe(67);
    expect(run(undefined, { FAKE_REVISION: "a".repeat(40) }).status).toBe(67);
  });

  it("rejects a noncanonical origin before making a request", () => {
    const result = spawnSync("bash", [
      verifier,
      "https://sync.example.test/path",
      "0.2.0",
      "5",
      sourceCommit,
      "probe"
    ], { encoding: "utf8", env: environment() });

    expect(result.status).toBe(65);
    expect(result.stderr).toContain("must be exactly https://<hostname>");
    expect(() => readFileSync(join(directory, "curl-called"), "utf8")).toThrow();
  });

  function run(expected?: string, extra: Record<string, string> = {}) {
    const args = [
      verifier,
      "https://sync.example.test",
      "0.2.0",
      "5",
      sourceCommit,
      "release-probe"
    ];
    if (expected !== undefined) args.push(expected);
    return spawnSync("bash", args, {
      encoding: "utf8",
      env: { ...environment(), ...extra }
    });
  }

  function environment(): NodeJS.ProcessEnv {
    return {
      ...process.env,
      CURL_BIN: fakeCurl,
      NODE_BIN: process.execPath,
      RUNNER_TEMP: directory,
      FAKE_CURL_CALLED: join(directory, "curl-called"),
      FAKE_BODY: body,
      FAKE_DIGEST: digest,
      FAKE_REVISION: serverRevision
    };
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
    chains: { bitcoin: { restUrl: "https://blockstream.info/api" } },
    exchanges: {}
  };
}
