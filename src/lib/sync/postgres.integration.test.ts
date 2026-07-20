import { createHash, randomUUID } from "node:crypto";
import { NextRequest } from "next/server";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { GET as getHealth, resetHealthReadinessForTests } from "@/app/healthz/route";
import { GET as getLatestVault, PUT as putLatestVault } from "@/app/vault/latest/route";
import { base64urlEncode } from "./base64url";
import {
  canonicalEnvelopeBytes,
  computeSnapshotChecksum,
  type EncryptedVaultEnvelope,
  type RemoteVaultSnapshot
} from "./envelope";
import {
  checkSyncSchemaReadiness,
  closeSyncPoolForTests,
  ensureSyncSchema,
  getSyncPool
} from "./postgres";
import { resetRateLimitsForTests } from "./rate-limit";
import { issueSessionToken } from "./tokens";
import { saveVaultSnapshot, VaultConflictError, VaultQuotaError } from "./vault-storage";

const maybeDescribe = process.env.TEST_SYNC_DATABASE_URL ? describe : describe.skip;

maybeDescribe("encrypted sync Postgres storage", () => {
  const testUserIds = new Set<string>();
  let previousDatabaseURL: string | undefined;
  let previousSessionSecret: string | undefined;
  let previousByteLimit: string | undefined;
  let previousWriteLimit: string | undefined;

  beforeAll(async () => {
    previousDatabaseURL = process.env.SYNC_DATABASE_URL;
    previousSessionSecret = process.env.SYNC_SESSION_SECRET;
    previousByteLimit = process.env.SYNC_VAULT_DAILY_BYTE_LIMIT;
    previousWriteLimit = process.env.SYNC_VAULT_DAILY_WRITE_LIMIT;
    process.env.SYNC_DATABASE_URL = process.env.TEST_SYNC_DATABASE_URL;
    process.env.SYNC_SESSION_SECRET = "ci-only-public-session-secret-for-integration-tests";
    await ensureSyncSchema();
  });

  afterEach(async () => {
    resetRateLimitsForTests();
    restoreEnv("SYNC_VAULT_DAILY_BYTE_LIMIT", previousByteLimit);
    restoreEnv("SYNC_VAULT_DAILY_WRITE_LIMIT", previousWriteLimit);
    if (testUserIds.size > 0) {
      await getSyncPool().query("DELETE FROM users WHERE id = ANY($1::uuid[])", [[...testUserIds]]);
      testUserIds.clear();
    }
  });

  afterAll(async () => {
    await closeSyncPoolForTests();
    restoreEnv("SYNC_DATABASE_URL", previousDatabaseURL);
    restoreEnv("SYNC_SESSION_SECRET", previousSessionSecret);
    restoreEnv("SYNC_VAULT_DAILY_BYTE_LIMIT", previousByteLimit);
    restoreEnv("SYNC_VAULT_DAILY_WRITE_LIMIT", previousWriteLimit);
  });

  async function createUser() {
    const userId = randomUUID();
    testUserIds.add(userId);
    await getSyncPool().query("INSERT INTO users (id) VALUES ($1)", [userId]);
    return userId;
  }

  it("stores only opaque vault snapshot data", async () => {
    const pool = getSyncPool();
    const userId = await createUser();
    const snapshot = {
      schemaVersion: 1,
      cryptoVersion: 1,
      keyId: "sync-v1",
      nonce: "abc123_-",
      ciphertext: "opaqueCiphertext_-",
      checksum: "b".repeat(64)
    };
    const checksum = "a".repeat(64);
    const plaintextMarkers = [
      "0x742d35cc6634c0532925a3b844bc454e4438f44e",
      "wallet-alpha",
      "12345.67",
      "binance-secret-key",
      "usdc-token-list",
      "scan-run-history",
      "preferred-currency"
    ];

    const byteSize = JSON.stringify(snapshot).length;
    await pool.query(
      `INSERT INTO vault_snapshots (user_id, version, envelope, byte_size, checksum)
       VALUES ($1, $2, $3::jsonb, $4, $5)`,
      [userId, 1, JSON.stringify(snapshot), byteSize, checksum]
    );
    // This bypasses saveVaultSnapshot, so mirror its global-counter charge:
    // the strict delete trigger fails closed if the cascade decrement at
    // cleanup would push the counter below zero.
    await pool.query(
      `UPDATE sync_storage_usage
       SET total_snapshot_bytes = total_snapshot_bytes + $1, updated_at = now()
       WHERE singleton = true`,
      [byteSize]
    );

    const result = await pool.query(
      "SELECT user_id, version, envelope, byte_size, checksum FROM vault_snapshots WHERE user_id = $1",
      [userId]
    );
    const serialized = JSON.stringify(result.rows[0]).toLowerCase();

    expect(serialized).toContain("opaqueciphertext");
    for (const marker of plaintextMarkers) {
      expect(serialized).not.toContain(marker);
    }
  });

  it("fails closed on runtime schema drift and repairs only data-safe contract damage", async () => {
    const schema = `readiness_${randomUUID().replaceAll("-", "_")}`;
    const quotedSchema = `"${schema}"`;
    const baseDatabaseURL = process.env.TEST_SYNC_DATABASE_URL!;
    const isolatedDatabaseURL = new URL(baseDatabaseURL);
    isolatedDatabaseURL.searchParams.set("options", `-csearch_path=${schema}`);

    await getSyncPool().query(`CREATE SCHEMA ${quotedSchema}`);
    await closeSyncPoolForTests();
    process.env.SYNC_DATABASE_URL = isolatedDatabaseURL.toString();
    try {
      const restartAndAssertReady = async () => {
        await closeSyncPoolForTests();
        await ensureSyncSchema();
        await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();
      };

      await ensureSyncSchema();
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();

      const assertSessionModeNotReady = async (setting: string) => {
        await closeSyncPoolForTests();
        const modeURL = new URL(baseDatabaseURL);
        modeURL.searchParams.set("options", `-csearch_path=${schema} ${setting}`);
        process.env.SYNC_DATABASE_URL = modeURL.toString();
        await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
        await closeSyncPoolForTests();
        process.env.SYNC_DATABASE_URL = isolatedDatabaseURL.toString();
      };

      await assertSessionModeNotReady("-cdefault_transaction_read_only=on");
      await assertSessionModeNotReady("-csession_replication_role=replica");

      // Additive rolling deployments may leave plain nullable built-in columns
      // and fixed-width tuning indexes. They cannot affect explicit writes.
      await getSyncPool().query("ALTER TABLE users ADD COLUMN rollout_note text");
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();
      await getSyncPool().query("ALTER TABLE users DROP COLUMN rollout_note");
      await getSyncPool().query(
        "CREATE INDEX vault_snapshots_version_tuning_idx ON vault_snapshots (version)"
      );
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();
      await getSyncPool().query("DROP INDEX vault_snapshots_version_tuning_idx");

      // Varlena, expression, partial, and custom-access-method indexes can
      // execute code or reject valid writes and therefore remain fail-closed.
      await getSyncPool().query(
        "CREATE INDEX vault_snapshots_envelope_unsafe_idx ON vault_snapshots (envelope)"
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await getSyncPool().query("DROP INDEX vault_snapshots_envelope_unsafe_idx");
      await getSyncPool().query(
        "CREATE INDEX vault_snapshots_expression_unsafe_idx ON vault_snapshots ((version + 1))"
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await getSyncPool().query("DROP INDEX vault_snapshots_expression_unsafe_idx");
      await getSyncPool().query(
        "CREATE INDEX vault_snapshots_partial_unsafe_idx ON vault_snapshots (version) WHERE version > 1"
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await getSyncPool().query("DROP INDEX vault_snapshots_partial_unsafe_idx");
      await getSyncPool().query(
        "CREATE INDEX vault_snapshots_brin_unsafe_idx ON vault_snapshots USING brin (version)"
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await getSyncPool().query("DROP INDEX vault_snapshots_brin_unsafe_idx");

      // Relation shape is checked after initialization rather than inferred
      // from the once-resolved schema promise.
      await getSyncPool().query("ALTER TABLE vault_snapshots RENAME TO vault_snapshots_missing");
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);

      await getSyncPool().query("ALTER TABLE vault_snapshots_missing RENAME TO vault_snapshots");
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();

      // Defaults are runtime behavior: challenge inserts intentionally omit
      // consumed_at. Startup can restore the default without rewriting data.
      const challenge = `default-${randomUUID()}`;
      await getSyncPool().query("ALTER TABLE consumed_challenges ALTER COLUMN consumed_at DROP DEFAULT");
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await expect(
        getSyncPool().query("INSERT INTO consumed_challenges (challenge) VALUES ($1)", [challenge])
      ).rejects.toThrow(/null value/i);
      await restartAndAssertReady();
      await expect(
        getSyncPool().query("INSERT INTO consumed_challenges (challenge) VALUES ($1)", [challenge])
      ).resolves.toMatchObject({ rowCount: 1 });

      // Required nullability is equally repairable when existing rows satisfy
      // it; initialization validates before restoring the flag.
      await getSyncPool().query("ALTER TABLE vault_snapshots ALTER COLUMN version DROP NOT NULL");
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await restartAndAssertReady();

      // SimpleWebAuthn signCount is uint32, while node-postgres exposes BIGINT
      // as text and the runtime converts it with Number(). The database must
      // reject negative, oversized, and unsafe legacy values before that cast.
      const counterUser = randomUUID();
      const invalidCredential = `invalid-counter-${randomUUID()}`;
      await getSyncPool().query("INSERT INTO users (id) VALUES ($1)", [counterUser]);
      await getSyncPool().query(
        `ALTER TABLE passkey_credentials
         DROP CONSTRAINT passkey_credentials_counter_uint32_check`
      );
      await getSyncPool().query(
        `INSERT INTO passkey_credentials (id, user_id, public_key_base64url, counter)
         VALUES ($1, $2, 'AA', 4294967296)`,
        [invalidCredential, counterUser]
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).rejects.toThrow();
      await closeSyncPoolForTests();
      await getSyncPool().query("DELETE FROM passkey_credentials WHERE id = $1", [invalidCredential]);
      await restartAndAssertReady();
      await expect(
        getSyncPool().query(
          `INSERT INTO passkey_credentials (id, user_id, public_key_base64url, counter)
           VALUES ($1, $2, 'AA', -1)`,
          [`negative-counter-${randomUUID()}`, counterUser]
        )
      ).rejects.toThrow(/passkey_credentials_counter_uint32_check/i);

      // Representative ON CONFLICT arbiters are functional runtime
      // dependencies, not optional metadata. Missing either one below makes a
      // normal vault write fail.
      const snapshotUser = randomUUID();
      await getSyncPool().query("INSERT INTO users (id) VALUES ($1)", [snapshotUser]);
      await getSyncPool().query("ALTER TABLE vault_snapshots DROP CONSTRAINT vault_snapshots_pkey");
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await expect(saveVaultSnapshot(snapshotUser, remoteSnapshot(1, "g"), 500))
        .rejects.toThrow(/unique or exclusion constraint/i);
      await restartAndAssertReady();
      await expect(saveVaultSnapshot(snapshotUser, remoteSnapshot(1, "g"), 500))
        .resolves.toEqual({ idempotent: false });

      const quotaUser = randomUUID();
      await getSyncPool().query("INSERT INTO users (id) VALUES ($1)", [quotaUser]);
      await getSyncPool().query("ALTER TABLE vault_write_usage DROP CONSTRAINT vault_write_usage_pkey");
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await expect(saveVaultSnapshot(quotaUser, remoteSnapshot(1, "h"), 500))
        .rejects.toThrow(/unique or exclusion constraint/i);
      await restartAndAssertReady();
      await expect(saveVaultSnapshot(quotaUser, remoteSnapshot(1, "h"), 500))
        .resolves.toEqual({ idempotent: false });

      // Database bounds protect quota arithmetic even from direct/legacy SQL.
      await expect(
        getSyncPool().query(
          `INSERT INTO vault_snapshots (user_id, version, envelope, byte_size, checksum)
           VALUES ($1, 0, '{}'::jsonb, 200, $2)`,
          [counterUser, "v".repeat(64)]
        )
      ).rejects.toThrow(/version_bound/i);
      await expect(
        getSyncPool().query(
          `INSERT INTO vault_snapshots (user_id, version, envelope, byte_size, checksum)
           VALUES ($1, 1, '{}'::jsonb, 8000001, $2)`,
          [counterUser, "b".repeat(64)]
        )
      ).rejects.toThrow(/byte_size_bound/i);

      // Reconciliation is explicit and versioned: ordinary health stays cheap,
      // while a marked counter is repaired exactly once under the row lock.
      await getSyncPool().query(
        `UPDATE sync_storage_usage
         SET total_snapshot_bytes = 1, reconcile_required = true
         WHERE singleton = true`
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await restartAndAssertReady();
      const reconciledUsage = await getSyncPool().query(
        `SELECT total_snapshot_bytes, reconciled_contract_version, reconcile_required
         FROM sync_storage_usage WHERE singleton = true`
      );
      expect(Number(reconciledUsage.rows[0]?.total_snapshot_bytes)).toBe(400);
      expect(reconciledUsage.rows[0]).toMatchObject({
        reconciled_contract_version: 1,
        reconcile_required: false
      });

      // PostgreSQL can arbitrate ON CONFLICT with either a primary key or a
      // non-deferrable UNIQUE constraint. A deferrable UNIQUE is not a valid
      // arbiter and must not make readiness green.
      await getSyncPool().query(
        "ALTER TABLE consumed_challenges DROP CONSTRAINT consumed_challenges_pkey"
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await getSyncPool().query(
        `ALTER TABLE consumed_challenges
         ADD CONSTRAINT consumed_challenges_challenge_key UNIQUE (challenge)`
      );
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();
      await getSyncPool().query(
        "ALTER TABLE consumed_challenges DROP CONSTRAINT consumed_challenges_challenge_key"
      );
      await getSyncPool().query(
        `ALTER TABLE consumed_challenges
         ADD CONSTRAINT consumed_challenges_challenge_key
         UNIQUE (challenge) DEFERRABLE INITIALLY IMMEDIATE`
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await getSyncPool().query(
        "ALTER TABLE consumed_challenges DROP CONSTRAINT consumed_challenges_challenge_key"
      );
      await restartAndAssertReady();

      // Missing canonical FK/check/index objects are safe to add and validate.
      await getSyncPool().query(
        "ALTER TABLE vault_snapshots DROP CONSTRAINT vault_snapshots_user_id_fkey"
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await restartAndAssertReady();

      // Semantically exact renamed NOT VALID objects are safe to validate in
      // place, while duplicate equivalents remain ambiguous and fail closed.
      await getSyncPool().query(
        "ALTER TABLE vault_snapshots DROP CONSTRAINT vault_snapshots_user_id_fkey"
      );
      await getSyncPool().query(
        `ALTER TABLE vault_snapshots
         ADD CONSTRAINT vault_snapshots_user_id_pending_fk
         FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE NOT VALID`
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await restartAndAssertReady();
      const validatedRenamedFK = await getSyncPool().query(
        `SELECT convalidated FROM pg_catalog.pg_constraint
         WHERE conname = 'vault_snapshots_user_id_pending_fk'`
      );
      expect(validatedRenamedFK.rows[0]?.convalidated).toBe(true);
      await getSyncPool().query(
        "ALTER TABLE vault_snapshots DROP CONSTRAINT vault_snapshots_user_id_pending_fk"
      );
      await restartAndAssertReady();

      await getSyncPool().query(
        `ALTER TABLE vault_snapshots
         ADD CONSTRAINT vault_snapshots_duplicate_user_fk
         FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE`
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).rejects.toThrow();
      await closeSyncPoolForTests();
      await getSyncPool().query(
        "ALTER TABLE vault_snapshots DROP CONSTRAINT vault_snapshots_duplicate_user_fk"
      );
      await restartAndAssertReady();

      await getSyncPool().query(
        "ALTER TABLE vault_snapshots DROP CONSTRAINT vault_snapshots_version_bound_check"
      );
      await getSyncPool().query(
        `ALTER TABLE vault_snapshots
         ADD CONSTRAINT vault_snapshots_version_pending_check
         CHECK (version BETWEEN 1 AND 2000000000) NOT VALID`
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await restartAndAssertReady();
      const validatedRenamedCheck = await getSyncPool().query(
        `SELECT convalidated FROM pg_catalog.pg_constraint
         WHERE conname = 'vault_snapshots_version_pending_check'`
      );
      expect(validatedRenamedCheck.rows[0]?.convalidated).toBe(true);
      await getSyncPool().query(
        "ALTER TABLE vault_snapshots DROP CONSTRAINT vault_snapshots_version_pending_check"
      );
      await restartAndAssertReady();

      // pg_constraint can still look correct after a superuser disables the
      // internal RI triggers that actually enforce inserts and cascades.
      await getSyncPool().query("ALTER TABLE passkey_credentials DISABLE TRIGGER ALL");
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await getSyncPool().query("ALTER TABLE passkey_credentials ENABLE TRIGGER ALL");
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();

      // A same-name FK with weaker delete semantics is not safe to replace
      // automatically because an operator may need to repair orphaned rows.
      await getSyncPool().query(
        "ALTER TABLE vault_snapshots DROP CONSTRAINT vault_snapshots_user_id_fkey"
      );
      await getSyncPool().query(
        `ALTER TABLE vault_snapshots
         ADD CONSTRAINT vault_snapshots_user_id_fkey
         FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE NO ACTION`
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).rejects.toThrow();
      await closeSyncPoolForTests();
      await getSyncPool().query(
        "ALTER TABLE vault_snapshots DROP CONSTRAINT vault_snapshots_user_id_fkey"
      );
      await restartAndAssertReady();

      await getSyncPool().query(
        "ALTER TABLE sync_storage_usage DROP CONSTRAINT sync_storage_usage_total_snapshot_bytes_check"
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await restartAndAssertReady();

      // A same-name but weaker check would admit a negative aggregate and make
      // the capacity gate lie. Its expression is part of the contract.
      await getSyncPool().query(
        "ALTER TABLE sync_storage_usage DROP CONSTRAINT sync_storage_usage_total_snapshot_bytes_check"
      );
      await getSyncPool().query(
        `ALTER TABLE sync_storage_usage
         ADD CONSTRAINT sync_storage_usage_total_snapshot_bytes_check
         CHECK (total_snapshot_bytes >= -1)`
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).rejects.toThrow();
      await closeSyncPoolForTests();
      await getSyncPool().query(
        "ALTER TABLE sync_storage_usage DROP CONSTRAINT sync_storage_usage_total_snapshot_bytes_check"
      );
      await restartAndAssertReady();

      await getSyncPool().query("DROP INDEX consumed_challenges_consumed_at_idx");
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await restartAndAssertReady();

      await getSyncPool().query("DROP INDEX consumed_challenges_consumed_at_idx");
      await getSyncPool().query(
        "CREATE INDEX consumed_challenges_consumed_at_idx ON consumed_challenges (challenge)"
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).rejects.toThrow();
      await closeSyncPoolForTests();
      await getSyncPool().query("DROP INDEX consumed_challenges_consumed_at_idx");
      await restartAndAssertReady();

      await getSyncPool().query("ALTER TABLE vault_snapshots DISABLE TRIGGER address_atlas_snapshot_delete_usage");
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);

      await getSyncPool().query("ALTER TABLE vault_snapshots ENABLE TRIGGER address_atlas_snapshot_delete_usage");
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();

      await getSyncPool().query("DROP TRIGGER address_atlas_snapshot_delete_usage ON vault_snapshots");
      await getSyncPool().query(`
        CREATE TRIGGER address_atlas_snapshot_delete_usage
        AFTER DELETE ON vault_snapshots
        FOR EACH ROW WHEN (false)
        EXECUTE FUNCTION address_atlas_decrement_snapshot_usage()
      `);
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);

      await getSyncPool().query(
        `UPDATE sync_storage_usage
         SET total_snapshot_bytes = 1, reconcile_required = false
         WHERE singleton = true`
      );

      // A fresh startup repairs a same-event trigger whose WHEN clause makes it
      // behaviorally inert, marks reconciliation, and repairs any missed delta.
      await restartAndAssertReady();
      const triggerReconciledUsage = await getSyncPool().query(
        `SELECT total_snapshot_bytes, reconcile_required
         FROM sync_storage_usage WHERE singleton = true`
      );
      expect(Number(triggerReconciledUsage.rows[0]?.total_snapshot_bytes)).toBe(400);
      expect(triggerReconciledUsage.rows[0]?.reconcile_required).toBe(false);

      await getSyncPool().query("DROP TRIGGER address_atlas_snapshot_delete_usage ON vault_snapshots");
      await getSyncPool().query(`
        CREATE TRIGGER address_atlas_snapshot_delete_usage
        BEFORE UPDATE ON vault_snapshots
        FOR EACH STATEMENT EXECUTE FUNCTION address_atlas_decrement_snapshot_usage()
      `);
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);

      // A fresh startup must repair a same-name trigger with the wrong event,
      // timing, or granularity rather than trusting its name alone.
      await restartAndAssertReady();

      // A trigger can retain the right name/event/function OID while the
      // function body and volatility make it a no-op. Readiness inspects both.
      await getSyncPool().query(`
        CREATE OR REPLACE FUNCTION address_atlas_decrement_snapshot_usage()
        RETURNS trigger
        LANGUAGE plpgsql
        STABLE
        AS $$
        BEGIN
          RETURN OLD;
        END;
        $$
      `);
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await restartAndAssertReady();

      // The body alone is insufficient: SECURITY DEFINER or a captured
      // search_path changes which privileges/schema the trigger uses.
      await getSyncPool().query(
        "ALTER FUNCTION address_atlas_decrement_snapshot_usage() SECURITY DEFINER"
      );
      await getSyncPool().query(
        "ALTER FUNCTION address_atlas_decrement_snapshot_usage() SET search_path = pg_catalog"
      );
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await restartAndAssertReady();

      // A missing or corrupt global counter must block a cascade/delete rather
      // than silently clamp to zero and lose accounting information.
      await getSyncPool().query(
        `UPDATE sync_storage_usage
         SET total_snapshot_bytes = 0, reconcile_required = false
         WHERE singleton = true`
      );
      await expect(
        getSyncPool().query("DELETE FROM vault_snapshots WHERE user_id = $1", [snapshotUser])
      ).rejects.toThrow(/usage counter is missing or inconsistent/i);
      const retainedSnapshot = await getSyncPool().query(
        "SELECT 1 FROM vault_snapshots WHERE user_id = $1",
        [snapshotUser]
      );
      expect(retainedSnapshot.rowCount).toBe(1);
      await getSyncPool().query(
        "UPDATE sync_storage_usage SET reconcile_required = true WHERE singleton = true"
      );
      await restartAndAssertReady();

      const beforeDelete = await getSyncPool().query(
        "SELECT total_snapshot_bytes FROM sync_storage_usage WHERE singleton = true"
      );
      expect(Number(beforeDelete.rows[0]?.total_snapshot_bytes)).toBe(400);
      await getSyncPool().query("DELETE FROM vault_snapshots WHERE user_id = $1", [snapshotUser]);
      const afterDelete = await getSyncPool().query(
        "SELECT total_snapshot_bytes FROM sync_storage_usage WHERE singleton = true"
      );
      expect(Number(afterDelete.rows[0]?.total_snapshot_bytes)).toBe(200);

      // A type change is not guessed away. bigint makes node-postgres decode
      // version as a string, violating the strict number comparisons in the
      // vault state machine, so both readiness and initialization fail closed.
      await getSyncPool().query("ALTER TABLE vault_snapshots ALTER COLUMN version TYPE bigint");
      await expect(checkSyncSchemaReadiness()).rejects.toThrow(/schema is not ready/i);
      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).rejects.toThrow();

      await closeSyncPoolForTests();
      await getSyncPool().query(
        "ALTER TABLE vault_snapshots ALTER COLUMN version TYPE integer USING version::integer"
      );
      await restartAndAssertReady();
    } finally {
      await closeSyncPoolForTests();
      process.env.SYNC_DATABASE_URL = baseDatabaseURL;
      await getSyncPool().query(`DROP SCHEMA IF EXISTS ${quotedSchema} CASCADE`);
      await ensureSyncSchema();
    }
  }, 120_000);

  it("migrates the legacy storage counter and trigger without losing vault usage", async () => {
    const schema = `legacy_${randomUUID().replaceAll("-", "_")}`;
    const quotedSchema = `"${schema}"`;
    const baseDatabaseURL = process.env.TEST_SYNC_DATABASE_URL!;
    const isolatedDatabaseURL = new URL(baseDatabaseURL);
    isolatedDatabaseURL.searchParams.set("options", `-csearch_path=${schema}`);

    await getSyncPool().query(`CREATE SCHEMA ${quotedSchema}`);
    await closeSyncPoolForTests();
    process.env.SYNC_DATABASE_URL = isolatedDatabaseURL.toString();
    try {
      const legacyUser = randomUUID();
      await getSyncPool().query(`
        CREATE TABLE users (
          id uuid PRIMARY KEY,
          created_at timestamptz NOT NULL DEFAULT now(),
          updated_at timestamptz NOT NULL DEFAULT now()
        )
      `);
      await getSyncPool().query(`
        CREATE TABLE sync_storage_usage (
          singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
          total_snapshot_bytes bigint NOT NULL CHECK (total_snapshot_bytes >= 0),
          updated_at timestamptz NOT NULL DEFAULT now()
        )
      `);
      await getSyncPool().query(`
        CREATE TABLE vault_snapshots (
          user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
          version integer NOT NULL,
          envelope jsonb NOT NULL,
          byte_size integer NOT NULL,
          checksum text NOT NULL,
          created_at timestamptz NOT NULL DEFAULT now(),
          updated_at timestamptz NOT NULL DEFAULT now()
        )
      `);
      await getSyncPool().query("INSERT INTO users (id) VALUES ($1)", [legacyUser]);
      await getSyncPool().query(
        `INSERT INTO vault_snapshots (user_id, version, envelope, byte_size, checksum)
         VALUES ($1, 1, '{}'::jsonb, 321, $2)`,
        [legacyUser, "l".repeat(64)]
      );
      await getSyncPool().query(
        `INSERT INTO sync_storage_usage (singleton, total_snapshot_bytes)
         VALUES (true, 999)`
      );
      await getSyncPool().query(`
        CREATE FUNCTION address_atlas_decrement_snapshot_usage()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
          UPDATE sync_storage_usage
          SET total_snapshot_bytes = GREATEST(total_snapshot_bytes - OLD.byte_size, 0),
              updated_at = now()
          WHERE singleton = true;
          RETURN OLD;
        END;
        $$
      `);
      await getSyncPool().query(`
        CREATE TRIGGER address_atlas_snapshot_delete_usage
        AFTER DELETE ON vault_snapshots
        FOR EACH ROW EXECUTE FUNCTION address_atlas_decrement_snapshot_usage()
      `);

      await getSyncPool().query("CREATE TABLE storage_bootstrap_audit (event text NOT NULL)");
      await getSyncPool().query(`
        CREATE FUNCTION record_unsafe_storage_bootstrap()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
          INSERT INTO storage_bootstrap_audit (event) VALUES (TG_OP);
          RETURN NEW;
        END;
        $$
      `);
      await getSyncPool().query(`
        CREATE TRIGGER unsafe_storage_bootstrap
        BEFORE INSERT OR UPDATE ON sync_storage_usage
        FOR EACH ROW EXECUTE FUNCTION record_unsafe_storage_bootstrap()
      `);

      await closeSyncPoolForTests();
      await expect(ensureSyncSchema()).rejects.toThrow(/bootstrap surface contains unsafe behavior/i);
      await closeSyncPoolForTests();
      const audit = await getSyncPool().query("SELECT event FROM storage_bootstrap_audit");
      expect(audit.rows).toEqual([]);
      await getSyncPool().query("DROP TRIGGER unsafe_storage_bootstrap ON sync_storage_usage");
      await getSyncPool().query("DROP FUNCTION record_unsafe_storage_bootstrap()");

      await closeSyncPoolForTests();
      await ensureSyncSchema();
      await expect(checkSyncSchemaReadiness()).resolves.toBeUndefined();

      const storage = await getSyncPool().query(
        `SELECT total_snapshot_bytes, reconciled_contract_version, reconcile_required
         FROM sync_storage_usage WHERE singleton = true`
      );
      expect(Number(storage.rows[0]?.total_snapshot_bytes)).toBe(321);
      expect(storage.rows[0]).toMatchObject({
        reconciled_contract_version: 1,
        reconcile_required: false
      });

      const metadata = await getSyncPool().query(
        `SELECT column_name, data_type, is_nullable, column_default
         FROM information_schema.columns
         WHERE table_schema = current_schema()
           AND table_name = 'sync_storage_usage'
           AND column_name IN ('reconciled_contract_version', 'reconcile_required')
         ORDER BY column_name`
      );
      expect(metadata.rows).toEqual([
        expect.objectContaining({
          column_name: "reconcile_required",
          data_type: "boolean",
          is_nullable: "NO",
          column_default: "true"
        }),
        expect.objectContaining({
          column_name: "reconciled_contract_version",
          data_type: "integer",
          is_nullable: "NO",
          column_default: "0"
        })
      ]);

      const triggerFunction = await getSyncPool().query(
        `SELECT proc.prosrc
         FROM pg_catalog.pg_proc AS proc
         JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = proc.pronamespace
         WHERE namespace.nspname = current_schema()
           AND proc.proname = 'address_atlas_decrement_snapshot_usage'`
      );
      expect(String(triggerFunction.rows[0]?.prosrc)).toContain("TG_TABLE_SCHEMA");
      expect(String(triggerFunction.rows[0]?.prosrc)).toContain("updated_rows <> 1");
    } finally {
      await closeSyncPoolForTests();
      process.env.SYNC_DATABASE_URL = baseDatabaseURL;
      await getSyncPool().query(`DROP SCHEMA IF EXISTS ${quotedSchema} CASCADE`);
      await ensureSyncSchema();
    }
  }, 60_000);

  it("returns 404 for a real account that has no vault snapshot", async () => {
    const userId = await createUser();

    const response = await getLatestVault(vaultRequest(issueSessionToken(userId)));

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "No vault snapshot." });
  });

  it("returns 401 when a real account is deleted after its session was issued", async () => {
    const userId = await createUser();
    const sessionToken = issueSessionToken(userId);
    await getSyncPool().query("DELETE FROM users WHERE id = $1", [userId]);

    const response = await getLatestVault(vaultRequest(sessionToken));

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "Authentication required." });
  });

  it("round-trips an uploaded snapshot through the real PUT and GET handlers", async () => {
    const userId = await createUser();
    const sessionToken = issueSessionToken(userId);
    const snapshot = uploadableSnapshot(3, 7);

    const putResponse = await putLatestVault(new NextRequest("http://localhost/vault/latest", {
      method: "PUT",
      headers: {
        authorization: `Bearer ${sessionToken}`,
        "content-type": "application/json"
      },
      body: JSON.stringify(snapshot)
    }));

    expect(putResponse.status).toBe(200);
    expect(await putResponse.json()).toEqual({ ok: true, idempotent: false });

    const getResponse = await getLatestVault(vaultRequest(sessionToken));

    expect(getResponse.status).toBe(200);
    expect(getResponse.headers.get("cache-control")).toBe("no-store");
    const body = await getResponse.json();
    expect(body).toEqual({
      version: snapshot.version,
      envelope: snapshot.envelope,
      byteSize: snapshot.byteSize,
      checksum: snapshot.checksum,
      updatedAt: expect.any(String)
    });
    expect(new Date(body.updatedAt).toISOString()).toBe(body.updatedAt);
  });

  it("reports healthy from the real health route against the real database", async () => {
    resetHealthReadinessForTests();

    const response = await getHealth();

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ ok: true, service: "address-atlas-sync" });
  });

  it("charges real request bytes for a rejected conflict without incrementing writes", async () => {
    const userId = await createUser();
    const original = remoteSnapshot(2, "a");
    await saveVaultSnapshot(userId, original, 500);

    await expect(saveVaultSnapshot(userId, remoteSnapshot(2, "b"), 700))
      .rejects.toBeInstanceOf(VaultConflictError);

    const stored = await getSyncPool().query(
      "SELECT version, checksum FROM vault_snapshots WHERE user_id = $1",
      [userId]
    );
    const usage = await getSyncPool().query(
      "SELECT write_count, byte_count FROM vault_write_usage WHERE user_id = $1",
      [userId]
    );
    expect(stored.rows[0]).toMatchObject({ version: 2, checksum: original.checksum });
    expect(Number(usage.rows[0]?.write_count)).toBe(1);
    expect(Number(usage.rows[0]?.byte_count)).toBe(1_200);
  });

  it("rolls back the snapshot when the real daily quota SQL rejects a write", async () => {
    process.env.SYNC_VAULT_DAILY_WRITE_LIMIT = "1";
    const userId = await createUser();
    const original = remoteSnapshot(1, "c");
    await saveVaultSnapshot(userId, original, 500);

    await expect(saveVaultSnapshot(userId, remoteSnapshot(2, "d"), 700))
      .rejects.toBeInstanceOf(VaultQuotaError);

    const stored = await getSyncPool().query(
      "SELECT version, checksum FROM vault_snapshots WHERE user_id = $1",
      [userId]
    );
    const usage = await getSyncPool().query(
      "SELECT write_count, byte_count FROM vault_write_usage WHERE user_id = $1",
      [userId]
    );
    expect(stored.rows[0]).toMatchObject({ version: 1, checksum: original.checksum });
    expect(Number(usage.rows[0]?.write_count)).toBe(1);
    expect(Number(usage.rows[0]?.byte_count)).toBe(500);
  });

  it("charges exact-retry bytes without incrementing the real write counter", async () => {
    process.env.SYNC_VAULT_DAILY_WRITE_LIMIT = "1";
    const userId = await createUser();
    const snapshot = remoteSnapshot(1, "e");
    await saveVaultSnapshot(userId, snapshot, 500);
    await expect(saveVaultSnapshot(userId, snapshot, 500)).resolves.toEqual({ idempotent: true });

    const usage = await getSyncPool().query(
      "SELECT write_count, byte_count FROM vault_write_usage WHERE user_id = $1",
      [userId]
    );
    expect(usage.rows[0]).toMatchObject({ write_count: 1 });
    expect(Number(usage.rows[0]?.byte_count)).toBe(1_000);
  });

  it("rejects an exact replay atomically when its byte charge exceeds the daily cap", async () => {
    process.env.SYNC_VAULT_DAILY_BYTE_LIMIT = "8100000";
    const userId = await createUser();
    const snapshot = remoteSnapshot(1, "f");
    await saveVaultSnapshot(userId, snapshot, 4_100_000);

    await expect(saveVaultSnapshot(userId, snapshot, 4_100_000))
      .rejects.toBeInstanceOf(VaultQuotaError);

    const usage = await getSyncPool().query(
      "SELECT write_count, byte_count FROM vault_write_usage WHERE user_id = $1",
      [userId]
    );
    expect(usage.rows[0]).toMatchObject({ write_count: 1 });
    expect(Number(usage.rows[0]?.byte_count)).toBe(4_100_000);
  });
});

function vaultRequest(sessionToken: string) {
  return new NextRequest("http://localhost/vault/latest", {
    headers: { authorization: `Bearer ${sessionToken}` }
  });
}

/** A v2 snapshot whose inner and outer checksums survive the route's real validation chain. */
function uploadableSnapshot(version: number, fill: number): RemoteVaultSnapshot {
  const nonce = Buffer.alloc(12, fill);
  const ciphertext = Buffer.alloc(48, fill + 1);
  const envelope: EncryptedVaultEnvelope = {
    schemaVersion: 2,
    cryptoVersion: 2,
    keyId: "sync-v2",
    nonce: base64urlEncode(nonce),
    ciphertext: base64urlEncode(ciphertext),
    checksum: createHash("sha256")
      .update(Buffer.from("schema:2|crypto:2|key:sync-v2|", "utf8"))
      .update(nonce)
      .update(ciphertext)
      .digest("hex"),
    createdAt: "2026-07-13T10:00:00Z"
  };
  const canonical = canonicalEnvelopeBytes(envelope);
  return {
    version,
    envelope,
    byteSize: canonical.byteLength,
    checksum: computeSnapshotChecksum(version, envelope, canonical)
  };
}

function remoteSnapshot(version: number, marker: string): RemoteVaultSnapshot {
  return {
    version,
    byteSize: 200,
    checksum: marker.repeat(64),
    envelope: {
      schemaVersion: 2,
      cryptoVersion: 2,
      keyId: "sync-v2",
      nonce: "AQEBAQEBAQEBAQEB",
      ciphertext: "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC",
      checksum: marker.repeat(64),
      createdAt: "2026-07-13T10:00:00Z"
    }
  };
}

function restoreEnv(name: string, value: string | undefined) {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}
