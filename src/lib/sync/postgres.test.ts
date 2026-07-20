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

import {
  checkSyncSchemaReadiness,
  closeSyncPoolForTests,
  ensureSyncSchema,
  getSyncPool
} from "./postgres";

function successfulClientResult(sql: string) {
  if (sql.includes("SELECT reconciled_contract_version, reconcile_required")) {
    return {
      rowCount: 1,
      rows: [{ reconciled_contract_version: 0, reconcile_required: true }]
    };
  }
  if (sql.includes("address-atlas-sync-schema-contract-v2")) {
    return { rowCount: 1, rows: [{ ready: true }] };
  }
  return { rowCount: 1, rows: [] };
}

describe("Postgres sync readiness", () => {
  beforeEach(async () => {
    await closeSyncPoolForTests();
    vi.clearAllMocks();
    mocks.configs.length = 0;
    mocks.poolQuery.mockResolvedValue({ rowCount: 0, rows: [] });
    mocks.clientQuery.mockImplementation(async (sql: string) => successfulClientResult(sql));
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

  it("forwards explicit pool size and idle timeout controls to node-postgres", () => {
    vi.stubEnv("SYNC_DB_POOL_SIZE", "7");
    vi.stubEnv("SYNC_DB_IDLE_TIMEOUT_MS", "45000");

    getSyncPool();

    expect(mocks.configs[0]).toMatchObject({ max: 7, idleTimeoutMillis: 45_000 });
  });

  it("checks the exact runtime table, column, constraint, index, trigger, and function contract", async () => {
    mocks.poolQuery.mockResolvedValueOnce({ rowCount: 1, rows: [{ ready: true }] });

    await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();

    const readinessSQL = String(mocks.poolQuery.mock.calls[0]?.[0]);
    for (const relation of [
      "users",
      "passkey_credentials",
      "consumed_challenges",
      "vault_write_usage",
      "sync_storage_usage",
      "vault_snapshots"
    ]) {
      expect(readinessSQL).toContain(`('${relation}')`);
    }
    const requiredColumns: Record<string, string[]> = {
      users: ["id", "created_at", "updated_at"],
      passkey_credentials: [
        "id", "user_id", "public_key_base64url", "counter", "transports", "created_at", "updated_at"
      ],
      consumed_challenges: ["challenge", "consumed_at"],
      vault_write_usage: ["user_id", "usage_date", "write_count", "byte_count", "updated_at"],
      sync_storage_usage: [
        "singleton",
        "total_snapshot_bytes",
        "reconciled_contract_version",
        "reconcile_required",
        "updated_at"
      ],
      vault_snapshots: [
        "user_id", "version", "envelope", "byte_size", "checksum", "created_at", "updated_at"
      ]
    };
    for (const [relation, columns] of Object.entries(requiredColumns)) {
      for (const column of columns) {
        expect(readinessSQL).toContain(`('${relation}', '${column}',`);
      }
    }
    for (const exactColumnContract of [
      "('users', 'id', 'uuid', NULL::text)",
      "('users', 'created_at', 'timestamptz', 'now()')",
      "('passkey_credentials', 'counter', 'int8', '0')",
      "('passkey_credentials', 'transports', 'jsonb', '''[]''::jsonb')",
      "('vault_write_usage', 'write_count', 'int4', NULL)",
      "('vault_write_usage', 'byte_count', 'int8', NULL)",
      "('sync_storage_usage', 'singleton', 'bool', 'true')",
      "('sync_storage_usage', 'reconciled_contract_version', 'int4', '0')",
      "('sync_storage_usage', 'reconcile_required', 'bool', 'true')",
      "('vault_snapshots', 'version', 'int4', NULL)",
      "('vault_snapshots', 'envelope', 'jsonb', NULL)"
    ]) {
      expect(readinessSQL).toContain(exactColumnContract);
    }
    expect(readinessSQL).toContain("address_atlas_snapshot_delete_usage");
    expect(readinessSQL).toContain("trigger_row.tgenabled = 'O'");
    expect(readinessSQL).toContain("trigger_row.tgtype = 9");
    expect(readinessSQL).toContain("trigger_row.tgqual IS NULL");
    expect(readinessSQL).toContain("trigger_row.tgconstraint = 0::oid");
    expect(readinessSQL).toContain("NOT trigger_row.tgdeferrable");
    expect(readinessSQL).toContain("NOT trigger_row.tginitdeferred");
    expect(readinessSQL).toContain("trigger_row.tgnargs = 0");
    expect(readinessSQL).toContain("address_atlas_decrement_snapshot_usage");
    expect(readinessSQL).toContain("trigger_proc.prosrc");
    for (const conflictKey of [
      "users conflict key",
      "passkey credential conflict key",
      "challenge conflict key",
      "vault usage conflict key",
      "storage singleton conflict key",
      "vault snapshot conflict key"
    ]) {
      expect(readinessSQL).toContain(conflictKey);
    }
    expect(readinessSQL).toContain("expected.constraint_type = 'k'");
    expect(readinessSQL).toContain("present.contype IN ('p', 'u')");
    expect(readinessSQL).toContain("present.confupdtype::text = expected.foreign_update_action");
    expect(readinessSQL).toContain("present.confdeltype::text = expected.foreign_delete_action");
    expect(readinessSQL).toContain("present.confmatchtype::text = expected.foreign_match_type");
    expect(readinessSQL).toContain("present.convalidated");
    for (const relationship of [
      "passkey account foreign key",
      "vault usage account foreign key",
      "vault snapshot account foreign key"
    ]) {
      expect(readinessSQL).toContain(relationship);
    }
    for (const check of [
      "passkey counter uint32 check",
      "vault usage write count check",
      "vault usage byte count check",
      "storage singleton check",
      "storage byte count check",
      "storage contract version check",
      "vault snapshot version bound",
      "vault snapshot byte size bound"
    ]) {
      expect(readinessSQL).toContain(check);
    }
    expect(readinessSQL).toContain("type.typname <> required.type_name");
    expect(readinessSQL).toContain("type_namespace.nspname <> 'pg_catalog'");
    expect(readinessSQL).toContain("IS DISTINCT FROM required.default_expression");
    expect(readinessSQL).toContain("attribute.attidentity <> ''");
    expect(readinessSQL).toContain("attribute.attinhcount <> 0");
    expect(readinessSQL).toContain("present.contype IN ('p', 'u', 'f', 'c', 'x')");
    expect(readinessSQL).toContain("internal_trigger.tgconstraint = present.oid");
    expect(readinessSQL).toContain("count(*) = 4");
    expect(readinessSQL).toContain("internal_trigger.tgenabled = 'O'");
    expect(readinessSQL).toContain("present.indisunique");
    expect(readinessSQL).toContain("NOT present.indcheckxmin");
    expect(readinessSQL).toContain("consumed_challenges_consumed_at_idx");
    expect(readinessSQL).toContain("vault_write_usage_date_idx");
    expect(readinessSQL).toContain("relation.relrowsecurity");
    expect(readinessSQL).toContain("pg_catalog.pg_inherits");
    expect(readinessSQL).toContain("trigger_proc.pronargdefaults = 0");
    expect(readinessSQL).toContain("trigger_proc.proallargtypes IS NULL");
    expect(readinessSQL).toContain("trigger_proc.proconfig IS NULL");
    expect(readinessSQL).toContain("trigger_row.tgparentid = 0::oid");
    expect(readinessSQL).toContain("octet_length(trigger_row.tgargs) = 0");
    expect(readinessSQL).toContain("total_snapshot_bytes >= 0");
    expect(readinessSQL).toContain("counter <= ''4294967295''::bigint");
    expect(readinessSQL).toContain("NOT reconcile_required");
    expect(readinessSQL).toContain("reconciled_contract_version");
    expect(readinessSQL).toContain("LIMIT 2");
    expect(readinessSQL).toContain("TG_TABLE_SCHEMA");
    expect(readinessSQL).toContain("pg_catalog.format");
    expect(readinessSQL).toContain("updated_rows <> 1");
    expect(readinessSQL).not.toContain("sum(byte_size)");
  });

  it("fails readiness when the schema probe reports drift", async () => {
    mocks.poolQuery.mockResolvedValueOnce({ rowCount: 1, rows: [{ ready: false }] });

    await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
  });

  it("reconciles aggregate storage under a row lock and prunes usage in a bounded batch", async () => {
    await expect(ensureSyncSchema()).resolves.toBeUndefined();

    const statements = mocks.clientQuery.mock.calls.map(([sql]) => String(sql));
    const schemaSQL = statements.join("\n");
    expect(schemaSQL).toContain("ADD COLUMN IF NOT EXISTS transports");
    expect(schemaSQL).toContain("passkey_credentials_transports_bounded");
    expect(schemaSQL).toContain("passkey_credentials_counter_uint32_check");
    expect(schemaSQL).toContain("CHECK (counter BETWEEN 0 AND 4294967295)");
    expect(schemaSQL).not.toContain("DROP COLUMN IF EXISTS transports");
    expect(schemaSQL).toContain("address_atlas_snapshot_delete_usage");
    expect(schemaSQL).toContain("DROP TRIGGER IF EXISTS address_atlas_snapshot_delete_usage");
    expect(schemaSQL).toContain("trigger_row.tgenabled = 'O'");
    expect(schemaSQL).toContain("trigger_row.tgtype = 9");
    expect(schemaSQL).toContain("trigger_row.tgqual IS NULL");
    expect(schemaSQL).toContain("trigger_row.tgconstraint = 0::oid");
    expect(schemaSQL).toContain("NOT trigger_row.tgdeferrable");
    expect(schemaSQL).toContain("NOT trigger_row.tginitdeferred");
    expect(schemaSQL).toContain("trigger_row.tgnargs = 0");
    expect(schemaSQL).toContain("address-atlas-sync-schema-contract-v2");
    expect(schemaSQL).toContain("ALTER TABLE vault_snapshots ADD CONSTRAINT vault_snapshots_pkey");
    expect(schemaSQL).toContain("ALTER COLUMN %I SET NOT NULL");
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

  it("skips the full snapshot scan when the current contract is already reconciled", async () => {
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT reconciled_contract_version, reconcile_required")) {
        return {
          rowCount: 1,
          rows: [{ reconciled_contract_version: 1, reconcile_required: false }]
        };
      }
      return successfulClientResult(sql);
    });

    await expect(ensureSyncSchema()).resolves.toBeUndefined();

    const statements = mocks.clientQuery.mock.calls.map(([sql]) => String(sql));
    expect(statements.some((sql) => sql.includes("COALESCE(sum(byte_size)"))).toBe(false);
  });

  it("fails closed instead of downgrading a newer reconciliation contract", async () => {
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (sql.includes("address-atlas-schema-version-probe")) {
        return {
          rowCount: 1,
          rows: [{
            schema_name: "public",
            relation_oid: "16384",
            relation_shape_safe: true,
            marker_exists: true,
            marker_shape_safe: true
          }]
        };
      }
      if (sql.includes("ORDER BY attribute.attnum")) {
        const shared = {
          type_namespace: "pg_catalog",
          type_modifier: -1,
          dimensions: 0,
          not_null: true,
          identity_kind: "",
          generated_kind: "",
          is_local: true,
          inheritance_count: 0,
          default_collation: true
        };
        return {
          rowCount: 5,
          rows: [
            { ...shared, column_name: "singleton", type_name: "bool", default_expression: "true" },
            { ...shared, column_name: "total_snapshot_bytes", type_name: "int8", default_expression: null },
            { ...shared, column_name: "updated_at", type_name: "timestamptz", default_expression: "now()" },
            { ...shared, column_name: "reconciled_contract_version", type_name: "int4", default_expression: "0" },
            { ...shared, column_name: "reconcile_required", type_name: "bool", default_expression: "true" }
          ]
        };
      }
      if (sql.includes("WITH matching_constraints AS")) {
        return { rowCount: 1, rows: [{ safe: true }] };
      }
      if (sql.includes('FROM "public".sync_storage_usage')) {
        return { rowCount: 1, rows: [{ "?column?": 1 }] };
      }
      return successfulClientResult(sql);
    });

    await expect(ensureSyncSchema()).rejects.toThrow(/newer than this server supports/i);
    const statements = mocks.clientQuery.mock.calls.map(([sql]) => String(sql));
    expect(statements.some((sql) => sql.includes("CREATE TABLE IF NOT EXISTS"))).toBe(false);
    expect(statements.some((sql) => sql.includes("COALESCE(sum(byte_size)"))).toBe(false);
    expect(mocks.clientQuery).toHaveBeenCalledWith("ROLLBACK");
  });

  it("retries schema initialization after a transient failure", async () => {
    let shouldFail = true;
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (shouldFail && sql.includes("CREATE TABLE IF NOT EXISTS users")) {
        shouldFail = false;
        throw new Error("database starting");
      }
      return successfulClientResult(sql);
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
      return successfulClientResult(sql);
    });

    await expect(ensureSyncSchema()).resolves.toBeUndefined();
    expect(mocks.release).toHaveBeenCalledWith(true);
  });

  it("fails initialization itself when schema drift cannot be repaired safely", async () => {
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (sql.includes("address-atlas-sync-schema-contract-v2")) {
        return { rowCount: 1, rows: [{ ready: false }] };
      }
      return successfulClientResult(sql);
    });

    await expect(ensureSyncSchema()).rejects.toThrow(/schema is not ready/i);
    expect(mocks.clientQuery).toHaveBeenCalledWith(expect.stringContaining("address-atlas-sync-schema-contract-v2"));
    expect(mocks.clientQuery).toHaveBeenCalledWith("ROLLBACK");
  });
});
