import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";

const repoRoot = resolve(import.meta.dirname, "../../..");
const workflow = readFileSync(join(repoRoot, ".github/workflows/release.yml"), "utf8");

describe("macOS release workflow governance", () => {
  it("binds protected release secrets and live policy to the exact source commit", () => {
    expect(workflow).toContain("environment: release");
    expect(workflow).toContain("PRODUCTION_SYNC_ORIGIN: ${{ vars.ADDRESS_ATLAS_PRODUCTION_ORIGIN }}");
    expect(workflow).toContain("SOURCE_COMMIT: ${{ steps.release.outputs.source_commit }}");
    expect(workflow.match(/scripts\/verify-live-native-config\.sh/g)?.length).toBeGreaterThanOrEqual(2);
    expect(workflow).toContain('"$SOURCE_COMMIT"');
    expect(workflow).toContain("node-version-file: .nvmrc");
    expect(workflow).toContain("actions/setup-node@48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e");
  });

  it("requires immutable releases, governed main, and create/update/delete-protected tags", () => {
    expect(workflow.match(/immutable-releases/g)?.length).toBeGreaterThanOrEqual(2);
    for (const rule of [
      'has_rule("creation")',
      'has_rule("update")',
      'has_rule("deletion")',
      'has_rule("non_fast_forward")',
      'has_rule("required_linear_history")'
    ]) {
      expect(workflow).toContain(rule);
    }
    expect(workflow).toContain("strict_required_status_checks_policy == true");
    expect(workflow).toContain("required_review_thread_resolution == true");
  });

  it("publishes once and verifies immutable release plus asset attestations", () => {
    expect(workflow).toContain("generate_release_notes: true");
    expect(workflow).toContain('make_latest: "legacy"');
    expect(workflow).toContain(".immutable == true");
    expect(workflow).toContain("Verify immutable release and asset attestations");
    expect(workflow).toContain("gh release verify \"$RELEASE_TAG\"");
    expect(workflow).toContain("gh release verify-asset \"$RELEASE_TAG\"");
    expect(workflow).toContain("gh release verify --help");
    expect(workflow).toContain("gh release verify-asset --help");
    expect(workflow).toContain("A draft or published GitHub Release already exists");
  });
});
