import { randomUUID } from "node:crypto";
import { Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  checkSyncSchemaReadiness,
  closeSyncPoolForTests,
  ensureSyncSchema,
  getSyncPool
} from "./postgres";
import {
  assertSyncSchemaReady,
  type RuntimeDatabaseIdentity
} from "./postgres-readiness";
import { STORAGE_RECONCILIATION_VERSION } from "./postgres-migrations";
import { SYNC_RUNTIME_PRIVILEGES } from "./postgres-schema-model";
import { assertStoredPasskeyCredentialIntegrity } from "./passkey-credential-integrity";
import { StoredPasskeyCredentialIntegrityError } from "./stored-passkey-credential";
import {
  checkStorageLedgerIntegrity,
  resetStorageLedgerIntegrityForTests
} from "./storage-ledger-integrity";

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
         CHECK (byte_size BETWEEN 1 AND 7999999)`
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(
        /constraint vault_snapshots_byte_size_bound_check differs/i
      );
      await getSyncPool().query(
        "ALTER TABLE vault_snapshots DROP CONSTRAINT vault_snapshots_byte_size_bound_check"
      );
      await getSyncPool().query(
        `ALTER TABLE vault_snapshots
         ADD CONSTRAINT vault_snapshots_byte_size_bound_check
         CHECK (byte_size BETWEEN 1 AND 8000000)`
      );
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();

      await getSyncPool().query("DROP INDEX session_grants_expires_at_idx");
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/index set differs/i);
      await getSyncPool().query(
        "CREATE INDEX session_grants_expires_at_idx ON session_grants (user_id)"
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(
        /index session_grants_expires_at_idx differs/i
      );
      await getSyncPool().query("DROP INDEX session_grants_expires_at_idx");
      for (const driftedDefinition of [
        "CREATE UNIQUE INDEX session_grants_expires_at_idx ON session_grants (expires_at)",
        "CREATE INDEX session_grants_expires_at_idx ON session_grants USING hash (expires_at)",
        "CREATE INDEX session_grants_expires_at_idx ON session_grants (expires_at DESC)",
        `CREATE INDEX session_grants_expires_at_idx ON session_grants (expires_at)
         WITH (fillfactor = 70)`
      ]) {
        await getSyncPool().query(driftedDefinition);
        await expect(checkSyncSchemaReadiness()).rejects.toThrow(
          /index session_grants_expires_at_idx differs/i
        );
        await getSyncPool().query("DROP INDEX session_grants_expires_at_idx");
      }
      await getSyncPool().query(
        "CREATE INDEX session_grants_expires_at_idx ON session_grants (expires_at)"
      );
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();

      await getSyncPool().query(
        "ALTER TABLE session_grants DROP CONSTRAINT session_grants_user_id_fkey"
      );
      await getSyncPool().query(
        `ALTER TABLE session_grants
         ADD CONSTRAINT session_grants_user_id_fkey
         FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT`
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(
        /constraint session_grants_user_id_fkey differs/i
      );
      await getSyncPool().query(
        "ALTER TABLE session_grants DROP CONSTRAINT session_grants_user_id_fkey"
      );
      await getSyncPool().query(
        `ALTER TABLE session_grants
         ADD CONSTRAINT session_grants_user_id_fkey
         FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE`
      );
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();

      await getSyncPool().query(
        "ALTER TABLE vault_write_usage DROP CONSTRAINT vault_write_usage_pkey"
      );
      await getSyncPool().query(
        `ALTER TABLE vault_write_usage
         ADD CONSTRAINT vault_write_usage_pkey PRIMARY KEY (usage_date, user_id)`
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(
        /constraint vault_write_usage_pkey differs/i
      );
      await getSyncPool().query(
        "ALTER TABLE vault_write_usage DROP CONSTRAINT vault_write_usage_pkey"
      );
      await getSyncPool().query(
        `ALTER TABLE vault_write_usage
         ADD CONSTRAINT vault_write_usage_pkey PRIMARY KEY (user_id, usage_date)`
      );
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();

      const originalFunction = await getSyncPool().query<{ definition: string }>(
        `SELECT pg_catalog.pg_get_functiondef(
           'address_atlas_decrement_snapshot_usage()'::regprocedure
         ) AS definition`
      );
      const functionDefinition = originalFunction.rows[0]?.definition;
      expect(functionDefinition).toBeTypeOf("string");
      await getSyncPool().query(
        `CREATE OR REPLACE FUNCTION address_atlas_decrement_snapshot_usage()
         RETURNS trigger
         LANGUAGE plpgsql
         AS $body$
         BEGIN
           RETURN OLD;
         END;
         $body$`
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/vault accounting trigger differs/i);
      await getSyncPool().query(functionDefinition!);
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();

      await getSyncPool().query(
        "ALTER FUNCTION address_atlas_decrement_snapshot_usage() SET search_path TO pg_catalog"
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/vault accounting trigger differs/i);
      await getSyncPool().query(
        "ALTER FUNCTION address_atlas_decrement_snapshot_usage() RESET search_path"
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
      await expect(ensureSyncSchema()).rejects.toThrow(/runtime database identity|migration ledger/i);
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

  it("keeps schema readiness constant-time while periodic integrity detects aggregate drift", async () => {
    await withIsolatedSchema(async () => {
      await ensureSyncSchema();
      const userId = randomUUID();
      await getSyncPool().query("INSERT INTO users (id) VALUES ($1)", [userId]);
      await getSyncPool().query(
        `INSERT INTO vault_snapshots (user_id, version, envelope, byte_size, checksum)
         VALUES ($1, 1, '{}'::jsonb, 321, $2)`,
        [userId, "b".repeat(64)]
      );
      await getSyncPool().query(
        `UPDATE sync_storage_usage
         SET total_snapshot_bytes = 321,
             reconciled_contract_version = $1,
             reconcile_required = false
         WHERE singleton = true`,
        [STORAGE_RECONCILIATION_VERSION]
      );
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();
      resetStorageLedgerIntegrityForTests();
      await expect(checkStorageLedgerIntegrity()).resolves.toBeUndefined();

      await getSyncPool().query(
        `UPDATE sync_storage_usage
         SET total_snapshot_bytes = 320, reconcile_required = false
         WHERE singleton = true`
      );
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();
      resetStorageLedgerIntegrityForTests();
      await expect(checkStorageLedgerIntegrity()).rejects.toMatchObject({
        operationalCode: "storage_ledger_invalid"
      });

      await getSyncPool().query(
        `UPDATE sync_storage_usage
         SET total_snapshot_bytes = 322, reconcile_required = false
         WHERE singleton = true`
      );
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();
      resetStorageLedgerIntegrityForTests();
      await expect(checkStorageLedgerIntegrity()).rejects.toMatchObject({
        operationalCode: "storage_ledger_invalid"
      });

      await getSyncPool().query(
        `UPDATE sync_storage_usage
         SET total_snapshot_bytes = 321, reconcile_required = false
         WHERE singleton = true`
      );
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();
      resetStorageLedgerIntegrityForTests();
      await expect(checkStorageLedgerIntegrity()).resolves.toBeUndefined();
    });
  });

  it("rejects a restored account that has no credential capable of recovering it", async () => {
    await withIsolatedSchema(async () => {
      await ensureSyncSchema();
      const userId = randomUUID();
      await getSyncPool().query("INSERT INTO users (id) VALUES ($1)", [userId]);

      await expect(assertStoredPasskeyCredentialIntegrity(getSyncPool()))
        .rejects.toBeInstanceOf(StoredPasskeyCredentialIntegrityError);

      const credentialId = Buffer.from(`credential:${userId}`).toString("base64url");
      const publicKey = Buffer.from(
        "a50102032620012158206b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2962258204fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
        "hex"
      ).toString("base64url");
      await getSyncPool().query(
        `INSERT INTO passkey_credentials (id, user_id, public_key_base64url)
         VALUES ($1, $2, $3)`,
        [credentialId, userId, publicKey]
      );

      await expect(assertStoredPasskeyCredentialIntegrity(getSyncPool()))
        .resolves.toBeUndefined();
    });
  });

  it("rejects exact default, type, collation, rule, and inheritance drift", async () => {
    await withIsolatedSchema(async (schema) => {
      await ensureSyncSchema();

      await getSyncPool().query(
        "ALTER TABLE consumed_challenges ALTER COLUMN consumed_at SET DEFAULT to_timestamp(0)"
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/consumed_challenges\.consumed_at/i);
      await getSyncPool().query(
        "ALTER TABLE consumed_challenges ALTER COLUMN consumed_at SET DEFAULT now()"
      );

      await getSyncPool().query(
        `ALTER TABLE users ALTER COLUMN id
         SET DEFAULT '00000000-0000-0000-0000-000000000000'::pg_catalog.uuid`
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/column users\.id/i);
      await getSyncPool().query("ALTER TABLE users ALTER COLUMN id DROP DEFAULT");

      await getSyncPool().query(
        "ALTER TABLE users ALTER COLUMN created_at TYPE pg_catalog.timestamptz(3)"
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/column users\.created_at/i);
      await getSyncPool().query(
        "ALTER TABLE users ALTER COLUMN created_at TYPE pg_catalog.timestamptz"
      );

      await getSyncPool().query(
        "ALTER TABLE passkey_credentials ALTER COLUMN id TYPE pg_catalog.text COLLATE pg_catalog.\"C\""
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/column passkey_credentials\.id/i);
      await getSyncPool().query(
        "ALTER TABLE passkey_credentials ALTER COLUMN id TYPE pg_catalog.text COLLATE pg_catalog.\"default\""
      );

      const quotedSchema = `"${schema}"`;
      await getSyncPool().query(`CREATE DOMAIN ${quotedSchema}.text AS pg_catalog.text`);
      await getSyncPool().query(
        `ALTER TABLE consumed_challenges ALTER COLUMN challenge
         TYPE ${quotedSchema}.text USING challenge::${quotedSchema}.text`
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/column consumed_challenges\.challenge/i);
      await getSyncPool().query(
        `ALTER TABLE consumed_challenges ALTER COLUMN challenge
         TYPE pg_catalog.text USING challenge::pg_catalog.text`
      );
      await getSyncPool().query(`DROP DOMAIN ${quotedSchema}.text`);

      await getSyncPool().query(
        "CREATE RULE users_readiness_rule AS ON UPDATE TO users DO ALSO NOTHING"
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/table users has unsupported behavior/i);
      await getSyncPool().query("DROP RULE users_readiness_rule ON users");

      await getSyncPool().query("CREATE TABLE users_readiness_child () INHERITS (users)");
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/table users has unsupported behavior/i);
      await getSyncPool().query("DROP TABLE users_readiness_child");

      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();
    });
  });

  it("rejects owner-only objects outside the exact schema surface", async () => {
    await withIsolatedSchema(async () => {
      await ensureSyncSchema();
      const drifts = [
        {
          create: "CREATE TABLE readiness_extra_table (value pg_catalog.int4)",
          restrict: "REVOKE ALL PRIVILEGES ON TABLE readiness_extra_table FROM PUBLIC",
          drop: "DROP TABLE readiness_extra_table",
          error: /relation set differs.*readiness_extra_table/i
        },
        {
          create: "CREATE SEQUENCE readiness_extra_sequence",
          restrict: "REVOKE ALL PRIVILEGES ON SEQUENCE readiness_extra_sequence FROM PUBLIC",
          drop: "DROP SEQUENCE readiness_extra_sequence",
          error: /relation set differs.*readiness_extra_sequence/i
        },
        {
          create: "CREATE VIEW readiness_extra_view AS SELECT id FROM users",
          restrict: "REVOKE ALL PRIVILEGES ON TABLE readiness_extra_view FROM PUBLIC",
          drop: "DROP VIEW readiness_extra_view",
          error: /relation set differs.*readiness_extra_view/i
        },
        {
          create: `CREATE MATERIALIZED VIEW readiness_extra_materialized_view
                   AS SELECT id FROM users WITH NO DATA`,
          restrict:
            "REVOKE ALL PRIVILEGES ON TABLE readiness_extra_materialized_view FROM PUBLIC",
          drop: "DROP MATERIALIZED VIEW readiness_extra_materialized_view",
          error: /relation set differs.*readiness_extra_materialized_view/i
        },
        {
          create: `CREATE FUNCTION readiness_extra_function()
                   RETURNS pg_catalog.int4
                   LANGUAGE sql IMMUTABLE PARALLEL SAFE
                   AS $body$ SELECT 1 $body$`,
          restrict:
            "REVOKE ALL PRIVILEGES ON FUNCTION readiness_extra_function() FROM PUBLIC",
          drop: "DROP FUNCTION readiness_extra_function()",
          error: /routine set differs.*readiness_extra_function/i
        },
        {
          create: "CREATE DOMAIN readiness_extra_domain AS pg_catalog.text",
          restrict: "REVOKE ALL PRIVILEGES ON TYPE readiness_extra_domain FROM PUBLIC",
          drop: "DROP DOMAIN readiness_extra_domain",
          error: /type set differs.*readiness_extra_domain/i
        },
        {
          create: "CREATE TYPE readiness_extra_enum AS ENUM ('value')",
          restrict: "REVOKE ALL PRIVILEGES ON TYPE readiness_extra_enum FROM PUBLIC",
          drop: "DROP TYPE readiness_extra_enum",
          error: /type set differs.*readiness_extra_enum/i
        },
        {
          create: "CREATE TYPE readiness_extra_range AS RANGE (subtype = pg_catalog.int4)",
          restrict: "REVOKE ALL PRIVILEGES ON TYPE readiness_extra_range FROM PUBLIC",
          drop: "DROP TYPE readiness_extra_range",
          // PostgreSQL 16 also installs range/multirange constructor routines.
          error: /routine set differs.*readiness_extra_multirange/i
        },
        {
          create: "CREATE TYPE readiness_extra_composite AS (value pg_catalog.int4)",
          restrict: "REVOKE ALL PRIVILEGES ON TYPE readiness_extra_composite FROM PUBLIC",
          drop: "DROP TYPE readiness_extra_composite",
          error: /relation set differs.*readiness_extra_composite/i
        }
      ] as const;

      for (const drift of drifts) {
        await getSyncPool().query(drift.create);
        try {
          await getSyncPool().query(drift.restrict);
          await expect(checkSyncSchemaReadiness()).rejects.toThrow(drift.error);
        } finally {
          await getSyncPool().query(drift.drop);
        }
        await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();
      }
    });
  });

  it("accepts only the exact runtime role and rejects authority or grant drift", async () => {
    await withIsolatedDatabase(async (database, isolatedDatabaseURL) => {
      await ensureSyncSchema();
      const role = `runtime_${randomUUID().replaceAll("-", "_")}`;
      const adminRole = `admin_${randomUUID().replaceAll("-", "_")}`;
      const observerRole = `observer_${randomUUID().replaceAll("-", "_")}`;
      const quotedRole = `"${role}"`;
      const quotedAdminRole = `"${adminRole}"`;
      const quotedObserverRole = `"${observerRole}"`;
      const quotedDatabase = `"${database}"`;
      const rolePassword = `${randomUUID().replaceAll("-", "")}${randomUUID().replaceAll("-", "")}`;
      const identity: RuntimeDatabaseIdentity = {
        database,
        schema: "public",
        runtimeRole: role,
        ownerRole: "address_atlas",
        adminRole
      };
      await getSyncPool().query(`CREATE ROLE ${quotedAdminRole} NOLOGIN NOINHERIT`);
      await getSyncPool().query(`CREATE ROLE ${quotedObserverRole} NOLOGIN NOINHERIT`);
      await getSyncPool().query(`CREATE ROLE ${quotedRole} LOGIN NOINHERIT PASSWORD '${rolePassword}'`);
      let runtimePool: Pool | undefined;
      try {
        await getSyncPool().query("ALTER SCHEMA public OWNER TO address_atlas");
        await getSyncPool().query(
          `REVOKE ALL PRIVILEGES ON DATABASE ${quotedDatabase}
           FROM PUBLIC, ${quotedAdminRole}, ${quotedRole}, ${quotedObserverRole}`
        );
        await getSyncPool().query(
          `GRANT CONNECT ON DATABASE ${quotedDatabase} TO ${quotedAdminRole}, ${quotedRole}`
        );
        await getSyncPool().query(
          `REVOKE ALL PRIVILEGES ON SCHEMA public
           FROM PUBLIC, ${quotedAdminRole}, ${quotedRole}, ${quotedObserverRole}`
        );
        await getSyncPool().query(
          `GRANT USAGE ON SCHEMA public TO address_atlas, ${quotedAdminRole}, ${quotedRole}`
        );
        await getSyncPool().query(
          `REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public
           FROM PUBLIC, ${quotedAdminRole}, ${quotedRole}, ${quotedObserverRole}`
        );
        for (const [table, privileges] of Object.entries(SYNC_RUNTIME_PRIVILEGES)) {
          await getSyncPool().query(
            `GRANT ${privileges.join(", ")} ON TABLE "${table}" TO ${quotedRole}`
          );
        }
        await getSyncPool().query(
          `REVOKE ALL PRIVILEGES ON FUNCTION address_atlas_decrement_snapshot_usage()
           FROM PUBLIC, ${quotedAdminRole}, ${quotedRole}, ${quotedObserverRole}`
        );
        for (const [defaultOwner, revokedGrantees] of [
          ["address_atlas", `PUBLIC, ${quotedAdminRole}, ${quotedRole}, ${quotedObserverRole}`],
          [quotedAdminRole, `PUBLIC, address_atlas, ${quotedRole}, ${quotedObserverRole}`]
        ] as const) {
          await getSyncPool().query(
            `ALTER DEFAULT PRIVILEGES FOR ROLE ${defaultOwner}
             REVOKE ALL PRIVILEGES ON ROUTINES
             FROM ${revokedGrantees}`
          );
          await getSyncPool().query(
            `ALTER DEFAULT PRIVILEGES FOR ROLE ${defaultOwner}
             REVOKE ALL PRIVILEGES ON TYPES
             FROM ${revokedGrantees}`
          );
        }

        const runtimeURL = new URL(isolatedDatabaseURL);
        runtimeURL.username = role;
        runtimeURL.password = rolePassword;
        runtimePool = new Pool({ connectionString: runtimeURL.toString(), max: 1 });
        const assertRuntimeReady = () => assertSyncSchemaReady(runtimePool!, {
          expectedRuntimeIdentity: identity
        });
        await expect(assertSyncSchemaReady(runtimePool)).rejects.toThrow(
          /runtime database identity or search path/i
        );
        await expect(assertRuntimeReady()).resolves.toBeUndefined();
        await expect(assertSyncSchemaReady(getSyncPool(), {
          expectedRuntimeIdentity: identity
        })).rejects.toThrow(
          /runtime database identity or search path/i
        );

        const userId = randomUUID();
        await expect(runtimePool.query("INSERT INTO users (id) VALUES ($1)", [userId]))
          .resolves.toMatchObject({ rowCount: 1 });
        await expect(runtimePool.query(
          `INSERT INTO vault_snapshots (user_id, version, envelope, byte_size, checksum)
           VALUES ($1, 1, '{}'::jsonb, 17, $2)`,
          [userId, "c".repeat(64)]
        )).resolves.toMatchObject({ rowCount: 1 });
        await expect(runtimePool.query(
          "UPDATE sync_storage_usage SET total_snapshot_bytes = 17 WHERE singleton = true"
        )).resolves.toMatchObject({ rowCount: 1 });
        await expect(runtimePool.query("DELETE FROM users WHERE id = $1", [userId]))
          .resolves.toMatchObject({ rowCount: 1 });
        await expect(runtimePool.query(
          "SELECT total_snapshot_bytes::text FROM sync_storage_usage WHERE singleton = true"
        )).resolves.toMatchObject({ rows: [{ total_snapshot_bytes: "0" }] });
        await expect(runtimePool.query("CREATE TABLE forbidden_runtime_ddl (id integer)"))
          .rejects.toThrow(/permission denied/i);

        await getSyncPool().query(`GRANT TRUNCATE ON TABLE users TO ${quotedRole}`);
        await expect(assertRuntimeReady()).rejects.toThrow(/unexpected TRUNCATE/i);
        await getSyncPool().query(`REVOKE TRUNCATE ON TABLE users FROM ${quotedRole}`);
        await expect(assertRuntimeReady()).resolves.toBeUndefined();

        await getSyncPool().query(
          `GRANT SELECT ON TABLE users TO ${quotedRole} WITH GRANT OPTION`
        );
        await expect(assertRuntimeReady()).rejects.toThrow(/table ACLs differ/i);
        await getSyncPool().query(
          `REVOKE GRANT OPTION FOR SELECT ON TABLE users FROM ${quotedRole}`
        );
        await expect(assertRuntimeReady()).resolves.toBeUndefined();

        await getSyncPool().query(`GRANT SELECT ON TABLE users TO ${quotedObserverRole}`);
        await expect(assertRuntimeReady()).rejects.toThrow(/table ACLs differ/i);
        await getSyncPool().query(`REVOKE SELECT ON TABLE users FROM ${quotedObserverRole}`);
        await expect(assertRuntimeReady()).resolves.toBeUndefined();

        await getSyncPool().query(`REVOKE SELECT ON TABLE users FROM ${quotedRole}`);
        await getSyncPool().query("GRANT SELECT ON TABLE users TO PUBLIC");
        await expect(assertRuntimeReady()).rejects.toThrow(/table ACLs differ/i);
        await getSyncPool().query("REVOKE SELECT ON TABLE users FROM PUBLIC");
        await getSyncPool().query(`GRANT SELECT ON TABLE users TO ${quotedRole}`);
        await expect(assertRuntimeReady()).resolves.toBeUndefined();

        await getSyncPool().query(`GRANT UPDATE (id) ON TABLE users TO ${quotedRole}`);
        await expect(assertRuntimeReady()).rejects.toThrow(/column ACLs differ/i);
        await getSyncPool().query(`REVOKE UPDATE (id) ON TABLE users FROM ${quotedRole}`);
        await expect(assertRuntimeReady()).resolves.toBeUndefined();

        await getSyncPool().query("CREATE TABLE readiness_extra_table (id integer)");
        await getSyncPool().query(`GRANT SELECT ON readiness_extra_table TO ${quotedRole}`);
        await expect(assertRuntimeReady()).rejects.toThrow(
          /unexpected SELECT on readiness_extra_table/i
        );
        await getSyncPool().query("DROP TABLE readiness_extra_table");
        await expect(assertRuntimeReady()).resolves.toBeUndefined();

        await getSyncPool().query(
          `GRANT EXECUTE ON FUNCTION address_atlas_decrement_snapshot_usage() TO ${quotedRole}`
        );
        await expect(assertRuntimeReady()).rejects.toThrow(/routine ACLs differ/i);
        await getSyncPool().query(
          `REVOKE EXECUTE ON FUNCTION address_atlas_decrement_snapshot_usage() FROM ${quotedRole}`
        );
        await expect(assertRuntimeReady()).resolves.toBeUndefined();

        await getSyncPool().query(`GRANT USAGE ON SCHEMA public TO ${quotedObserverRole}`);
        await expect(assertRuntimeReady()).rejects.toThrow(/schema ACLs differ/i);
        await getSyncPool().query(`REVOKE USAGE ON SCHEMA public FROM ${quotedObserverRole}`);

        await getSyncPool().query(`GRANT CONNECT ON DATABASE ${quotedDatabase} TO ${quotedObserverRole}`);
        await expect(assertRuntimeReady()).rejects.toThrow(/database ACLs differ/i);
        await getSyncPool().query(`REVOKE CONNECT ON DATABASE ${quotedDatabase} FROM ${quotedObserverRole}`);

        await getSyncPool().query(`GRANT CREATE ON SCHEMA public TO ${quotedRole}`);
        await expect(assertRuntimeReady()).rejects.toThrow(/authority exceeds/i);
        await getSyncPool().query(`REVOKE CREATE ON SCHEMA public FROM ${quotedRole}`);

        await getSyncPool().query(
          `GRANT CREATE ON DATABASE ${quotedDatabase} TO ${quotedRole}`
        );
        await expect(assertRuntimeReady()).rejects.toThrow(/authority exceeds/i);
        await getSyncPool().query(
          `REVOKE CREATE ON DATABASE ${quotedDatabase} FROM ${quotedRole}`
        );

        await getSyncPool().query(
          `GRANT TEMPORARY ON DATABASE ${quotedDatabase} TO ${quotedRole}`
        );
        await expect(assertRuntimeReady()).rejects.toThrow(/authority exceeds/i);
        await getSyncPool().query(
          `REVOKE TEMPORARY ON DATABASE ${quotedDatabase} FROM ${quotedRole}`
        );

        for (const [enable, disable] of [
          ["SUPERUSER", "NOSUPERUSER"],
          ["CREATEDB", "NOCREATEDB"],
          ["CREATEROLE", "NOCREATEROLE"],
          ["REPLICATION", "NOREPLICATION"],
          ["BYPASSRLS", "NOBYPASSRLS"],
          ["INHERIT", "NOINHERIT"]
        ] as const) {
          await getSyncPool().query(`ALTER ROLE ${quotedRole} ${enable}`);
          await expect(assertRuntimeReady()).rejects.toThrow(/authority exceeds/i);
          await getSyncPool().query(`ALTER ROLE ${quotedRole} ${disable}`);
        }

        await getSyncPool().query(
          `ALTER ROLE ${quotedRole} SET statement_timeout TO '5s'`
        );
        await expect(assertRuntimeReady()).rejects.toThrow(/authority exceeds/i);
        await getSyncPool().query(`ALTER ROLE ${quotedRole} RESET statement_timeout`);

        await getSyncPool().query(
          `ALTER ROLE ${quotedRole} VALID UNTIL '2030-01-01T00:00:00Z'`
        );
        await expect(assertRuntimeReady()).rejects.toThrow(/authority exceeds/i);
        await getSyncPool().query(`ALTER ROLE ${quotedRole} VALID UNTIL 'infinity'`);

        const membershipRole = `membership_${randomUUID().replaceAll("-", "_")}`;
        const quotedMembershipRole = `"${membershipRole}"`;
        await getSyncPool().query(`CREATE ROLE ${quotedMembershipRole} NOLOGIN`);
        try {
          await getSyncPool().query(`GRANT ${quotedMembershipRole} TO ${quotedRole}`);
          await expect(assertRuntimeReady()).rejects.toThrow(/runtime database identity|authority exceeds/i);
          await getSyncPool().query(`REVOKE ${quotedMembershipRole} FROM ${quotedRole}`);
        } finally {
          await getSyncPool().query(`DROP ROLE ${quotedMembershipRole}`);
        }

        await getSyncPool().query(`GRANT address_atlas TO ${quotedObserverRole}`);
        await expect(assertRuntimeReady()).rejects.toThrow(/runtime database identity/i);
        await getSyncPool().query(`REVOKE address_atlas FROM ${quotedObserverRole}`);

        await getSyncPool().query(
          `ALTER DEFAULT PRIVILEGES FOR ROLE address_atlas
           GRANT SELECT ON TABLES TO ${quotedObserverRole}`
        );
        await expect(assertRuntimeReady()).rejects.toThrow(/default ACLs differ/i);
        await getSyncPool().query(
          `ALTER DEFAULT PRIVILEGES FOR ROLE address_atlas
           REVOKE SELECT ON TABLES FROM ${quotedObserverRole}`
        );

        await expect(assertRuntimeReady()).resolves.toBeUndefined();
      } finally {
        await runtimePool?.end();
        for (const quotedCleanupRole of [quotedObserverRole, quotedRole, quotedAdminRole]) {
          await getSyncPool().query(`DROP OWNED BY ${quotedCleanupRole}`);
          await getSyncPool().query(`DROP ROLE ${quotedCleanupRole}`);
        }
      }
    });
  });

  async function withIsolatedDatabase(
    run: (database: string, isolatedDatabaseURL: string) => Promise<void>
  ) {
    const database = `readiness_${randomUUID().replaceAll("-", "_")}`;
    const quotedDatabase = `"${database}"`;
    const baseDatabaseURL = process.env.TEST_SYNC_DATABASE_URL!;
    const isolatedDatabaseURL = new URL(baseDatabaseURL);
    isolatedDatabaseURL.pathname = `/${database}`;
    isolatedDatabaseURL.search = "";
    isolatedDatabaseURL.hash = "";

    await getSyncPool().query(
      `CREATE DATABASE ${quotedDatabase} OWNER address_atlas TEMPLATE template0`
    );
    await closeSyncPoolForTests();
    process.env.SYNC_DATABASE_URL = isolatedDatabaseURL.toString();
    try {
      await run(database, isolatedDatabaseURL.toString());
    } finally {
      await closeSyncPoolForTests();
      process.env.SYNC_SCHEMA_MODE = "bootstrap";
      process.env.SYNC_DATABASE_URL = baseDatabaseURL;
      await getSyncPool().query(`DROP DATABASE IF EXISTS ${quotedDatabase} WITH (FORCE)`);
      await ensureSyncSchema();
    }
  }

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
