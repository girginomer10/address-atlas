import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { SYNC_MIGRATIONS } from "./postgres-migrations";
import {
  checkSyncSchemaReadiness,
  closeSyncPoolForTests,
  ensureSyncSchema,
  getSyncPool
} from "./postgres";

const maybeDescribe = process.env.TEST_SYNC_DATABASE_URL ? describe : describe.skip;

maybeDescribe("versioned Postgres schema migrations", () => {
  let previousDatabaseURL: string | undefined;
  let previousSchemaMode: string | undefined;

  beforeAll(async () => {
    previousDatabaseURL = process.env.SYNC_DATABASE_URL;
    previousSchemaMode = process.env.SYNC_SCHEMA_MODE;
    process.env.SYNC_DATABASE_URL = process.env.TEST_SYNC_DATABASE_URL;
    process.env.SYNC_SCHEMA_MODE = "bootstrap";
    await ensureSyncSchema();
  });

  afterAll(async () => {
    await closeSyncPoolForTests();
    restoreEnv("SYNC_DATABASE_URL", previousDatabaseURL);
    restoreEnv("SYNC_SCHEMA_MODE", previousSchemaMode);
  });

  it("records immutable checksums and makes repeated bootstrap a no-op", async () => {
    await withIsolatedSchema(async () => {
      await ensureSyncSchema();
      const first = await migrationRows();
      expect(first).toEqual(SYNC_MIGRATIONS.map(({ version, name, checksum }) => ({
        version,
        name,
        checksum
      })));

      await closeSyncPoolForTests();
      await ensureSyncSchema();
      expect(await migrationRows()).toEqual(first);
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();
    });
  });

  it("adopts the exact six-table HEAD baseline and applies new migrations", async () => {
    await withIsolatedSchema(async () => {
      await ensureSyncSchema();
      await getSyncPool().query("DROP TABLE account_deletion_receipts");
      await getSyncPool().query("DROP TABLE registration_usage");
      await getSyncPool().query("DROP TABLE session_grants");
      await getSyncPool().query("DROP TABLE vault_global_ingress_usage");
      await getSyncPool().query("DROP TABLE sync_schema_migrations");

      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).resolves.toBeUndefined();
      expect(await migrationRows()).toHaveLength(SYNC_MIGRATIONS.length);
      for (const table of [
        "registration_usage",
        "session_grants",
        "vault_global_ingress_usage",
        "account_deletion_receipts"
      ]) {
        const present = await getSyncPool().query<{ present: boolean }>(
          "SELECT to_regclass(format('%I.%I', current_schema(), $1::text)) IS NOT NULL AS present",
          [table]
        );
        expect(present.rows[0]?.present).toBe(true);
      }
    });
  });

  it("adopts this branch's exact nine-table pre-ledger schema", async () => {
    await withIsolatedSchema(async () => {
      await ensureSyncSchema();
      await getSyncPool().query("DROP TABLE account_deletion_receipts");
      await getSyncPool().query("DROP TABLE sync_schema_migrations");

      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).resolves.toBeUndefined();
      expect(await migrationRows()).toHaveLength(SYNC_MIGRATIONS.length);
    });
  });

  it("rejects an unversioned drifted schema without creating a ledger", async () => {
    await withIsolatedSchema(async () => {
      await ensureSyncSchema();
      await getSyncPool().query("DROP TABLE account_deletion_receipts");
      await getSyncPool().query("DROP TABLE sync_schema_migrations");
      await getSyncPool().query("ALTER TABLE users ADD COLUMN operator_drift text");

      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).rejects.toThrow(/column set differs/i);
      const ledger = await getSyncPool().query<{ present: boolean }>(
        "SELECT to_regclass(format('%I.sync_schema_migrations', current_schema())) IS NOT NULL AS present"
      );
      expect(ledger.rows[0]?.present).toBe(false);
    });
  });

  it("fails closed on modified or forward migration history", async () => {
    await withIsolatedSchema(async () => {
      await ensureSyncSchema();
      await getSyncPool().query(
        "UPDATE sync_schema_migrations SET checksum = $1 WHERE version = 2",
        ["0".repeat(64)]
      );
      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).rejects.toThrow(/unknown or modified/i);
    });

    await withIsolatedSchema(async () => {
      await ensureSyncSchema();
      await getSyncPool().query(
        `INSERT INTO sync_schema_migrations (version, name, checksum)
         VALUES ($1, $2, $3)`,
        [SYNC_MIGRATIONS.length + 1, "future-release", "f".repeat(64)]
      );
      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).rejects.toThrow(/newer than this server supports/i);
    });
  });

  it("resumes from the last durable migration after an interrupted upgrade", async () => {
    await withIsolatedSchema(async () => {
      await ensureSyncSchema();
      await getSyncPool().query("DROP TABLE account_deletion_receipts");
      await getSyncPool().query("DELETE FROM sync_schema_migrations WHERE version = 3");

      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).resolves.toBeUndefined();
      expect(await migrationRows()).toHaveLength(SYNC_MIGRATIONS.length);
      const receipts = await getSyncPool().query<{ present: boolean }>(
        `SELECT to_regclass(format('%I.account_deletion_receipts', current_schema())) IS NOT NULL
          AS present`
      );
      expect(receipts.rows[0]?.present).toBe(true);
    });
  });

  it("reconciles aggregate storage under a row lock without replaying migrations", async () => {
    await withIsolatedSchema(async () => {
      await ensureSyncSchema();
      const userId = randomUUID();
      await getSyncPool().query("INSERT INTO users (id) VALUES ($1)", [userId]);
      await getSyncPool().query(
        `INSERT INTO vault_snapshots (user_id, version, envelope, byte_size, checksum)
         VALUES ($1, 1, '{}'::jsonb, 321, $2)`,
        [userId, "a".repeat(64)]
      );
      await getSyncPool().query(
        `UPDATE sync_storage_usage
         SET total_snapshot_bytes = 999,
             reconciled_contract_version = 0,
             reconcile_required = true
         WHERE singleton = true`
      );

      await closeSyncPoolForTests();
      await ensureSyncSchema();
      const storage = await getSyncPool().query(
        `SELECT total_snapshot_bytes::text, reconciled_contract_version, reconcile_required
         FROM sync_storage_usage WHERE singleton = true`
      );
      expect(storage.rows[0]).toEqual({
        total_snapshot_bytes: "321",
        reconciled_contract_version: 1,
        reconcile_required: false
      });
      expect(await migrationRows()).toHaveLength(SYNC_MIGRATIONS.length);
    });
  });

  async function withIsolatedSchema(run: () => Promise<void>) {
    const schema = `migration_${randomUUID().replaceAll("-", "_")}`;
    const quotedSchema = `"${schema}"`;
    const baseDatabaseURL = process.env.TEST_SYNC_DATABASE_URL!;
    const isolatedDatabaseURL = new URL(baseDatabaseURL);
    isolatedDatabaseURL.searchParams.set("options", `-csearch_path=${schema}`);

    await getSyncPool().query(`CREATE SCHEMA ${quotedSchema}`);
    await closeSyncPoolForTests();
    process.env.SYNC_DATABASE_URL = isolatedDatabaseURL.toString();
    try {
      await run();
    } finally {
      await closeSyncPoolForTests();
      process.env.SYNC_DATABASE_URL = baseDatabaseURL;
      await getSyncPool().query(`DROP SCHEMA IF EXISTS ${quotedSchema} CASCADE`);
      await ensureSyncSchema();
    }
  }

  async function migrationRows() {
    const result = await getSyncPool().query<{
      version: number;
      name: string;
      checksum: string;
    }>(
      "SELECT version, name, checksum FROM sync_schema_migrations ORDER BY version"
    );
    return result.rows;
  }
});

function restoreEnv(name: string, value: string | undefined) {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}
