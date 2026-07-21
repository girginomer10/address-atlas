import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { STORAGE_RECONCILIATION_VERSION, SYNC_MIGRATIONS } from "./postgres-migrations";
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

  it("rejects v1 surface drift before a pending migration mutates anything", async () => {
    await withIsolatedSchema(async () => {
      await ensureSyncSchema();
      await getSyncPool().query("DROP TABLE account_deletion_receipts");
      await getSyncPool().query("DROP TABLE vault_snapshots");
      await getSyncPool().query("DROP FUNCTION address_atlas_decrement_snapshot_usage()");
      await getSyncPool().query("DELETE FROM sync_schema_migrations WHERE version > 1");
      await getSyncPool().query(
        `UPDATE sync_storage_usage
         SET total_snapshot_bytes = 0,
             reconciled_contract_version = 0,
             reconcile_required = true,
             updated_at = '2000-01-01T00:00:00Z'::pg_catalog.timestamptz
         WHERE singleton = true`
      );

      // This is deliberately compatible enough for migration 002's
      // IF-NOT-EXISTS/function/trigger statements to succeed, but it is not a
      // version-1 object and must be rejected before any of those statements.
      await getSyncPool().query(
        `CREATE TABLE vault_snapshots (
           user_id pg_catalog.uuid PRIMARY KEY,
           byte_size pg_catalog.int4 NOT NULL,
           operator_drift pg_catalog.text NOT NULL
         )`
      );
      await getSyncPool().query(
        `CREATE FUNCTION address_atlas_decrement_snapshot_usage()
         RETURNS trigger
         LANGUAGE plpgsql
         AS $body$
         BEGIN
           RETURN OLD;
         END;
         $body$`
      );
      await getSyncPool().query(
        `CREATE TRIGGER address_atlas_snapshot_delete_usage
         BEFORE UPDATE ON vault_snapshots
         FOR EACH ROW EXECUTE FUNCTION address_atlas_decrement_snapshot_usage()`
      );

      const captureState = async () => {
        const result = await getSyncPool().query(
          `SELECT (
                    SELECT pg_catalog.jsonb_agg(
                      pg_catalog.jsonb_build_array(
                        ledger.version, ledger.name, ledger.checksum, ledger.applied_at::text
                      ) ORDER BY ledger.version
                    )
                    FROM sync_schema_migrations AS ledger
                  ) AS ledger,
                  pg_catalog.to_regclass(
                    pg_catalog.format('%I.vault_snapshots', current_schema())
                  )::pg_catalog.oid::text AS vault_oid,
                  (
                    SELECT pg_catalog.jsonb_agg(
                      pg_catalog.jsonb_build_array(
                        attribute.attname,
                        pg_catalog.format_type(attribute.atttypid, attribute.atttypmod),
                        attribute.attnotnull
                      ) ORDER BY attribute.attnum
                    )
                    FROM pg_catalog.pg_attribute AS attribute
                    WHERE attribute.attrelid = 'vault_snapshots'::pg_catalog.regclass
                      AND attribute.attnum > 0
                      AND NOT attribute.attisdropped
                  ) AS vault_columns,
                  pg_catalog.pg_get_functiondef(
                    'address_atlas_decrement_snapshot_usage()'::pg_catalog.regprocedure
                  ) AS function_definition,
                  (
                    SELECT pg_catalog.pg_get_triggerdef(trigger_row.oid, false)
                    FROM pg_catalog.pg_trigger AS trigger_row
                    WHERE trigger_row.tgrelid = 'vault_snapshots'::pg_catalog.regclass
                      AND trigger_row.tgname = 'address_atlas_snapshot_delete_usage'
                      AND NOT trigger_row.tgisinternal
                  ) AS trigger_definition,
                  (
                    SELECT pg_catalog.jsonb_build_array(
                      usage.total_snapshot_bytes::text,
                      usage.reconciled_contract_version,
                      usage.reconcile_required,
                      usage.updated_at::text
                    )
                    FROM sync_storage_usage AS usage
                    WHERE usage.singleton = true
                  ) AS storage,
                  pg_catalog.to_regclass(
                    pg_catalog.format('%I.account_deletion_receipts', current_schema())
                  ) IS NOT NULL AS receipts_present`
        );
        return result.rows[0];
      };
      const before = await captureState();

      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).rejects.toThrow(
        /relation set differs.*vault_snapshots/i
      );

      expect(await captureState()).toEqual(before);
      expect(await migrationRows()).toHaveLength(1);
      expect(before?.receipts_present).toBe(false);
    });
  });

  it("reconciles a stale aggregate under a row lock despite current markers", async () => {
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
             reconciled_contract_version = $1,
             reconcile_required = false
         WHERE singleton = true`,
        [STORAGE_RECONCILIATION_VERSION]
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
