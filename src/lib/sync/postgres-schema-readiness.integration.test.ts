import { randomUUID } from "node:crypto";
import { Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  checkSyncSchemaReadiness,
  closeSyncPoolForTests,
  ensureSyncSchema,
  getSyncPool
} from "./postgres";
import { assertSyncSchemaReady } from "./postgres-readiness";
import { SYNC_RUNTIME_PRIVILEGES } from "./postgres-schema-model";

const maybeDescribe = process.env.TEST_SYNC_DATABASE_URL ? describe : describe.skip;

maybeDescribe("diagnostic Postgres runtime readiness", () => {
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

  it("reports named drift and bootstrap does not silently repair it", async () => {
    await withIsolatedSchema(async () => {
      await ensureSyncSchema();

      await getSyncPool().query("ALTER TABLE users ADD COLUMN operator_drift text");
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/column set differs/i);
      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).rejects.toThrow(/column set differs/i);
      const extraColumn = await getSyncPool().query(
        `SELECT 1 FROM pg_catalog.pg_attribute
         WHERE attrelid = 'users'::regclass
           AND attname = 'operator_drift'
           AND NOT attisdropped`
      );
      expect(extraColumn.rowCount).toBe(1);
      await getSyncPool().query("ALTER TABLE users DROP COLUMN operator_drift");
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();

      await getSyncPool().query(
        "ALTER TABLE vault_snapshots DROP CONSTRAINT vault_snapshots_byte_size_bound_check"
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/constraint set differs/i);
      await getSyncPool().query(
        `ALTER TABLE vault_snapshots
         ADD CONSTRAINT vault_snapshots_byte_size_bound_check
         CHECK (byte_size BETWEEN 1 AND 8000000)`
      );
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();

      await getSyncPool().query("DROP INDEX session_grants_expires_at_idx");
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/index set differs/i);
      await getSyncPool().query(
        "CREATE INDEX session_grants_expires_at_idx ON session_grants (expires_at)"
      );
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();

      await getSyncPool().query(
        "ALTER TABLE vault_snapshots DISABLE TRIGGER address_atlas_snapshot_delete_usage"
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/trigger differs/i);
      await getSyncPool().query(
        "ALTER TABLE vault_snapshots ENABLE TRIGGER address_atlas_snapshot_delete_usage"
      );
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();
    });
  });

  it("keeps validate-only startup read-only on an empty schema", async () => {
    await withIsolatedSchema(async () => {
      process.env.SYNC_SCHEMA_MODE = "validate";
      await expect(ensureSyncSchema()).rejects.toThrow(/migration ledger is missing/i);
      const tables = await getSyncPool().query(
        `SELECT relname FROM pg_catalog.pg_class AS relation
         JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
         WHERE namespace.nspname = current_schema() AND relation.relkind = 'r'`
      );
      expect(tables.rows).toEqual([]);
      await closeSyncPoolForTests();
      process.env.SYNC_SCHEMA_MODE = "bootstrap";
      await expect(ensureSyncSchema()).resolves.toBeUndefined();
    }, false);
  });

  it("accepts a least-privilege DML role while denying schema DDL", async () => {
    await withIsolatedSchema(async (schema, isolatedDatabaseURL) => {
      await ensureSyncSchema();
      const role = `runtime_${randomUUID().replaceAll("-", "_")}`;
      const quotedRole = `"${role}"`;
      const rolePassword = `${randomUUID().replaceAll("-", "")}${randomUUID().replaceAll("-", "")}`;
      await getSyncPool().query(
        `CREATE ROLE ${quotedRole} LOGIN NOINHERIT PASSWORD '${rolePassword}'`
      );
      let runtimePool: Pool | undefined;
      try {
        await getSyncPool().query(`GRANT USAGE ON SCHEMA "${schema}" TO ${quotedRole}`);
        for (const [table, privileges] of Object.entries(SYNC_RUNTIME_PRIVILEGES)) {
          await getSyncPool().query(
            `GRANT ${privileges.join(", ")} ON TABLE "${table}" TO ${quotedRole}`
          );
        }
        await getSyncPool().query(
          `GRANT EXECUTE ON FUNCTION address_atlas_decrement_snapshot_usage() TO ${quotedRole}`
        );

        const runtimeURL = new URL(isolatedDatabaseURL);
        runtimeURL.username = role;
        runtimeURL.password = rolePassword;
        runtimePool = new Pool({ connectionString: runtimeURL.toString(), max: 1 });
        await expect(assertSyncSchemaReady(runtimePool)).resolves.toBeUndefined();

        const userId = randomUUID();
        await expect(runtimePool.query("INSERT INTO users (id) VALUES ($1)", [userId]))
          .resolves.toMatchObject({ rowCount: 1 });
        await expect(runtimePool.query("DELETE FROM users WHERE id = $1", [userId]))
          .resolves.toMatchObject({ rowCount: 1 });
        await expect(runtimePool.query("CREATE TABLE forbidden_runtime_ddl (id integer)"))
          .rejects.toThrow(/permission denied/i);
      } finally {
        await runtimePool?.end();
        await getSyncPool().query(`DROP OWNED BY ${quotedRole}`);
        await getSyncPool().query(`DROP ROLE ${quotedRole}`);
      }
    });
  });

  async function withIsolatedSchema(
    run: (schema: string, isolatedDatabaseURL: string) => Promise<void>,
    bootstrap = true
  ) {
    const schema = `readiness_${randomUUID().replaceAll("-", "_")}`;
    const quotedSchema = `"${schema}"`;
    const baseDatabaseURL = process.env.TEST_SYNC_DATABASE_URL!;
    const isolatedDatabaseURL = new URL(baseDatabaseURL);
    isolatedDatabaseURL.searchParams.set("options", `-csearch_path=${schema}`);

    await getSyncPool().query(`CREATE SCHEMA ${quotedSchema}`);
    await closeSyncPoolForTests();
    process.env.SYNC_DATABASE_URL = isolatedDatabaseURL.toString();
    try {
      if (bootstrap) await ensureSyncSchema();
      await run(schema, isolatedDatabaseURL.toString());
    } finally {
      await closeSyncPoolForTests();
      process.env.SYNC_SCHEMA_MODE = "bootstrap";
      process.env.SYNC_DATABASE_URL = baseDatabaseURL;
      await getSyncPool().query(`DROP SCHEMA IF EXISTS ${quotedSchema} CASCADE`);
      await ensureSyncSchema();
    }
  }
});

function restoreEnv(name: string, value: string | undefined) {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}
