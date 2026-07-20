import { spawnSync, type SpawnSyncReturns } from "node:child_process";
import { randomBytes } from "node:crypto";
import {
  copyFileSync,
  existsSync,
  linkSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

const repoRoot = resolve(import.meta.dirname, "../..");
const tool = join(repoRoot, "scripts/repo-memory.py");
const categories = ["architecture", "decisions", "bugfixes", "gotchas", "file-map", "api-notes"];
const templateNames = ["architecture.md", "decision.md", "bugfix.md", "gotcha.md", "file-map.md", "api-note.md"];

type MemoryResult = SpawnSyncReturns<string>;

function note(
  title: string,
  status = "active",
  relatedFiles = "[]",
  lineEnding = "\n"
): string {
  return [
    "---",
    `title: ${title}`,
    "date: 2026-07-14",
    `status: ${status}`,
    "tags: [test, memory]",
    `related_files: ${relatedFiles}`,
    "---",
    "",
    "## Durable fact",
    "",
    `${title} must remain retrievable.`,
    ""
  ].join(lineEnding);
}

function createProject(container: string, projectName = "project"): { root: string; database: string } {
  const root = join(container, projectName);
  const database = join(container, `${projectName}-cache`, "repo-memory.sqlite3");
  mkdirSync(join(root, "memory", "templates"), { recursive: true });
  for (const category of categories) mkdirSync(join(root, "memory", category), { recursive: true });
  mkdirSync(join(root, "scripts"), { recursive: true });
  copyFileSync(tool, join(root, "scripts", "repo-memory.py"));
  for (const templateName of templateNames) {
    copyFileSync(join(repoRoot, "memory", "templates", templateName), join(root, "memory", "templates", templateName));
  }
  writeFileSync(join(root, "memory", "README.md"), "# Test repo semantic memory\n");
  writeFileSync(
    join(root, "AGENTS.md"),
    "<!-- repo-semantic-memory:start -->\n## Repo Semantic Memory\n<!-- repo-semantic-memory:end -->\n"
  );
  writeFileSync(
    join(root, "package.json"),
    JSON.stringify(
      {
        scripts: Object.fromEntries(
          ["init", "add", "sync", "search", "reindex", "doctor"].map((command) => [
            `memory:${command}`,
            `python3 scripts/repo-memory.py ${command}`
          ])
        )
      },
      null,
      2
    )
  );
  return { root, database };
}

function runMemory(root: string, database: string, ...args: string[]): MemoryResult {
  return spawnSync("python3", [tool, ...args], {
    cwd: root,
    encoding: "utf8",
    env: { ...process.env, CODEX_REPO_MEMORY_DB: database }
  });
}

function queryDatabase(database: string, sql: string): unknown {
  const result = spawnSync(
    "python3",
    [
      "-c",
      "import json, sqlite3, sys; c=sqlite3.connect(sys.argv[1]); print(json.dumps(c.execute(sys.argv[2]).fetchall()))",
      database,
      sql
    ],
    { encoding: "utf8" }
  );
  expect(result.status, result.stderr).toBe(0);
  return JSON.parse(result.stdout);
}

function executeDatabase(database: string, sql: string): void {
  const result = spawnSync(
    "python3",
    ["-c", "import sqlite3, sys; c=sqlite3.connect(sys.argv[1]); c.execute(sys.argv[2]); c.commit()", database, sql],
    { encoding: "utf8" }
  );
  expect(result.status, result.stderr).toBe(0);
}

describe("repo semantic memory tooling", () => {
  let temporaryDirectory: string | undefined;

  afterEach(() => {
    if (temporaryDirectory) rmSync(temporaryDirectory, { recursive: true, force: true });
    temporaryDirectory = undefined;
  });

  it("builds a local-only repository collection and retrieves the bootstrap decision", () => {
    temporaryDirectory = mkdtempSync(join(tmpdir(), "address-atlas-memory-"));
    const database = join(temporaryDirectory, "repo-memory.sqlite3");
    const environment = { ...process.env, CODEX_REPO_MEMORY_DB: database };

    const doctor = spawnSync("python3", [tool, "doctor"], {
      cwd: repoRoot,
      encoding: "utf8",
      env: environment
    });
    expect(doctor.status, doctor.stderr).toBe(0);
    const health = JSON.parse(doctor.stdout) as {
      healthy: boolean;
      database: string;
      notes_indexed: number;
      security_warnings: string[];
    };
    expect(health).toMatchObject({
      healthy: true,
      database: resolve(database),
      security_warnings: []
    });
    expect(health.notes_indexed).toBeGreaterThanOrEqual(1);
    for (const artifact of [database, `${database}-wal`, `${database}-shm`, `${database}-journal`]) {
      if (existsSync(artifact)) expect(statSync(artifact).mode & 0o077).toBe(0);
    }

    const search = spawnSync(
      "python3",
      [tool, "search", "How should agents use repository memory?", "--top-k", "5"],
      { cwd: repoRoot, encoding: "utf8", env: environment }
    );
    expect(search.status, search.stderr).toBe(0);
    const results = JSON.parse(search.stdout) as {
      repo_id: string;
      results: Array<{ source: string }>;
    };
    expect(results.repo_id).toMatch(/^address-atlas-/);
    expect(results.results.map((result) => result.source)).toContain(
      "memory/decisions/repo-semantic-memory.md"
    );
    expect(results.results.some((result) => result.source.startsWith("docs/handoff/"))).toBe(false);
  });

  it("handles status transitions, deleted notes, CRLF/BOM input, and excludes raw handoffs", () => {
    temporaryDirectory = mkdtempSync(join(tmpdir(), "repo-memory-lifecycle-"));
    const { root, database } = createProject(temporaryDirectory);
    writeFileSync(join(root, "memory", "decisions", "active.md"), note("Unique active memory"));
    writeFileSync(
      join(root, "memory", "gotchas", "review.md"),
      `\ufeff${note("Unique review memory", "needs-review # intentionally pending", "[missing.ts]", "\r\n")}`
    );
    writeFileSync(join(root, "memory", "bugfixes", "old.md"), note("Retired memory", "deprecated"));
    mkdirSync(join(root, "docs", "handoff"), { recursive: true });
    mkdirSync(join(root, "memory", "handoff"), { recursive: true });
    writeFileSync(join(root, "docs", "handoff", "raw.md"), "Unique raw handoff memory\n");
    writeFileSync(join(root, "memory", "handoff", "raw.md"), "Unique raw handoff memory\n");

    const initial = runMemory(root, database, "init");
    expect(initial.status, initial.stderr).toBe(0);
    expect(JSON.parse(initial.stdout)).toMatchObject({ scanned: 3, indexed: 2, removed: 0 });
    const repeatedInit = runMemory(root, database, "init");
    expect(repeatedInit.status, repeatedInit.stderr).toBe(0);
    expect(JSON.parse(repeatedInit.stdout)).toMatchObject({
      mode: "sync",
      scanned: 3,
      indexed: 0,
      updated: 0,
      removed: 0,
      skipped: 3
    });

    const firstSearch = runMemory(root, database, "search", "Unique memory", "--top-k", "8");
    const secondSearch = runMemory(root, database, "search", "Unique memory", "--top-k", "8");
    expect(firstSearch.status, firstSearch.stderr).toBe(0);
    expect(secondSearch.status, secondSearch.stderr).toBe(0);
    expect(secondSearch.stdout).toBe(firstSearch.stdout);
    const sources = (JSON.parse(firstSearch.stdout) as { results: Array<{ source: string }> }).results.map(
      (result) => result.source
    );
    expect(sources).toEqual(
      expect.arrayContaining(["memory/decisions/active.md", "memory/gotchas/review.md"])
    );
    expect(sources).not.toContain("memory/bugfixes/old.md");
    expect(sources.some((source) => source.includes("handoff"))).toBe(false);

    const doctor = runMemory(root, database, "doctor");
    expect(doctor.status, doctor.stderr).toBe(0);
    const health = JSON.parse(doctor.stdout) as { stale_or_needs_review: string[] };
    expect(health.stale_or_needs_review.join("\n")).toContain("status is needs-review");
    expect(health.stale_or_needs_review.join("\n")).toContain("related file does not exist: missing.ts");

    executeDatabase(database, "UPDATE collections SET vector_dimensions = 1");
    const schemaRepair = runMemory(root, database, "sync");
    expect(schemaRepair.status, schemaRepair.stderr).toBe(0);
    expect(JSON.parse(schemaRepair.stdout)).toMatchObject({ mode: "reindex", indexed: 2 });

    executeDatabase(
      database,
      "UPDATE chunks SET vector = 'not-json' WHERE rowid IN (SELECT rowid FROM chunks LIMIT 1)"
    );
    const cacheRepair = runMemory(root, database, "sync");
    expect(cacheRepair.status, cacheRepair.stderr).toBe(0);
    expect(JSON.parse(cacheRepair.stdout)).toMatchObject({ mode: "reindex", indexed: 2 });

    writeFileSync(join(root, "memory", "decisions", "active.md"), note("Unique active memory", "superseded"));
    rmSync(join(root, "memory", "gotchas", "review.md"));
    const cleanup = runMemory(root, database, "sync");
    expect(cleanup.status, cleanup.stderr).toBe(0);
    expect(JSON.parse(cleanup.stdout)).toMatchObject({ updated: 1, removed: 1 });
    expect(queryDatabase(database, "SELECT source FROM documents ORDER BY source")).toEqual([]);
  });

  it("rebuilds a corrupt disposable database and sidecars from curated Markdown", () => {
    temporaryDirectory = mkdtempSync(join(tmpdir(), "repo-memory-corrupt-db-"));
    const { root, database } = createProject(temporaryDirectory);
    writeFileSync(join(root, "memory", "decisions", "valid.md"), note("Recovered memory"));
    mkdirSync(dirname(database), { recursive: true });
    writeFileSync(database, randomBytes(256));
    writeFileSync(`${database}-wal`, randomBytes(256));
    writeFileSync(`${database}-shm`, randomBytes(256));
    writeFileSync(`${database}-journal`, randomBytes(256));

    const recovered = runMemory(root, database, "init");
    expect(recovered.status, recovered.stderr).toBe(0);
    expect(recovered.stderr).toContain("corrupt local cache removed; rebuilding it from curated Markdown");
    expect(JSON.parse(recovered.stdout)).toMatchObject({ scanned: 1, indexed: 1 });
    expect(queryDatabase(database, "SELECT title FROM documents ORDER BY source")).toEqual([
      ["Recovered memory"]
    ]);
    for (const artifact of [database, `${database}-wal`, `${database}-shm`, `${database}-journal`]) {
      if (existsSync(artifact)) expect(statSync(artifact).mode & 0o077).toBe(0);
    }

    const search = runMemory(root, database, "search", "Recovered memory");
    expect(search.status, search.stderr).toBe(0);
    expect(
      (JSON.parse(search.stdout) as { results: Array<{ source: string }> }).results.map(
        (result) => result.source
      )
    ).toContain("memory/decisions/valid.md");
    const doctor = runMemory(root, database, "doctor");
    expect(doctor.status, doctor.stderr).toBe(0);
    expect(JSON.parse(doctor.stdout)).toMatchObject({ healthy: true, notes_indexed: 1 });
  });

  it("rejects symlinked notes and path escapes without reading outside the repository", () => {
    temporaryDirectory = mkdtempSync(join(tmpdir(), "repo-memory-paths-"));
    const { root, database } = createProject(temporaryDirectory);
    writeFileSync(join(root, "memory", "decisions", "valid.md"), note("Valid memory"));
    expect(runMemory(root, database, "init").status).toBe(0);

    const external = join(temporaryDirectory, "external.md");
    writeFileSync(external, note("External memory"));
    symlinkSync(external, join(root, "memory", "decisions", "linked.md"));
    const symlinked = runMemory(root, database, "sync");
    expect(symlinked.status).toBe(1);
    expect(symlinked.stderr).toContain("must not use symbolic links");
    expect(symlinked.stderr).not.toContain(readFileSync(external, "utf8"));

    rmSync(join(root, "memory", "decisions", "linked.md"));
    const externalDirectory = join(temporaryDirectory, "external-directory");
    mkdirSync(externalDirectory);
    writeFileSync(join(externalDirectory, "hidden.md"), note("Hidden external memory"));
    symlinkSync(externalDirectory, join(root, "memory", "decisions", "linked-directory"));
    const linkedDirectory = runMemory(root, database, "sync");
    expect(linkedDirectory.status).toBe(1);
    expect(linkedDirectory.stderr).toContain("linked-directory");

    rmSync(join(root, "memory", "decisions", "linked-directory"));
    linkSync(external, join(root, "memory", "decisions", "hard-linked.md"));
    const hardLinked = runMemory(root, database, "sync");
    expect(hardLinked.status).toBe(1);
    expect(hardLinked.stderr).toContain("must not be hard-linked");

    rmSync(join(root, "memory", "decisions", "hard-linked.md"));
    writeFileSync(
      join(root, "memory", "decisions", "escape.md"),
      note("Escaping reference", "active", "[../outside.txt]")
    );
    const escaped = runMemory(root, database, "doctor");
    expect(escaped.status).toBe(1);
    const report = JSON.parse(escaped.stdout) as { healthy: boolean; errors: string[] };
    expect(report.healthy).toBe(false);
    expect(report.errors.join("\n")).toContain("must be repository-relative");
  });

  it("keeps the previous index intact when reindex validation fails and reports secrets structurally", () => {
    temporaryDirectory = mkdtempSync(join(tmpdir(), "repo-memory-atomic-"));
    const { root, database } = createProject(temporaryDirectory);
    const validPath = join(root, "memory", "decisions", "valid.md");
    writeFileSync(validPath, note("Original indexed title"));
    expect(runMemory(root, database, "init").status).toBe(0);

    writeFileSync(validPath, note("Uncommitted replacement title"));
    const fakeGitHubToken = `ghp_${"1".repeat(30)}`;
    writeFileSync(
      join(root, "memory", "bugfixes", "secret.md"),
      `${note("Secret note")}\naccess_token = \"${fakeGitHubToken}\"\n`
    );
    const rejected = runMemory(root, database, "reindex");
    expect(rejected.status).toBe(1);
    expect(rejected.stderr).toContain("possible GitHub token");
    expect(rejected.stderr).not.toContain(fakeGitHubToken);
    expect(queryDatabase(database, "SELECT title FROM documents ORDER BY source")).toEqual([
      ["Original indexed title"]
    ]);

    const doctor = runMemory(root, database, "doctor");
    expect(doctor.status).toBe(1);
    const report = JSON.parse(doctor.stdout) as {
      healthy: boolean;
      sync: { status: string };
      security_warnings: string[];
    };
    expect(report).toMatchObject({ healthy: false, sync: { status: "blocked" } });
    expect(report.security_warnings.join("\n")).toContain("possible GitHub token");

    const fakeSessionSecret = "a".repeat(24);
    writeFileSync(
      join(root, "memory", "bugfixes", "secret.md"),
      `${note("Secret note")}\nSYNC_SESSION_SECRET = \"${fakeSessionSecret}\"\n`
    );
    const genericSecret = runMemory(root, database, "sync");
    expect(genericSecret.status).toBe(1);
    expect(genericSecret.stderr).toContain("possible credential variable");
    expect(genericSecret.stderr).not.toContain(fakeSessionSecret);
  });

  it("uses distinct namespaces per clone and strips credentials from stored remotes", () => {
    temporaryDirectory = mkdtempSync(join(tmpdir(), "repo-memory-scope-"));
    const firstContainer = join(temporaryDirectory, "one");
    const secondContainer = join(temporaryDirectory, "two");
    mkdirSync(firstContainer);
    mkdirSync(secondContainer);
    const first = createProject(firstContainer, "same-name");
    const second = createProject(secondContainer, "same-name");
    const sharedDatabase = join(temporaryDirectory, "shared-cache", "repo-memory.sqlite3");
    const credentialRemote = [
      "https://",
      ["secret", "user"].join("-"),
      ":",
      ["super", "secret"].join(""),
      "@example.com/org/repo.git?token=hidden"
    ].join("");
    for (const project of [first, second]) {
      writeFileSync(join(project.root, "memory", "decisions", "valid.md"), note("Scoped memory"));
      expect(spawnSync("git", ["init", "-q"], { cwd: project.root }).status).toBe(0);
      expect(
        spawnSync(
          "git",
          ["remote", "add", "origin", credentialRemote],
          { cwd: project.root }
        ).status
      ).toBe(0);
    }

    const firstInit = runMemory(first.root, sharedDatabase, "init");
    const secondInit = runMemory(second.root, sharedDatabase, "init");
    expect(firstInit.status, firstInit.stderr).toBe(0);
    expect(secondInit.status, secondInit.stderr).toBe(0);
    expect(JSON.parse(firstInit.stdout).repo_id).not.toBe(JSON.parse(secondInit.stdout).repo_id);
    expect(queryDatabase(sharedDatabase, "SELECT remote FROM collections ORDER BY root")).toEqual([
      ["https://example.com/org/repo.git"],
      ["https://example.com/org/repo.git"]
    ]);
    expect(queryDatabase(sharedDatabase, "SELECT COUNT(*) FROM collections")).toEqual([[2]]);
  });

  it("creates notes from a safe category template and refuses duplicate or empty slugs", () => {
    temporaryDirectory = mkdtempSync(join(tmpdir(), "repo-memory-add-"));
    const { root, database } = createProject(temporaryDirectory);
    const created = runMemory(root, database, "add", "bugfixes", "Race Condition");
    expect(created.status, created.stderr).toBe(0);
    const relativePath = created.stdout.trim();
    expect(relativePath).toMatch(/^memory\/bugfixes\/\d{4}-\d{2}-\d{2}-race-condition\.md$/);
    const content = readFileSync(join(root, relativePath), "utf8");
    expect(content).toContain("title: Race condition");
    expect(content).toContain("related_files: []");

    const duplicate = runMemory(root, database, "add", "bugfixes", "Race Condition");
    expect(duplicate.status).toBe(1);
    expect(duplicate.stderr).toContain("Note already exists");
    const empty = runMemory(root, database, "add", "bugfixes", "../../");
    expect(empty.status).toBe(1);
    expect(empty.stderr).toContain("slug must contain letters or numbers");

    const doctor = runMemory(root, database, "doctor");
    expect(doctor.status, doctor.stderr).toBe(0);
    expect(JSON.parse(doctor.stdout)).toMatchObject({ healthy: true, notes_scanned: 1, notes_indexed: 1 });
  });

  it("refuses to place the rebuildable database inside the repository", () => {
    temporaryDirectory = mkdtempSync(join(tmpdir(), "repo-memory-local-db-"));
    const { root } = createProject(temporaryDirectory);
    writeFileSync(join(root, "memory", "decisions", "valid.md"), note("Valid memory"));
    const database = join(root, "repo-memory.sqlite3");
    const result = runMemory(root, database, "init");
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("must live outside the repository");

    const protectedTarget = join(temporaryDirectory, "protected.txt");
    writeFileSync(protectedTarget, "do-not-touch");

    const linkedDatabase = join(temporaryDirectory, "linked-cache.sqlite3");
    symlinkSync(protectedTarget, linkedDatabase);
    const mainSymlink = runMemory(root, linkedDatabase, "init");
    expect(mainSymlink.status).toBe(1);
    expect(mainSymlink.stderr).toContain("database artifact must not be a symlink");
    expect(readFileSync(protectedTarget, "utf8")).toBe("do-not-touch");

    const hardLinkedDatabase = join(temporaryDirectory, "hard-linked-cache.sqlite3");
    linkSync(protectedTarget, hardLinkedDatabase);
    const mainHardLink = runMemory(root, hardLinkedDatabase, "init");
    expect(mainHardLink.status).toBe(1);
    expect(mainHardLink.stderr).toContain("database artifact must not be hard-linked");
    expect(readFileSync(protectedTarget, "utf8")).toBe("do-not-touch");

    const externalDatabase = join(temporaryDirectory, "external-cache.sqlite3");
    symlinkSync(protectedTarget, `${externalDatabase}-wal`);
    const sidecar = runMemory(root, externalDatabase, "init");
    expect(sidecar.status).toBe(1);
    expect(sidecar.stderr).toContain("database artifact must not be a symlink");
    expect(readFileSync(protectedTarget, "utf8")).toBe("do-not-touch");
  });
});
