import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  migrationLedgerExists: vi.fn(),
  assertAppliedMigrationHistory: vi.fn(),
  assertKnownUnversionedSchema: vi.fn(),
  assertSyncSchemaReady: vi.fn(),
  assertSyncSchemaVersionReady: vi.fn()
}));

vi.mock("./postgres-readiness", () => ({
  migrationLedgerExists: mocks.migrationLedgerExists,
  assertAppliedMigrationHistory: mocks.assertAppliedMigrationHistory,
  assertKnownUnversionedSchema: mocks.assertKnownUnversionedSchema,
  assertSyncSchemaReady: mocks.assertSyncSchemaReady,
  assertSyncSchemaVersionReady: mocks.assertSyncSchemaVersionReady
}));

import { STORAGE_RECONCILIATION_VERSION, SYNC_MIGRATIONS } from "./postgres-migrations";
import { initializeSyncSchema } from "./postgres-schema";

describe("versioned schema migration executor", () => {
  const query = vi.fn();
  const release = vi.fn();
  const pool = { connect: vi.fn(async () => ({ query, release })) };

  beforeEach(() => {
    vi.clearAllMocks();
    mocks.migrationLedgerExists.mockResolvedValue(false);
    mocks.assertAppliedMigrationHistory.mockImplementation(async () =>
      query.mock.calls.filter(([sql]) =>
        String(sql).includes("INSERT INTO sync_schema_migrations")
      ).length
    );
    mocks.assertKnownUnversionedSchema.mockResolvedValue("empty");
    mocks.assertSyncSchemaReady.mockResolvedValue(undefined);
    mocks.assertSyncSchemaVersionReady.mockResolvedValue(undefined);
    query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT reconciled_contract_version")) {
        return {
          rowCount: 1,
          rows: [{ reconciled_contract_version: 0, reconcile_required: true }]
        };
      }
      return { rowCount: 1, rows: [] };
    });
  });

  it("records every fresh migration atomically before final readiness", async () => {
    await initializeSyncSchema(pool as never);

    const ledgerWrites = query.mock.calls.filter(([sql]) =>
      String(sql).includes("INSERT INTO sync_schema_migrations")
    );
    expect(ledgerWrites.map(([, parameters]) => parameters)).toEqual(
      SYNC_MIGRATIONS.map((migration) => [migration.version, migration.name, migration.checksum])
    );
    expect(query.mock.calls.filter(([sql]) => sql === "BEGIN")).toHaveLength(4);
    expect(query.mock.calls.filter(([sql]) => sql === "COMMIT")).toHaveLength(4);
    expect(mocks.assertKnownUnversionedSchema).toHaveBeenCalledOnce();
    expect(mocks.assertSyncSchemaVersionReady.mock.calls.map(([, version]) => version))
      .toEqual([1, 1, 2, 2, 3, 3]);
    expect(mocks.assertSyncSchemaReady).toHaveBeenCalledOnce();
    expect(release).toHaveBeenCalledWith();
  });

  it("uses an authoritative complete ledger without replaying DDL", async () => {
    mocks.migrationLedgerExists.mockResolvedValue(true);
    mocks.assertAppliedMigrationHistory.mockResolvedValue(SYNC_MIGRATIONS.length);
    query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT reconciled_contract_version")) {
        return {
          rowCount: 1,
          rows: [{ reconciled_contract_version: 1, reconcile_required: false }]
        };
      }
      return { rowCount: 1, rows: [] };
    });

    await initializeSyncSchema(pool as never);

    expect(query.mock.calls.some(([sql]) => String(sql).includes("INSERT INTO sync_schema_migrations")))
      .toBe(false);
    expect(query.mock.calls.filter(([sql]) => sql === "BEGIN")).toHaveLength(1);
    expect(mocks.assertKnownUnversionedSchema).not.toHaveBeenCalled();
    const reconciliations = query.mock.calls.filter(([sql]) =>
      String(sql).includes("SET total_snapshot_bytes = totals.total_snapshot_bytes")
    );
    expect(reconciliations).toHaveLength(1);
    expect(reconciliations[0]?.[1]).toEqual([STORAGE_RECONCILIATION_VERSION]);
    expect(mocks.assertSyncSchemaReady).toHaveBeenCalledWith(
      expect.anything(),
      { verifyRuntimePrivileges: false }
    );
  });

  it("fails before migrations when applied history is unknown or newer", async () => {
    mocks.migrationLedgerExists.mockResolvedValue(true);
    mocks.assertAppliedMigrationHistory.mockRejectedValue(new Error("newer schema"));

    await expect(initializeSyncSchema(pool as never)).rejects.toThrow(/newer schema/i);
    expect(query.mock.calls.some(([sql]) => String(sql).includes("INSERT INTO sync_schema_migrations")))
      .toBe(false);
    expect(query).toHaveBeenCalledWith("ROLLBACK");
  });

  it("destroys a client after an ambiguous advisory-lock timeout", async () => {
    query.mockImplementation(async (sql: string) => {
      if (sql.includes("pg_advisory_lock")) throw new Error("query timed out");
      return { rowCount: 1, rows: [] };
    });

    await expect(initializeSyncSchema(pool as never)).rejects.toThrow(/timed out/i);
    expect(query).not.toHaveBeenCalledWith("ROLLBACK");
    expect(release).toHaveBeenCalledWith(true);
  });

  it("destroys a migration client when rollback is ambiguous", async () => {
    query.mockImplementation(async (sql: string) => {
      if (sql.includes("CREATE TABLE account_deletion_receipts")) throw new Error("query timed out");
      if (sql === "ROLLBACK") throw new Error("rollback timed out");
      if (sql.includes("SELECT reconciled_contract_version")) {
        return {
          rowCount: 1,
          rows: [{ reconciled_contract_version: 0, reconcile_required: true }]
        };
      }
      return { rowCount: 1, rows: [] };
    });

    await expect(initializeSyncSchema(pool as never)).rejects.toThrow(/query timed out/i);
    expect(release).toHaveBeenCalledWith(true);
  });

  it("destroys a client when the advisory lock cannot be confirmed released", async () => {
    query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT reconciled_contract_version")) {
        return {
          rowCount: 1,
          rows: [{ reconciled_contract_version: 0, reconcile_required: true }]
        };
      }
      if (sql.includes("pg_advisory_unlock")) throw new Error("unlock timed out");
      return { rowCount: 1, rows: [] };
    });

    await expect(initializeSyncSchema(pool as never)).resolves.toBeUndefined();
    expect(release).toHaveBeenCalledWith(true);
  });
});
