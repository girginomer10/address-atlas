import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  poolQuery: vi.fn(),
  connect: vi.fn(),
  clientQuery: vi.fn(),
  release: vi.fn(),
  end: vi.fn(),
  on: vi.fn(),
  configs: [] as unknown[]
}));

vi.mock("pg", () => ({
  Pool: vi.fn(function Pool(config: unknown) {
    mocks.configs.push(config);
    return {
      query: mocks.poolQuery,
      connect: mocks.connect,
      end: mocks.end,
      on: mocks.on
    };
  })
}));

import { closeSyncPoolForTests, ensureSyncSchema, getSyncPool } from "./postgres";

describe("Postgres sync readiness", () => {
  beforeEach(async () => {
    await closeSyncPoolForTests();
    vi.clearAllMocks();
    mocks.configs.length = 0;
    mocks.poolQuery.mockResolvedValue({ rowCount: 0, rows: [] });
    mocks.clientQuery.mockResolvedValue({ rowCount: 1, rows: [] });
    mocks.connect.mockResolvedValue({ query: mocks.clientQuery, release: mocks.release });
    vi.stubEnv("SYNC_DATABASE_URL", "postgres://user:password@localhost:5432/address_atlas");
  });

  afterEach(async () => {
    await closeSyncPoolForTests();
    vi.unstubAllEnvs();
  });

  it("configures bounded timeouts and consumes idle-client errors", () => {
    getSyncPool();
    expect(mocks.configs[0]).toMatchObject({
      connectionTimeoutMillis: 5_000,
      idleTimeoutMillis: 30_000,
      statement_timeout: 10_000,
      query_timeout: 12_000,
      max: 10
    });
    expect(mocks.on).toHaveBeenCalledWith("error", expect.any(Function));
  });

  it("reconciles aggregate storage under a row lock and prunes usage in a bounded batch", async () => {
    await expect(ensureSyncSchema()).resolves.toBeUndefined();

    const statements = mocks.clientQuery.mock.calls.map(([sql]) => String(sql));
    const schemaSQL = statements.join("\n");
    expect(schemaSQL).toContain("ADD COLUMN IF NOT EXISTS transports");
    expect(schemaSQL).toContain("passkey_credentials_transports_bounded");
    expect(schemaSQL).not.toContain("DROP COLUMN IF EXISTS transports");
    expect(schemaSQL).toContain("address_atlas_snapshot_delete_usage");
    const singletonInsertIndex = statements.findIndex((sql) => sql.includes("INSERT INTO sync_storage_usage"));
    const triggerIndex = statements.findIndex((sql) => sql.includes("CREATE TRIGGER address_atlas_snapshot_delete_usage"));
    expect(singletonInsertIndex).toBeGreaterThan(-1);
    expect(triggerIndex).toBeGreaterThan(singletonInsertIndex);
    expect(statements.slice(singletonInsertIndex + 1, triggerIndex)).toContain("COMMIT");
    expect(statements.slice(singletonInsertIndex + 1, triggerIndex)).toContain("BEGIN");
    expect(statements.filter((sql) => sql.includes("CREATE TABLE IF NOT EXISTS")))
      .toHaveLength(6);
    const lockIndex = statements.findIndex((sql) => sql.includes("FOR UPDATE"));
    const reconcileIndex = statements.findIndex((sql) => sql.includes("COALESCE(sum(byte_size)"));
    expect(lockIndex).toBeGreaterThan(-1);
    expect(reconcileIndex).toBeGreaterThan(lockIndex);
    expect(mocks.poolQuery).toHaveBeenCalledWith(expect.stringContaining("DELETE FROM vault_write_usage"), [
      35, 10_000
    ]);
    expect(String(mocks.poolQuery.mock.calls[0]?.[0])).toContain("FOR UPDATE SKIP LOCKED");
    expect(mocks.release).toHaveBeenCalledOnce();
  });

  it("retries schema initialization after a transient failure", async () => {
    let shouldFail = true;
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (shouldFail && sql.includes("CREATE TABLE IF NOT EXISTS users")) {
        shouldFail = false;
        throw new Error("database starting");
      }
      return { rowCount: 1, rows: [] };
    });

    await expect(ensureSyncSchema()).rejects.toThrow(/starting/i);
    await expect(ensureSyncSchema()).resolves.toBeUndefined();
    expect(mocks.connect).toHaveBeenCalledTimes(2);
    expect(mocks.clientQuery).toHaveBeenCalledWith("ROLLBACK");
  });

  it("does not leak a failed best-effort usage prune into concurrent callers", async () => {
    let rejectPrune: ((error: Error) => void) | undefined;
    mocks.poolQuery.mockImplementation(() => new Promise((_, reject) => {
      rejectPrune = reject;
    }));

    const first = ensureSyncSchema();
    await vi.waitFor(() => expect(rejectPrune).toBeTypeOf("function"));
    const concurrent = ensureSyncSchema();

    await expect(Promise.all([first, concurrent])).resolves.toEqual([undefined, undefined]);
    rejectPrune!(new Error("retention temporarily unavailable"));
  });

  it("destroys a transaction client when rollback also fails", async () => {
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (sql.includes("CREATE TABLE IF NOT EXISTS users")) throw new Error("query timed out");
      if (sql === "ROLLBACK") throw new Error("rollback timed out");
      return { rowCount: 1, rows: [] };
    });

    await expect(ensureSyncSchema()).rejects.toThrow(/query timed out/i);
    expect(mocks.release).toHaveBeenCalledWith(true);
  });

  it("destroys a client after an ambiguous advisory-lock timeout", async () => {
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (sql.includes("pg_advisory_lock")) throw new Error("query timed out");
      return { rowCount: 1, rows: [] };
    });

    await expect(ensureSyncSchema()).rejects.toThrow(/query timed out/i);
    expect(mocks.clientQuery).not.toHaveBeenCalledWith("ROLLBACK");
    expect(mocks.release).toHaveBeenCalledWith(true);
  });

  it("destroys a client when the session advisory lock cannot be confirmed released", async () => {
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (sql.includes("pg_advisory_unlock")) throw new Error("unlock timed out");
      return { rowCount: 1, rows: [] };
    });

    await expect(ensureSyncSchema()).resolves.toBeUndefined();
    expect(mocks.release).toHaveBeenCalledWith(true);
  });
});
