import { chmodSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

const repoRoot = resolve(import.meta.dirname, "../../..");
const hook = join(repoRoot, "server/sync/provision-restored-database.sh");
const provisionScript = join(repoRoot, "server/sync/provision-runtime-role.sh");
const bootstrapScript = join(repoRoot, "server/sync/bootstrap-database-roles.sh");
const provisionImage = "postgres:16.14-alpine3.24@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777";
const imageId = `sha256:${"d".repeat(64)}`;

describe("restored database privilege provision hook", () => {
  let directory: string;
  let fakeDocker: string;
  let invocationLog: string;

  beforeEach(() => {
    directory = realpathSync(mkdtempSync(join(tmpdir(), "address-atlas-restore-provision-")));
    fakeDocker = join(directory, "docker");
    invocationLog = join(directory, "docker-run-args");
    writeFileSync(fakeDocker, `#!/bin/sh
set -eu
case "\${1:-}:\${2:-}" in
  image:inspect) printf '%s\\n' "$FAKE_IMAGE_ID" ;;
  inspect:--format) printf '%s\\n' true ;;
  run:*) printf '%s\\n' "$@" > "$FAKE_INVOCATION_LOG" ;;
  *) exit 70 ;;
esac
`, { mode: 0o700 });
    chmodSync(fakeDocker, 0o700);
  });

  afterEach(() => {
    rmSync(directory, { recursive: true, force: true });
  });

  it("uses a private script snapshot and immutable image to restore ACLs before LOGIN", () => {
    const result = run();
    expect(result.status).toBe(0);
    const args = readFileSync(invocationLog, "utf8").split("\n");

    expect(args).toContain(imageId);
    expect(args).not.toContain(provisionImage);
    expect(args).toContain("ADDRESS_ATLAS_DATABASE_ROLE_MODE=restore");
    expect(args).toContain("POSTGRES_DB=address_atlas_sync");
    expect(args).toContain("POSTGRES_ADMIN_PASSWORD");
    expect(args).toContain("POSTGRES_RUNTIME_PASSWORD");
    expect(args.join(" ")).not.toContain("admin_restore_4Rx8Lm2Qs7Vz9Tr5Nc6Hw3Kp1Jf0Yb");
    expect(args.join(" ")).not.toContain("runtime_restore_7MdkP2Yw4Jq9Vs8Nx3Fb6Lc1Hr5Tz0Qa");
    expect(args).toContain("--read-only");
    expect(args).toContain("--cap-drop");
    expect(args).toContain("ALL");
    const volume = args[args.indexOf("--volume") + 1] ?? "";
    expect(volume).toMatch(/address-atlas-restore-provision\.[^/]+\/provision-runtime-role\.sh:\/opt\/address-atlas\/provision-runtime-role\.sh:ro$/);
    expect(volume).not.toContain(provisionScript);
  });

  it("rejects any restore provision image outside the reviewed digest", () => {
    const result = run({ ADDRESS_ATLAS_RESTORE_PROVISION_IMAGE: "postgres:latest" });
    expect(result.status).toBe(65);
    expect(result.stderr).toContain("reviewed immutable PostgreSQL image");
  });

  it("uses side-effect-bounded convergence for an isolated drill database", () => {
    const result = run({ ADDRESS_ATLAS_RESTORE_PROVISION_MODE: "drill" });
    expect(result.status).toBe(0);
    expect(readFileSync(invocationLog, "utf8"))
      .toContain("ADDRESS_ATLAS_DATABASE_ROLE_MODE=drill");
  });

  it("snapshots the one-time role split and transports the owner secret outside argv", () => {
    const ownerPassword = "owner_restore_6Hd9Tm4Qs2Vz8Nr5Kc7Wp3Lf1Jx0YbGa";
    const result = run({
      ADDRESS_ATLAS_RESTORE_PROVISION_MODE: "bootstrap",
      POSTGRES_PASSWORD: ownerPassword
    });
    expect(result.status).toBe(0);
    const args = readFileSync(invocationLog, "utf8").split("\n");

    expect(args).toContain("ADDRESS_ATLAS_DATABASE_ROLE_MODE=bootstrap");
    expect(args).toContain("POSTGRES_PASSWORD");
    expect(args.join(" ")).not.toContain(ownerPassword);
    const volumes = args.flatMap((argument, index) =>
      argument === "--volume" ? [args[index + 1] ?? ""] : []
    );
    expect(volumes).toHaveLength(2);
    expect(volumes).toEqual(expect.arrayContaining([
      expect.stringMatching(/address-atlas-restore-provision\.[^/]+\/provision-runtime-role\.sh:\/opt\/address-atlas\/provision-runtime-role\.sh:ro$/),
      expect.stringMatching(/address-atlas-restore-provision\.[^/]+\/bootstrap-database-roles\.sh:\/opt\/address-atlas\/bootstrap-database-roles\.sh:ro$/)
    ]));
    expect(volumes.join(" ")).not.toContain(provisionScript);
    expect(volumes.join(" ")).not.toContain(bootstrapScript);
  });

  function run(overrides: Record<string, string> = {}) {
    return spawnSync("sh", [hook, "postgres-production", "address_atlas_sync"], {
      encoding: "utf8",
      env: { ...environment(), ...overrides }
    });
  }

  function environment(): NodeJS.ProcessEnv {
    return {
      ...process.env,
      DOCKER_BIN: fakeDocker,
      ADDRESS_ATLAS_RESTORE_PROVISION_IMAGE: provisionImage,
      ADDRESS_ATLAS_RESTORE_PROVISION_MODE: "restore",
      POSTGRES_ADMIN_PASSWORD: "admin_restore_4Rx8Lm2Qs7Vz9Tr5Nc6Hw3Kp1Jf0Yb",
      POSTGRES_RUNTIME_PASSWORD: "runtime_restore_7MdkP2Yw4Jq9Vs8Nx3Fb6Lc1Hr5Tz0Qa",
      ADDRESS_ATLAS_RESTORE_STAGING_ROOT: directory,
      FAKE_IMAGE_ID: imageId,
      FAKE_INVOCATION_LOG: invocationLog,
      TMPDIR: directory
    };
  }
});
