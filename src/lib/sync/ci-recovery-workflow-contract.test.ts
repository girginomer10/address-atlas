import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";

const repoRoot = resolve(import.meta.dirname, "../../..");
const workflow = readFileSync(join(repoRoot, ".github/workflows/ci.yml"), "utf8");

describe("CI recovery workflow contract", () => {
  it("binds verification to the source and recovery to the fresh target", () => {
    const start = workflow.indexOf(
      "- name: Prove destructive fresh-volume PostgreSQL bootstrap recovery"
    );
    const end = workflow.indexOf("- name: Remove CI recovery containers and volumes", start);
    expect(start).toBeGreaterThanOrEqual(0);
    expect(end).toBeGreaterThan(start);
    const recoveryStep = workflow.slice(start, end);

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
});
