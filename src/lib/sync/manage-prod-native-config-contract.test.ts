import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";

const repoRoot = resolve(import.meta.dirname, "../../..");
const manageProd = readFileSync(join(repoRoot, "server/sync/manage-prod.sh"), "utf8");

describe("manage-prod native-config version authority", () => {
  it("allows a higher configVersion even when its real timestamp is lower", () => {
    const result = runFunction("validate_candidate_native_config_transition", `
BASELINE_CONFIG_VERSION=5
BASELINE_CONFIG_DIGEST=${"a".repeat(64)}
BASELINE_CONFIG_UPDATED_AT_MS=1784563200000
CANDIDATE_CONFIG_VERSION=6
CANDIDATE_CONFIG_DIGEST=${"b".repeat(64)}
CANDIDATE_CONFIG_UPDATED_AT_MS=1784505600000
APPROVED_CONFIG_VERSION=
APPROVED_CONFIG_DIGEST=
APPROVED_CONFIG_UPDATED_AT_MS=
validate_candidate_native_config_transition false
printf '%s|%s|%s\n' "$APPROVED_CONFIG_VERSION" "$APPROVED_CONFIG_DIGEST" "$APPROVED_CONFIG_UPDATED_AT_MS"
`);

    expect(result.status).toBe(0);
    expect(result.stdout.trim()).toBe(`6|${"b".repeat(64)}|1784505600000`);
  });

  it("rejects a changed digest or timestamp at the same configVersion", () => {
    for (const [candidateDigest, candidateTimestamp] of [
      ["b".repeat(64), "1784505600000"],
      ["a".repeat(64), "1784563200000"]
    ]) {
      const result = runFunction("validate_candidate_native_config_transition", `
BASELINE_CONFIG_VERSION=5
BASELINE_CONFIG_DIGEST=${"a".repeat(64)}
BASELINE_CONFIG_UPDATED_AT_MS=1784505600000
CANDIDATE_CONFIG_VERSION=5
CANDIDATE_CONFIG_DIGEST=${candidateDigest}
CANDIDATE_CONFIG_UPDATED_AT_MS=${candidateTimestamp}
APPROVED_CONFIG_VERSION=
APPROVED_CONFIG_DIGEST=
APPROVED_CONFIG_UPDATED_AT_MS=
validate_candidate_native_config_transition false
`);

      expect(result.status).toBe(67);
      expect(result.stderr).toContain("bound policy identity");
    }
  });

  it("selects the higher-version signed baseline without timestamp ordering", () => {
    const result = runFunction("merge_signed_backup_native_config_baseline", `
BASELINE_CONFIG_VERSION=5
BASELINE_CONFIG_DIGEST=${"a".repeat(64)}
BASELINE_CONFIG_UPDATED_AT_MS=1784563200000
BASELINE_CONFIG_REVISION=${"c".repeat(40)}
BASELINE_CONFIG_IMAGE_ID=sha256:${"d".repeat(64)}
merge_signed_backup_native_config_baseline 6 ${"b".repeat(64)} 1784505600000 ${"e".repeat(40)} sha256:${"f".repeat(64)}
printf '%s|%s|%s\n' "$BASELINE_CONFIG_VERSION" "$BASELINE_CONFIG_DIGEST" "$BASELINE_CONFIG_UPDATED_AT_MS"
`);

    expect(result.status).toBe(0);
    expect(result.stdout.trim()).toBe(`6|${"b".repeat(64)}|1784505600000`);
  });

  it("rejects a conflicting signed backup identity at the same configVersion", () => {
    const result = runFunction("merge_signed_backup_native_config_baseline", `
BASELINE_CONFIG_VERSION=5
BASELINE_CONFIG_DIGEST=${"a".repeat(64)}
BASELINE_CONFIG_UPDATED_AT_MS=1784505600000
BASELINE_CONFIG_REVISION=${"c".repeat(40)}
BASELINE_CONFIG_IMAGE_ID=sha256:${"d".repeat(64)}
merge_signed_backup_native_config_baseline 5 ${"a".repeat(64)} 1784563200000 ${"e".repeat(40)} sha256:${"f".repeat(64)}
`);

    expect(result.status).toBe(67);
    expect(result.stderr).toContain("conflict at one version");
  });
});

function runFunction(name: string, body: string) {
  const functionSource = extractFunction(name);
  return spawnSync("/bin/bash", ["-c", `set -euo pipefail\n${functionSource}\n${body}`], {
    encoding: "utf8"
  });
}

function extractFunction(name: string) {
  const start = manageProd.indexOf(`${name}() {`);
  if (start < 0) throw new Error(`Missing shell function ${name}`);
  const end = manageProd.indexOf("\n}\n", start);
  if (end < 0) throw new Error(`Unterminated shell function ${name}`);
  return manageProd.slice(start, end + 3);
}
