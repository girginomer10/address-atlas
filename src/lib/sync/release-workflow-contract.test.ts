import { spawnSync } from "node:child_process";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";

const repoRoot = resolve(import.meta.dirname, "../../..");
const workflow = readFileSync(join(repoRoot, ".github/workflows/release.yml"), "utf8");
const ciWorkflow = readFileSync(join(repoRoot, ".github/workflows/ci.yml"), "utf8");
const commitSha = "a".repeat(40);
const requiredChecks = [
  "Repository secret-artifact hygiene",
  "Web and sync server",
  "Native macOS package",
  "Deployment configuration"
];

const runSelectorProgram = `
[
  .workflow_runs[]?
  | select(
      .head_sha == $sha
      and .event == "push"
      and (.id | type == "number" and . > 0)
      and (.run_attempt | type == "number" and . > 0)
    )
]
| sort_by([.id, .run_attempt])
| last
| select(
    type == "object"
    and .status == "completed"
    and .conclusion == "success"
  )
`;

const jobsProgram = `
[ .[].jobs[]? ] as $jobs
| all(
    $required_checks[];
    . as $required
    | [ $jobs[] | select(.name == $required) ] as $matching
    | ($matching | length) == 1
      and $matching[0].run_id == $run_id
      and $matching[0].head_sha == $sha
      and $matching[0].status == "completed"
      and $matching[0].conclusion == "success"
      and ($matching[0].check_run_url | type == "string")
  )
`;

const checkRunsProgram = `
. as $check_runs
| if (
  ($check_runs | length) == ($required_checks | length)
  and all(
    $required_checks[];
    . as $required
    | [ $check_runs[] | select(.name == $required) ]
    | length == 1
  )
  and all(
    $check_runs[];
    (.id | type == "number" and . > 0)
    and .head_sha == $sha
    and .status == "completed"
    and .conclusion == "success"
    and (.app.id | type == "number" and . > 0)
  )
  and ([ $check_runs[].app.id ] | unique | length == 1)
)
then [ $check_runs[].app.id ] | unique | .[0]
else empty
end
`;

const checkRunResponseProgram = `
.id == $expected_id
and .name == $expected_name
and .head_sha == $sha
and .status == "completed"
and .conclusion == "success"
and .app.id == $expected_app
`;

const rulesetIntegrationProgram = `
.parameters.required_status_checks as $configured
| all(
    $required_checks[];
    . as $required
    | [
        $configured[]?
        | select(.context == $required)
      ] as $matching
    | ($matching | length) == 1
      and $matching[0].integration_id == $ci_integration_id
  )
`;

describe("macOS release workflow governance", () => {
  it("binds protected release secrets and live policy to the exact source commit", () => {
    expect(workflow).toContain("environment: release");
    expect(workflow).toContain("PRODUCTION_SYNC_ORIGIN: ${{ vars.ADDRESS_ATLAS_PRODUCTION_ORIGIN }}");
    expect(workflow).toContain("SOURCE_COMMIT: ${{ steps.release.outputs.source_commit }}");
    expect(workflow.match(/scripts\/verify-live-native-config\.sh/g)?.length).toBeGreaterThanOrEqual(2);
    expect(workflow).toContain('"$SOURCE_COMMIT"');
    expect(workflow).toContain("node-version-file: .nvmrc");
    expect(workflow).toContain("actions/setup-node@48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e");
    expect(workflow).toContain(
      "swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors"
    );
    expect(ciWorkflow).toContain(
      "swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors"
    );
    expect(workflow.match(/checks: read/g)?.length).toBe(2);
    expect(workflow).toContain([
      "permissions:",
      "  actions: read",
      "  attestations: read",
      "  checks: read",
      "  contents: write"
    ].join("\n"));
    expect(workflow).toContain([
      "    permissions:",
      "      actions: read",
      "      attestations: read",
      "      checks: read",
      "      contents: write"
    ].join("\n"));
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
    expect(workflow).toContain("ci-check-run-urls.txt");
    expect(workflow).toContain("check_run_url");
    expect(workflow).toContain("[ $check_runs[].app.id ] | unique | length == 1");
    expect(workflow).toContain('echo "ci_integration_id=$ci_integration_id" >> "$GITHUB_OUTPUT"');
    expect(workflow).toContain("CI_INTEGRATION_ID: ${{ steps.release.outputs.ci_integration_id }}");
    expect(workflow).toContain("CI_RUN_ID: ${{ steps.release.outputs.ci_run_id }}");
    expect(workflow).toContain("CI_RUN_ATTEMPT: ${{ steps.release.outputs.ci_run_attempt }}");
    expect(workflow).toContain("CI_CHECK_RUN_IDS: ${{ steps.release.outputs.ci_check_run_ids }}");
    expect(workflow).toContain("CI_CHECK_RUN_URLS: ${{ steps.release.outputs.ci_check_run_urls }}");
    for (const output of [
      "ci_run_id=$ci_run_id",
      "ci_run_attempt=$ci_run_attempt",
      "ci_integration_id=$ci_integration_id",
      "ci_check_run_ids=$ci_check_run_ids",
      "ci_check_run_urls=$ci_check_run_urls"
    ]) {
      expect(workflow).toContain(`echo "${output}" >> "$GITHUB_OUTPUT"`);
    }
    expect(workflow).toContain("release_ci_is_intact || {");
    expect(workflow.match(/latest_ci_run_matches_preflight \\/g)?.length).toBe(2);
    expect(workflow.match(/\.integration_id == \$ci_integration_id/g)?.length).toBe(2);
    expect(workflow).not.toContain('select(.integration_id | type == "number" and . > 0)');
  });

  it("rejects a missing run, failed latest attempt, or successful rerun drift", () => {
    expect(compactOccurrences(workflow, runSelectorProgram)).toBe(2);
    const identityFunction = extractWorkflowShellFunction("selected_ci_run_matches_preflight");
    const successful = workflowRun({ id: 100, run_attempt: 1 });
    const accepted = runJq(runSelectorProgram, { workflow_runs: [successful] }, [
      "--arg", "sha", commitSha
    ]);
    expect(accepted.status).toBe(0);
    expect(JSON.parse(accepted.stdout)).toMatchObject({ id: 100, run_attempt: 1 });
    expect(runSelectedCiRunFunction(identityFunction, successful).status).toBe(0);
    expect(runJq(runSelectorProgram, { workflow_runs: [] }, [
      "--arg", "sha", commitSha
    ]).status).not.toBe(0);

    const failedLatestAttempt = workflowRun({
      id: 100,
      run_attempt: 2,
      conclusion: "failure"
    });
    const rejected = runJq(
      runSelectorProgram,
      { workflow_runs: [successful, failedLatestAttempt] },
      ["--arg", "sha", commitSha]
    );
    expect(rejected.status).not.toBe(0);

    const successfulRerun = workflowRun({ id: 100, run_attempt: 2 });
    const rerunSelection = runJq(
      runSelectorProgram,
      { workflow_runs: [successful, successfulRerun] },
      ["--arg", "sha", commitSha]
    );
    expect(rerunSelection.status).toBe(0);
    expect(runSelectedCiRunFunction(identityFunction, successfulRerun).status).not.toBe(0);
  });

  it("rejects missing, duplicate, or failed jobs in the selected CI attempt", () => {
    expect(compactOccurrences(workflow, jobsProgram)).toBe(2);
    const jobs = requiredChecks.map((name, index) => workflowJob(name, index + 1));
    expect(runJobsJq(jobs).status).toBe(0);

    const invalidJobSets = [
      jobs.slice(0, -1),
      [jobs[0], { ...jobs[0], check_run_url: checkRunUrl(99) }, ...jobs.slice(1)],
      jobs.map((job, index) => index === 2 ? { ...job, conclusion: "failure" } : job)
    ];
    for (const invalidJobs of invalidJobSets) {
      expect(runJobsJq(invalidJobs).status).not.toBe(0);
    }
  });

  it("rejects missing, duplicate, failed, or cross-app check runs", () => {
    expect(compactOccurrences(workflow, checkRunsProgram)).toBe(2);
    const checks = requiredChecks.map((name, index) => workflowCheck(name, index + 1));
    const accepted = runChecksJq(checks);
    expect(accepted.status).toBe(0);
    expect(accepted.stdout.trim()).toBe("15368");

    const invalidCheckSets = [
      checks.slice(0, -1),
      [checks[0], { ...checks[0], id: 99 }, checks[1], checks[2]],
      checks.map((check, index) => index === 1 ? { ...check, conclusion: "failure" } : check),
      checks.map((check, index) => index === 3 ? { ...check, app: { id: 999 } } : check)
    ];
    for (const invalidChecks of invalidCheckSets) {
      expect(runChecksJq(invalidChecks).status).not.toBe(0);
    }
  });

  it("rejects check-response IDs or sorted check-run bindings that drift after preflight", () => {
    expect(compact(workflow)).toContain(compact(checkRunResponseProgram));
    const check = workflowCheck(requiredChecks[0]!, 1);
    const args = [
      "--argjson", "expected_id", "1",
      "--arg", "expected_name", requiredChecks[0]!,
      "--arg", "sha", commitSha,
      "--argjson", "expected_app", "15368"
    ];
    expect(runJq(checkRunResponseProgram, check, args).status).toBe(0);
    expect(runJq(checkRunResponseProgram, { ...check, id: 99 }, args).status).not.toBe(0);
    expect(runJq(
      checkRunResponseProgram,
      { ...check, app: { id: 999 } },
      args
    ).status).not.toBe(0);

    const bindingFunction = extractWorkflowShellFunction("ci_check_run_set_matches_preflight");
    const expectedIds = "1,2,3,4";
    const expectedUrls = [1, 2, 3, 4].map(checkRunUrl).join(",");
    expect(runCheckBindingFunction(
      bindingFunction,
      expectedIds,
      expectedUrls,
      expectedIds,
      expectedUrls
    ).status).toBe(0);
    expect(runCheckBindingFunction(
      bindingFunction,
      expectedIds,
      expectedUrls,
      "1,2,3,99",
      expectedUrls
    ).status).not.toBe(0);
    expect(runCheckBindingFunction(
      bindingFunction,
      expectedIds,
      expectedUrls,
      expectedIds,
      [1, 2, 3, 99].map(checkRunUrl).join(",")
    ).status).not.toBe(0);
  });

  it("revalidates the complete persisted CI identity immediately before publish", () => {
    const happyPath = runReleaseCiFixture("happy");
    expect(happyPath.status, happyPath.stderr).toBe(0);
    for (const scenario of [
      "rerun-attempt",
      "missing-run",
      "missing-check",
      "check-id-drift",
      "check-app-drift"
    ] as const) {
      expect(runReleaseCiFixture(scenario).status).not.toBe(0);
    }
  });

  it("requires every ruleset context to use the observed CI app integration", () => {
    expect(compact(workflow)).toContain(compact(rulesetIntegrationProgram));
    const rule = {
      parameters: {
        required_status_checks: requiredChecks.map((context) => ({
          context,
          integration_id: 15368
        }))
      }
    };
    expect(runRulesetJq(rule).status).toBe(0);
    rule.parameters.required_status_checks[2]!.integration_id = 999;
    expect(runRulesetJq(rule).status).not.toBe(0);
  });

  it("rejects malformed or out-of-repository check-run URLs", () => {
    expect(workflow.match(/validated_check_run_endpoint\(\)/g)?.length).toBe(2);
    const functionSource = extractWorkflowShellFunction("validated_check_run_endpoint");
    const validUrl = checkRunUrl(42);
    const accepted = runCheckUrlFunction(functionSource, validUrl);
    expect(accepted.status).toBe(0);
    expect(accepted.stdout).toBe("repos/example/address-atlas/check-runs/42\n");

    for (const invalidUrl of [
      "https://api.github.com/repos/other/repo/check-runs/42",
      checkRunUrl(0),
      "https://api.github.com/repos/example/address-atlas/check-runs/not-a-number",
      `${checkRunUrl(42)}/extra`,
      `${checkRunUrl(42)}\nhttps://api.github.com/repos/other/repo/check-runs/7`
    ]) {
      expect(runCheckUrlFunction(functionSource, invalidUrl).status).not.toBe(0);
    }
  });

  it("requires vulnerability alerts and unpaused automated security fixes at both gates", () => {
    expect(workflow.match(/repos\/\$GITHUB_REPOSITORY\/vulnerability-alerts/g)?.length).toBe(2);
    expect(workflow.match(/repos\/\$GITHUB_REPOSITORY\/automated-security-fixes/g)?.length).toBe(2);
    expect(workflow.match(/\.enabled == true and \.paused == false/g)?.length).toBe(2);
  });

  it("bounds Apple notarization waits in the protected release job", () => {
    expect(workflow).toContain("ADDRESS_ATLAS_NOTARY_TIMEOUT: 30m");
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

function workflowRun(overrides: Record<string, unknown> = {}) {
  return {
    id: 100,
    run_attempt: 1,
    head_sha: commitSha,
    event: "push",
    status: "completed",
    conclusion: "success",
    ...overrides
  };
}

function workflowJob(name: string, id: number) {
  return {
    id,
    name,
    run_id: 100,
    head_sha: commitSha,
    status: "completed",
    conclusion: "success",
    check_run_url: checkRunUrl(id)
  };
}

function workflowCheck(name: string, id: number) {
  return {
    id,
    name,
    head_sha: commitSha,
    status: "completed",
    conclusion: "success",
    app: { id: 15368 }
  };
}

function checkRunUrl(id: number) {
  return `https://api.github.com/repos/example/address-atlas/check-runs/${id}`;
}

function runJobsJq(jobs: Array<Record<string, unknown>>) {
  return runJq(jobsProgram, [{ total_count: jobs.length, jobs }], [
    "--arg", "sha", commitSha,
    "--argjson", "run_id", "100",
    "--argjson", "required_checks", JSON.stringify(requiredChecks)
  ]);
}

function runChecksJq(checks: Array<Record<string, unknown>>) {
  return runJq(checkRunsProgram, checks, [
    "--arg", "sha", commitSha,
    "--argjson", "required_checks", JSON.stringify(requiredChecks)
  ]);
}

function runRulesetJq(rule: Record<string, unknown>) {
  return runJq(rulesetIntegrationProgram, rule, [
    "--argjson", "required_checks", JSON.stringify(requiredChecks),
    "--argjson", "ci_integration_id", "15368"
  ]);
}

function runJq(program: string, input: unknown, args: string[]) {
  return spawnSync("jq", ["-cer", ...args, program], {
    encoding: "utf8",
    input: JSON.stringify(input)
  });
}

function extractWorkflowShellFunction(name: string) {
  const marker = `          ${name}() {`;
  const start = workflow.indexOf(marker);
  if (start < 0) throw new Error(`Missing workflow shell function ${name}`);
  const endMarker = "\n          }\n";
  const end = workflow.indexOf(endMarker, start);
  if (end < 0) throw new Error(`Unterminated workflow shell function ${name}`);
  return workflow.slice(start, end + endMarker.length).replace(/^ {10}/gm, "");
}

function runCheckUrlFunction(functionSource: string, url: string) {
  return spawnSync(
    "/bin/bash",
    ["-c", `set -euo pipefail\n${functionSource}\nvalidated_check_run_endpoint "$1"`, "fixture", url],
    {
      encoding: "utf8",
      env: {
        GITHUB_API_URL: "https://api.github.com",
        GITHUB_REPOSITORY: "example/address-atlas",
        NODE_ENV: "test"
      }
    }
  );
}

function runSelectedCiRunFunction(functionSource: string, run: Record<string, unknown>) {
  return spawnSync(
    "/bin/bash",
    [
      "-c",
      `set -euo pipefail\n${functionSource}\nselected_ci_run_matches_preflight "$1"`,
      "fixture",
      JSON.stringify(run)
    ],
    {
      encoding: "utf8",
      env: {
        CI_RUN_ATTEMPT: "1",
        CI_RUN_ID: "100",
        NODE_ENV: "test",
        PATH: process.env.PATH ?? "/usr/bin:/bin",
        SOURCE_COMMIT: commitSha
      }
    }
  );
}

function runCheckBindingFunction(
  functionSource: string,
  expectedIds: string,
  expectedUrls: string,
  observedIds: string,
  observedUrls: string
) {
  return spawnSync(
    "/bin/bash",
    [
      "-c",
      `set -euo pipefail\n${functionSource}\nci_check_run_set_matches_preflight "$1" "$2"`,
      "fixture",
      observedIds,
      observedUrls
    ],
    {
      encoding: "utf8",
      env: {
        CI_CHECK_RUN_IDS: expectedIds,
        CI_CHECK_RUN_URLS: expectedUrls,
        NODE_ENV: "test"
      }
    }
  );
}

type ReleaseCiFixtureScenario =
  | "happy"
  | "rerun-attempt"
  | "missing-run"
  | "missing-check"
  | "check-id-drift"
  | "check-app-drift";

function runReleaseCiFixture(scenario: ReleaseCiFixtureScenario) {
  const fixtureRoot = mkdtempSync(join(tmpdir(), "address-atlas-release-ci-"));
  const binDirectory = join(fixtureRoot, "bin");
  const stateDirectory = join(fixtureRoot, "state");
  mkdirSync(binDirectory);
  mkdirSync(stateDirectory);
  try {
    const ghMock = join(binDirectory, "gh");
    writeFileSync(ghMock, [
      "#!/usr/bin/env bash",
      "set -euo pipefail",
      'endpoint="${!#}"',
      'case "$endpoint" in',
      "  repos/*/actions/workflows/ci.yml/runs)",
      '    exec cat "$FIXTURE_DIR/runs.json"',
      "    ;;",
      "  repos/*/actions/runs/*/attempts/*/jobs?per_page=100)",
      '    exec cat "$FIXTURE_DIR/jobs.json"',
      "    ;;",
      "  repos/*/check-runs/*)",
      '    check_id="${endpoint##*/}"',
      '    test -f "$FIXTURE_DIR/check-${check_id}.json"',
      '    exec cat "$FIXTURE_DIR/check-${check_id}.json"',
      "    ;;",
      "  *) exit 64 ;;",
      "esac",
      ""
    ].join("\n"), { mode: 0o700 });
    chmodSync(ghMock, 0o700);

    const initialRun = workflowRun({ id: 100, run_attempt: 1 });
    const runs = scenario === "missing-run"
      ? []
      : scenario === "rerun-attempt"
        ? [initialRun, workflowRun({ id: 100, run_attempt: 2 })]
        : [initialRun];
    const jobs = requiredChecks.map((name, index) => workflowJob(name, index + 1));
    writeFileSync(join(fixtureRoot, "runs.json"), JSON.stringify({ workflow_runs: runs }));
    writeFileSync(join(fixtureRoot, "jobs.json"), JSON.stringify([
      { total_count: jobs.length, jobs }
    ]));
    for (const [index, name] of requiredChecks.entries()) {
      const id = index + 1;
      if (scenario === "missing-check" && id === 4) continue;
      const check = workflowCheck(name, id);
      if (scenario === "check-id-drift" && id === 4) check.id = 99;
      if (scenario === "check-app-drift" && id === 4) check.app.id = 999;
      writeFileSync(join(fixtureRoot, `check-${id}.json`), JSON.stringify(check));
    }

    const functionSource = [
      extractWorkflowShellFunction("validated_check_run_endpoint"),
      extractWorkflowShellFunction("selected_ci_run_matches_preflight"),
      extractWorkflowShellFunction("latest_ci_run_matches_preflight"),
      extractWorkflowShellFunction("ci_check_run_set_matches_preflight"),
      extractWorkflowShellFunction("release_ci_is_intact")
    ].join("\n");
    const expectedUrls = [1, 2, 3, 4].map(checkRunUrl).join(",");
    return spawnSync(
      "/bin/bash",
      ["-c", [
        "set -euo pipefail",
        functionSource,
        "api_header=(-H Accept:application/vnd.github+json)",
        'state_dir="$FIXTURE_STATE_DIR"',
        "release_ci_is_intact"
      ].join("\n")],
      {
        encoding: "utf8",
        env: {
          CI_CHECK_RUN_IDS: "1,2,3,4",
          CI_CHECK_RUN_URLS: expectedUrls,
          CI_INTEGRATION_ID: "15368",
          CI_RUN_ATTEMPT: "1",
          CI_RUN_ID: "100",
          FIXTURE_DIR: fixtureRoot,
          FIXTURE_STATE_DIR: stateDirectory,
          GITHUB_API_URL: "https://api.github.com",
          GITHUB_REPOSITORY: "example/address-atlas",
          NODE_ENV: "test",
          PATH: `${binDirectory}:${process.env.PATH ?? "/usr/bin:/bin"}`,
          SOURCE_COMMIT: commitSha
        }
      }
    );
  } finally {
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
}

function compact(value: string) {
  return value.replace(/\s+/g, " ").trim();
}

function compactOccurrences(source: string, needle: string) {
  return compact(source).split(compact(needle)).length - 1;
}
