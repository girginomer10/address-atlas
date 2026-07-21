import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";
import {
  validatePasskeyCredentialId,
  validatePasskeyPublicKey
} from "./stored-passkey-credential";

const repoRoot = resolve(import.meta.dirname, "../../..");
const workflow = readFileSync(join(repoRoot, ".github/workflows/ci.yml"), "utf8").replace(
  /\r\n/g,
  "\n"
);
const recoveryStepStart = workflow.indexOf(
  "- name: Prove destructive fresh-volume PostgreSQL bootstrap recovery"
);
const recoveryStepEnd = workflow.indexOf(
  "- name: Remove CI recovery containers and volumes",
  recoveryStepStart
);

expect(recoveryStepStart).toBeGreaterThanOrEqual(0);
expect(recoveryStepEnd).toBeGreaterThan(recoveryStepStart);

const recoveryStep = workflow.slice(recoveryStepStart, recoveryStepEnd);
const backupStepStart = workflow.indexOf(
  "- name: Prove encrypted backup, drill, and atomic production restore"
);
const backupStepEnd = workflow.indexOf(
  "- name: Prove destructive fresh-volume PostgreSQL bootstrap recovery",
  backupStepStart
);

expect(backupStepStart).toBeGreaterThanOrEqual(0);
expect(backupStepEnd).toBeGreaterThan(backupStepStart);

const backupStep = workflow.slice(backupStepStart, backupStepEnd);

describe("CI recovery workflow contract", () => {
  it("seeds a credential that restore readiness can cryptographically import", () => {
    const credentialSeed = backupStep.match(
      /INSERT INTO public\.passkey_credentials \([\s\S]*?\) VALUES \(\s*'([^']+)',\s*'[^']+',\s*'([^']+)'/
    );

    expect(credentialSeed).not.toBeNull();
    expect(() => validatePasskeyCredentialId(credentialSeed?.[1])).not.toThrow();
    expect(() => validatePasskeyPublicKey(credentialSeed?.[2])).not.toThrow();
  });

  it("binds verification to the source and recovery to the fresh target", () => {
    const sourceBinding = recoveryStep.indexOf(
      'export ADDRESS_ATLAS_POSTGRES_CONTAINER="$SOURCE_POSTGRES_CONTAINER"'
    );
    const artifactInspection = recoveryStep.indexOf(
      'metadata="$(bash "$backup_script" inspect "$backup")"'
    );
    const sourceRemoval = recoveryStep.indexOf(
      'docker rm --force "$SOURCE_POSTGRES_CONTAINER"'
    );
    const targetBinding = recoveryStep.indexOf(
      'export ADDRESS_ATLAS_POSTGRES_CONTAINER="$TARGET_POSTGRES_CONTAINER"'
    );
    const targetClassification = recoveryStep.indexOf(
      '"$(bash "$backup_script" classify-source)" == brand-new-empty'
    );

    expect(sourceBinding).toBeGreaterThanOrEqual(0);
    expect(artifactInspection).toBeGreaterThan(sourceBinding);
    expect(sourceRemoval).toBeGreaterThan(artifactInspection);
    expect(targetBinding).toBeGreaterThan(sourceRemoval);
    expect(targetClassification).toBeGreaterThan(targetBinding);
  });

  it("waits for the final PostgreSQL PID 1 instead of the transient init server", () => {
    const pidOneRead = recoveryStep.indexOf(
      "read -r pid_one_command < /proc/1/comm"
    );
    const finalPostgresCheck = recoveryStep.indexOf(
      '[ "$pid_one_command" = postgres ]'
    );
    const readinessProbe = recoveryStep.indexOf(
      "exec pg_isready --host 127.0.0.1 --username address_atlas"
    );
    const targetBinding = recoveryStep.indexOf(
      'export ADDRESS_ATLAS_POSTGRES_CONTAINER="$TARGET_POSTGRES_CONTAINER"'
    );

    expect(pidOneRead).toBeGreaterThanOrEqual(0);
    expect(finalPostgresCheck).toBeGreaterThan(pidOneRead);
    expect(readinessProbe).toBeGreaterThan(finalPostgresCheck);
    expect(targetBinding).toBeGreaterThan(readinessProbe);
  });

  it("makes the CI service healthcheck wait for final PID 1 and TCP", () => {
    expect(workflow).toContain(
      '--health-cmd "grep -qx postgres /proc/1/comm && pg_isready -h 127.0.0.1 -U address_atlas -d address_atlas_sync"'
    );
  });

  it("keeps the embedded recovery shell syntactically valid after YAML dedent", () => {
    const runMarker = "\n        run: |\n";
    const runBlockStart = recoveryStep.indexOf(runMarker);
    expect(runBlockStart).toBeGreaterThanOrEqual(0);

    const yamlRunBlock = `${recoveryStep
      .slice(runBlockStart + runMarker.length)
      .trimEnd()}\n`;
    expect(yamlRunBlock.match(/^ {14}cat <<'SQL'$/gm)).toHaveLength(2);
    expect(yamlRunBlock.match(/^ {10}SQL$/gm)).toHaveLength(2);

    const shellScript = yamlRunBlock.replace(/^ {10}/gm, "");
    const syntaxCheck = spawnSync("bash", ["-n"], {
      encoding: "utf8",
      input: shellScript,
    });

    expect(syntaxCheck.error).toBeUndefined();
    expect(syntaxCheck.stderr).toBe("");
    expect(syntaxCheck.status).toBe(0);
  });

  it("requests an uncached revision-bound native-config receipt", () => {
    expect(recoveryStep).toContain(
      '"http://127.0.0.1:3000/config/native?deployment_probe=${CI_NATIVE_REVISION}"'
    );
  });
});
