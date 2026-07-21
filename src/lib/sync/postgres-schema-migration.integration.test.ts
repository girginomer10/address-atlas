import { randomUUID } from "node:crypto";
import { types as pgTypes } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  PREPARED_SYNC_MIGRATIONS,
  STORAGE_RECONCILIATION_VERSION,
  SYNC_MIGRATIONS
} from "./postgres-migrations";
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
      const storage = await getSyncPool().query<{ attstorage: string }>(
        `SELECT attribute.attstorage::text AS attstorage
         FROM pg_catalog.pg_attribute AS attribute
         WHERE attribute.attrelid = 'vault_snapshots'::pg_catalog.regclass
           AND attribute.attname = 'envelope'`
      );
      expect(storage.rows[0]?.attstorage).toBe("e");
      const passkeyStorage = await getSyncPool().query<{
        column_name: string;
        attstorage: string;
      }>(
        `SELECT attribute.attname AS column_name,
                attribute.attstorage::text AS attstorage
         FROM pg_catalog.pg_attribute AS attribute
         WHERE attribute.attrelid = 'passkey_credentials'::pg_catalog.regclass
           AND attribute.attname = ANY($1::pg_catalog.text[])
         ORDER BY attribute.attname`,
        [["id", "public_key_base64url"]]
      );
      expect(passkeyStorage.rows).toEqual([
        { column_name: "id", attstorage: "e" },
        { column_name: "public_key_base64url", attstorage: "e" }
      ]);
    });
  });

  it("accepts the exact prepared next head as a healthy N-1 runtime", async () => {
    await withIsolatedSchema(async () => {
      await ensureSyncSchema();
      const prepared = PREPARED_SYNC_MIGRATIONS[0]!;

      // Release N already converges the storage policy. Prove the immutable
      // N+1 migration does not reacquire ACCESS EXCLUSIVE when it activates:
      // an unconditional ALTER would time out behind this reader lock.
      const reader = await getSyncPool().connect();
      const migrationRunner = await getSyncPool().connect();
      try {
        await reader.query("BEGIN");
        await reader.query("LOCK TABLE vault_snapshots IN ACCESS SHARE MODE");
        await migrationRunner.query("SET lock_timeout = '250ms'");
        await expect(migrationRunner.query(prepared.statements[0]!)).resolves.toBeDefined();
      } finally {
        await migrationRunner.query("RESET lock_timeout").catch(() => undefined);
        migrationRunner.release();
        await reader.query("ROLLBACK").catch(() => undefined);
        reader.release();
      }

      // The conditional expand step must still repair a skipped catalog
      // convergence; otherwise a predicate typo would turn it into a no-op.
      await getSyncPool().query(
        "ALTER TABLE vault_snapshots ALTER COLUMN envelope SET STORAGE EXTENDED"
      );
      await getSyncPool().query(prepared.statements[0]!);
      const repairedStorage = await getSyncPool().query<{ storage_policy: string }>(
        `SELECT attribute.attstorage::text AS storage_policy
         FROM pg_catalog.pg_attribute AS attribute
         WHERE attribute.attrelid = 'vault_snapshots'::pg_catalog.regclass
           AND attribute.attname = 'envelope'`
      );
      expect(repairedStorage.rows[0]?.storage_policy).toBe("e");

      for (const statement of prepared.statements) {
        await getSyncPool().query(statement);
      }
      await getSyncPool().query(
        `INSERT INTO sync_schema_migrations (version, name, checksum)
         VALUES ($1, $2, $3)`,
        [prepared.version, prepared.name, prepared.checksum]
      );

      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).resolves.toBeUndefined();
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();
      const preparedConstraint = await getSyncPool().query<{ validated: boolean }>(
        `SELECT constraint_row.convalidated AS validated
         FROM pg_catalog.pg_constraint AS constraint_row
         WHERE constraint_row.conrelid = 'vault_snapshots'::pg_catalog.regclass
           AND constraint_row.conname = 'vault_snapshots_envelope_storage_bound_check'`
      );
      expect(preparedConstraint.rows).toEqual([{ validated: false }]);

      const invalidUserId = randomUUID();
      await getSyncPool().query("INSERT INTO users (id) VALUES ($1)", [invalidUserId]);
      await expect(getSyncPool().query(
        `INSERT INTO vault_snapshots (user_id, version, envelope, byte_size, checksum)
         VALUES (
           $1,
           1,
           pg_catalog.jsonb_build_object('blob', pg_catalog.repeat('x', 8100000)),
           1,
           pg_catalog.repeat('a', 64)
         )`,
        [invalidUserId]
      )).rejects.toThrow(/vault_snapshots_envelope_storage_bound_check/i);
      expect(await migrationRows()).toEqual([
        ...SYNC_MIGRATIONS,
        prepared
      ].map(({ version, name, checksum }) => ({ version, name, checksum })));
    });
  });

  it("stages passkey storage idempotently and accepts the prepared v5 head", async () => {
    await withIsolatedSchema(async () => {
      await ensureSyncSchema();
      const vaultBound = PREPARED_SYNC_MIGRATIONS[0]!;
      const passkeyStorage = PREPARED_SYNC_MIGRATIONS[1]!;

      for (const statement of vaultBound.statements) {
        await getSyncPool().query(statement);
      }
      await getSyncPool().query(
        `INSERT INTO sync_schema_migrations (version, name, checksum)
         VALUES ($1, $2, $3)`,
        [vaultBound.version, vaultBound.name, vaultBound.checksum]
      );

      // Bootstrap already converged both attributes. The future immutable
      // migration must skip both ALTERs instead of waiting behind a reader.
      const reader = await getSyncPool().connect();
      const migrationRunner = await getSyncPool().connect();
      try {
        await reader.query("BEGIN");
        await reader.query("LOCK TABLE passkey_credentials IN ACCESS SHARE MODE");
        await migrationRunner.query("SET lock_timeout = '250ms'");
        await expect(migrationRunner.query(passkeyStorage.statements[0]!))
          .resolves.toBeDefined();
      } finally {
        await migrationRunner.query("RESET lock_timeout").catch(() => undefined);
        migrationRunner.release();
        await reader.query("ROLLBACK").catch(() => undefined);
        reader.release();
      }

      // A skipped convergence still gets repaired, and the same statement can
      // be run again without changing a compliant catalog.
      await getSyncPool().query(
        `ALTER TABLE passkey_credentials
           ALTER COLUMN id SET STORAGE EXTENDED,
           ALTER COLUMN public_key_base64url SET STORAGE EXTENDED`
      );
      await getSyncPool().query(passkeyStorage.statements[0]!);
      await getSyncPool().query(passkeyStorage.statements[0]!);
      const repaired = await getSyncPool().query<{
        column_name: string;
        storage_policy: string;
      }>(
        `SELECT attribute.attname AS column_name,
                attribute.attstorage::text AS storage_policy
         FROM pg_catalog.pg_attribute AS attribute
         WHERE attribute.attrelid = 'passkey_credentials'::pg_catalog.regclass
           AND attribute.attname = ANY($1::pg_catalog.text[])
         ORDER BY attribute.attname`,
        [["id", "public_key_base64url"]]
      );
      expect(repaired.rows).toEqual([
        { column_name: "id", storage_policy: "e" },
        { column_name: "public_key_base64url", storage_policy: "e" }
      ]);

      await getSyncPool().query(
        `INSERT INTO sync_schema_migrations (version, name, checksum)
         VALUES ($1, $2, $3)`,
        [passkeyStorage.version, passkeyStorage.name, passkeyStorage.checksum]
      );

      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).resolves.toBeUndefined();
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();
      const constraint = await getSyncPool().query<{ validated: boolean }>(
        `SELECT constraint_row.convalidated AS validated
         FROM pg_catalog.pg_constraint AS constraint_row
         WHERE constraint_row.conrelid = 'vault_snapshots'::pg_catalog.regclass
           AND constraint_row.conname = 'vault_snapshots_envelope_storage_bound_check'`
      );
      // Normal deployment never takes an unbounded historical vault scan.
      // The NOT VALID constraint still enforces every write after v4.
      expect(constraint.rows).toEqual([{ validated: false }]);
      expect(await migrationRows()).toEqual([
        ...SYNC_MIGRATIONS,
        ...PREPARED_SYNC_MIGRATIONS
      ].map(({ version, name, checksum }) => ({ version, name, checksum })));
    });
  });

  it("blocks cutover on legacy compressed vault data without rendering it", async () => {
    await withIsolatedSchema(async () => {
      await ensureSyncSchema();
      const userId = randomUUID();
      await getSyncPool().query("ALTER TABLE vault_snapshots ALTER COLUMN envelope SET STORAGE EXTENDED");
      await getSyncPool().query("INSERT INTO users (id) VALUES ($1)", [userId]);
      await getSyncPool().query(
        `INSERT INTO vault_snapshots (user_id, version, envelope, byte_size, checksum)
         VALUES (
           $1,
           1,
           pg_catalog.jsonb_build_object('blob', pg_catalog.repeat('x', 1000000)),
           1,
           pg_catalog.repeat('a', 64)
         )`,
        [userId]
      );
      await getSyncPool().query(
        `UPDATE sync_storage_usage
         SET total_snapshot_bytes = total_snapshot_bytes + 1,
             updated_at = now()
         WHERE singleton = true`
      );
      const compression = await getSyncPool().query<{ compression: string | null }>(
        `SELECT pg_catalog.pg_column_compression(envelope) AS compression
         FROM vault_snapshots
         WHERE user_id = $1`,
        [userId]
      );
      expect(compression.rows[0]?.compression).not.toBeNull();

      // SET STORAGE does not rewrite the already-compressed value.
      await getSyncPool().query("ALTER TABLE vault_snapshots ALTER COLUMN envelope SET STORAGE EXTERNAL");
      await closeSyncPoolForTests();

      const originalJSONBParser = pgTypes.getTypeParser(3802, "text");
      let jsonbDeserializations = 0;
      pgTypes.setTypeParser(3802, (value) => {
        jsonbDeserializations += 1;
        return originalJSONBParser(value);
      });
      try {
        await expect(ensureSyncSchema()).rejects.toThrow(/projection-safe/i);
        expect(jsonbDeserializations).toBe(0);
      } finally {
        pgTypes.setTypeParser(3802, originalJSONBParser);
      }

      await getSyncPool().query("DELETE FROM vault_snapshots WHERE user_id = $1", [userId]);
      await getSyncPool().query("DELETE FROM users WHERE id = $1", [userId]);
      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).resolves.toBeUndefined();
    });
  });

  it("blocks cutover on a legacy compressed passkey value", async () => {
    await withIsolatedSchema(async () => {
      await ensureSyncSchema();
      const userId = randomUUID();
      const credentialId = Buffer.from(`legacy-passkey:${userId}`).toString("base64url");
      await getSyncPool().query(
        `ALTER TABLE passkey_credentials
           ALTER COLUMN public_key_base64url SET STORAGE EXTENDED`
      );
      await getSyncPool().query("INSERT INTO users (id) VALUES ($1)", [userId]);
      await getSyncPool().query(
        `INSERT INTO passkey_credentials (id, user_id, public_key_base64url)
         VALUES ($1, $2, pg_catalog.repeat('A', 4096))`,
        [credentialId, userId]
      );
      const compression = await getSyncPool().query<{ compression: string | null }>(
        `SELECT pg_catalog.pg_column_compression(public_key_base64url) AS compression
         FROM passkey_credentials
         WHERE id = $1`,
        [credentialId]
      );
      expect(compression.rows[0]?.compression).not.toBeNull();

      // Catalog convergence is expand-only and cannot make the existing row
      // readable by the guarded authentication projection.
      await getSyncPool().query(
        `ALTER TABLE passkey_credentials
           ALTER COLUMN public_key_base64url SET STORAGE EXTERNAL`
      );
      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).rejects.toThrow(/projection-safe/i);

      await getSyncPool().query("DELETE FROM users WHERE id = $1", [userId]);
      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).resolves.toBeUndefined();
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
      await expect(ensureSyncSchema()).rejects.toThrow(/unknown or modified/i);
    });

    await withIsolatedSchema(async () => {
      await ensureSyncSchema();
      await getSyncPool().query(
        `INSERT INTO sync_schema_migrations (version, name, checksum)
         VALUES ($1, $2, $3)`,
        [
          SYNC_MIGRATIONS.length + PREPARED_SYNC_MIGRATIONS.length + 1,
          "unsupported-release",
          "e".repeat(64)
        ]
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
