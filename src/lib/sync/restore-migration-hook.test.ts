import { chmodSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

const repoRoot = resolve(import.meta.dirname, "../../..");
const hook = join(repoRoot, "server/sync/migrate-restored-database.sh");
const revision = "a".repeat(40);
const imageId = `sha256:${"b".repeat(64)}`;

describe("restored database migration hook", () => {
  let directory: string;
  let fakeDocker: string;
  let invocationLog: string;

  beforeEach(() => {
    directory = realpathSync(mkdtempSync(join(tmpdir(), "address-atlas-restore-hook-")));
    fakeDocker = join(directory, "docker");
    invocationLog = join(directory, "docker-run-args");
    writeFileSync(fakeDocker, `#!/bin/sh
set -eu
case "\${1:-}:\${2:-}" in
  image:inspect)
    printf '%s|%s\\n' "$FAKE_IMAGE_ID" "$FAKE_IMAGE_REVISION"
    ;;
  inspect:--format)
    printf '%s\\n' true
    ;;
  run:*)
    printf '%s\\n' "$@" > "$FAKE_INVOCATION_LOG"
    ;;
  *)
    exit 70
    ;;
esac
`, { mode: 0o700 });
    chmodSync(fakeDocker, 0o700);
  });

  afterEach(() => {
    rmSync(directory, { recursive: true, force: true });
  });

  it("runs only the inspected immutable image with a locked-down owner connection", () => {
    const result = run();
    expect(result.status).toBe(0);
    const args = readFileSync(invocationLog, "utf8").split("\n");

    expect(args).toContain(imageId);
    expect(args).not.toContain(`address-atlas-sync:${revision}`);
    expect(args).toContain("--network");
    expect(args).toContain("container:postgres-production");
    expect(args).toContain("--read-only");
    expect(args).toContain("--cap-drop");
    expect(args).toContain("ALL");
    expect(args).toContain("--security-opt");
    expect(args).toContain("no-new-privileges:true");
    expect(args).toContain("node");
    expect(args).toContain("dist/sync-restore.cjs");
    expect(args).toContain("SYNC_SCHEMA_DATABASE_URL");
    expect(args).toContain("ADDRESS_ATLAS_RESTORE_MIGRATION=1");
    expect(args.join(" ")).not.toContain("owner_6Vr2Kx8Qm4Np7Ts9Lc3Hw5Jf1Zd0By8Ua");
    const hookSource = readFileSync(hook, "utf8");
    expect(hookSource).not.toContain("?options=");
    expect(hookSource).toContain(
      'database_url="postgresql://address_atlas:${owner_password}@127.0.0.1:5432/${database}"'
    );
  });

  it("fails closed on mutable-tag provenance drift", () => {
    const result = run({ FAKE_IMAGE_REVISION: "c".repeat(40) });
    expect(result.status).toBe(67);
    expect(result.stderr).toContain("provenance does not match");
  });

  it("rejects malformed input before invoking Docker", () => {
    const result = spawnSync("sh", [hook, "postgres/unsafe", "address_atlas_sync", "1", "3"], {
      encoding: "utf8",
      env: environment()
    });
    expect(result.status).toBe(65);
    expect(() => readFileSync(invocationLog, "utf8")).toThrow();
  });

  it("rejects a valid-looking database outside the isolated restore prefixes", () => {
    const result = spawnSync("sh", [hook, "postgres-production", "customer_database", "1", "3"], {
      encoding: "utf8",
      env: environment()
    });
    expect(result.status).toBe(65);
    expect(result.stderr).toContain("isolated migration contract");
    expect(() => readFileSync(invocationLog, "utf8")).toThrow();
  });

  function run(overrides: Record<string, string> = {}) {
    return spawnSync("sh", [hook, "postgres-production", "atlas_restore_test1", "1", "3"], {
      encoding: "utf8",
      env: { ...environment(), ...overrides }
    });
  }

  function environment(): NodeJS.ProcessEnv {
    return {
      ...process.env,
      DOCKER_BIN: fakeDocker,
      ADDRESS_ATLAS_RESTORE_IMAGE: `address-atlas-sync:${revision}`,
      ADDRESS_ATLAS_RESTORE_BUILD_REVISION: revision,
      POSTGRES_PASSWORD: "owner_6Vr2Kx8Qm4Np7Ts9Lc3Hw5Jf1Zd0By8Ua",
      FAKE_IMAGE_ID: imageId,
      FAKE_IMAGE_REVISION: revision,
      FAKE_INVOCATION_LOG: invocationLog
    };
  }
});
