import { Pool, type PoolClient } from "pg";
import { getSyncDatabaseConfig } from "./config";

let pool: Pool | null = null;
let schemaReady: Promise<void> | null = null;
let nextUsagePruneAt = 0;
let usagePruneInFlight: Promise<void> | null = null;

const USAGE_RETENTION_DAYS = 35;
const USAGE_PRUNE_BATCH_SIZE = 10_000;
const USAGE_PRUNE_MAX_BATCHES = 100;
const USAGE_PRUNE_MAX_RUNTIME_MS = 2_000;
const USAGE_PRUNE_INTERVAL_MS = 60 * 60 * 1_000;
const USAGE_PRUNE_RETRY_MS = 60 * 1_000;

export function getSyncPool() {
  if (!pool) {
    const config = getSyncDatabaseConfig();
    const created = new Pool({
      connectionString: config.connectionString,
      application_name: "address-atlas-sync",
      max: config.poolSize,
      connectionTimeoutMillis: config.connectTimeoutMs,
      idleTimeoutMillis: config.idleTimeoutMs,
      statement_timeout: config.statementTimeoutMs,
      query_timeout: config.queryTimeoutMs
    });
    // node-postgres emits pool-level errors for idle clients that lose their
    // backend connection. Always consume the event so a DB restart cannot turn
    // into an uncaught EventEmitter error and terminate the process.
    created.on("error", () => {
      console.error("An idle Address Atlas Postgres connection failed; readiness checks will retry.");
    });
    pool = created;
  }
  return pool;
}

export async function ensureSyncSchema() {
  if (!schemaReady) {
    const attempt = initializeSchema();
    schemaReady = attempt;
    // A transient startup failure must not permanently poison this process.
    // Clear only our own attempt so a later caller can retry safely.
    void attempt.catch(() => {
      if (schemaReady === attempt) schemaReady = null;
    });
  }
  await schemaReady;
  scheduleOldVaultWriteUsagePrune();
}

async function initializeSchema() {
  const client = await getSyncPool().connect();
  let discardClient = false;
  let migrationLockHeld = false;
  let lockAcquisitionAmbiguous = true;
  try {
    // Hold a session-level lock across separately committed phases so replicas
    // cannot race the migration. Treat a timed-out acquisition as ambiguous and
    // discard that connection: the server may acquire the lock after pg's client
    // callback has already timed out.
    await client.query("SELECT pg_advisory_lock(1094992973)");
    migrationLockHeld = true;
    lockAcquisitionAmbiguous = false;

    await runTransaction(client, [
      `
      CREATE TABLE IF NOT EXISTS users (
        id uuid PRIMARY KEY,
        created_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      `,
      `
      CREATE TABLE IF NOT EXISTS passkey_credentials (
        id text PRIMARY KEY,
        user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        public_key_base64url text NOT NULL,
        counter bigint NOT NULL DEFAULT 0,
        transports jsonb NOT NULL DEFAULT '[]'::jsonb,
        created_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      `,
      // Keep the legacy column during rolling deploys, but new code neither
      // reads nor writes authenticator-controlled transport hints. Restore it
      // if a partial deployment already dropped it and bound old-node writes.
      `
      ALTER TABLE passkey_credentials
        ADD COLUMN IF NOT EXISTS transports jsonb NOT NULL DEFAULT '[]'::jsonb
      `,
      `
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conname = 'passkey_credentials_transports_bounded'
            AND conrelid = 'passkey_credentials'::regclass
        ) THEN
          ALTER TABLE passkey_credentials
            ADD CONSTRAINT passkey_credentials_transports_bounded
            CHECK (jsonb_typeof(transports) = 'array' AND octet_length(transports::text) <= 2048)
            NOT VALID;
        END IF;
      END;
      $$
      `,
      `
      CREATE TABLE IF NOT EXISTS consumed_challenges (
        challenge text PRIMARY KEY,
        consumed_at timestamptz NOT NULL DEFAULT now()
      )
      `,
      `
      CREATE INDEX IF NOT EXISTS consumed_challenges_consumed_at_idx
        ON consumed_challenges (consumed_at)
      `,
      `
      CREATE TABLE IF NOT EXISTS vault_write_usage (
        user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        usage_date date NOT NULL,
        write_count integer NOT NULL CHECK (write_count >= 0),
        byte_count bigint NOT NULL CHECK (byte_count >= 0),
        updated_at timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (user_id, usage_date)
      )
      `,
      `
      CREATE INDEX IF NOT EXISTS vault_write_usage_date_idx
        ON vault_write_usage (usage_date)
      `,
      `
      CREATE TABLE IF NOT EXISTS sync_storage_usage (
        singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
        total_snapshot_bytes bigint NOT NULL CHECK (total_snapshot_bytes >= 0),
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      `,
      `
      INSERT INTO sync_storage_usage (singleton, total_snapshot_bytes)
      VALUES (true, 0)
      ON CONFLICT (singleton) DO NOTHING
      `
    ]);

    // Keep vault-table DDL in a different transaction from the singleton insert.
    // Old app versions lock these resources in the opposite order, so no
    // migration transaction may hold both during a rolling deployment.
    await runTransaction(client, [
      `
      CREATE TABLE IF NOT EXISTS vault_snapshots (
        user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        version integer NOT NULL,
        envelope jsonb NOT NULL,
        byte_size integer NOT NULL,
        checksum text NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      `,
      `
      CREATE OR REPLACE FUNCTION address_atlas_decrement_snapshot_usage()
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
      `,
      `
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_trigger
          WHERE tgname = 'address_atlas_snapshot_delete_usage'
            AND tgrelid = 'vault_snapshots'::regclass
            AND NOT tgisinternal
        ) THEN
          CREATE TRIGGER address_atlas_snapshot_delete_usage
          AFTER DELETE ON vault_snapshots
          FOR EACH ROW EXECUTE FUNCTION address_atlas_decrement_snapshot_usage();
        END IF;
      END;
      $$
      `
    ]);

    // Lock before calculating the sum. Snapshot writers update this same row,
    // so reconciliation cannot erase a concurrent writer's committed delta.
    await runTransaction(client, [
      "SELECT total_snapshot_bytes FROM sync_storage_usage WHERE singleton = true FOR UPDATE",
      `
        UPDATE sync_storage_usage
        SET total_snapshot_bytes = totals.total_snapshot_bytes, updated_at = now()
        FROM (
          SELECT COALESCE(sum(byte_size), 0)::bigint AS total_snapshot_bytes
          FROM vault_snapshots
        ) AS totals
        WHERE singleton = true
      `
    ]);
  } catch (error) {
    discardClient = lockAcquisitionAmbiguous || !(await rollbackQuietly(client));
    throw error;
  } finally {
    if (migrationLockHeld && !discardClient) {
      try {
        await client.query("SELECT pg_advisory_unlock(1094992973)");
      } catch {
        // A session lock must never return to the pool after an ambiguous unlock.
        discardClient = true;
      }
    }
    if (discardClient) client.release(true);
    else client.release();
  }
}

async function runTransaction(client: PoolClient, statements: string[]) {
  await client.query("BEGIN");
  for (const statement of statements) {
    await client.query(statement);
  }
  await client.query("COMMIT");
}

function scheduleOldVaultWriteUsagePrune() {
  const now = Date.now();
  if (usagePruneInFlight) return;
  if (now < nextUsagePruneAt) return;

  nextUsagePruneAt = now + USAGE_PRUNE_INTERVAL_MS;
  const attempt = pruneOldVaultWriteUsage();
  usagePruneInFlight = attempt;
  void attempt.finally(() => {
    if (usagePruneInFlight === attempt) usagePruneInFlight = null;
  });
}

async function pruneOldVaultWriteUsage() {
  const deadline = Date.now() + USAGE_PRUNE_MAX_RUNTIME_MS;
  try {
    for (let batch = 0; batch < USAGE_PRUNE_MAX_BATCHES && Date.now() < deadline; batch += 1) {
      const result = await getSyncPool().query(
        `DELETE FROM vault_write_usage
         WHERE ctid IN (
           SELECT ctid
           FROM vault_write_usage
           WHERE usage_date < (now() AT TIME ZONE 'UTC')::date - $1
           ORDER BY usage_date
           FOR UPDATE SKIP LOCKED
           LIMIT $2
         )`,
        [USAGE_RETENTION_DAYS, USAGE_PRUNE_BATCH_SIZE]
      );
      if ((result.rowCount ?? 0) < USAGE_PRUNE_BATCH_SIZE) break;
    }
  } catch {
    // Retention is best effort and must not make an otherwise healthy request
    // unavailable. Retry soon instead of waiting for the normal hourly window.
    nextUsagePruneAt = Date.now() + USAGE_PRUNE_RETRY_MS;
  }
}

async function rollbackQuietly(client: PoolClient) {
  try {
    await client.query("ROLLBACK");
    return true;
  } catch {
    // The server may still be executing a client-timed-out statement. Returning
    // this connection to the pool could leak a live transaction to a new caller.
    return false;
  }
}

export async function closeSyncPoolForTests() {
  if (pool) await pool.end();
  pool = null;
  schemaReady = null;
  nextUsagePruneAt = 0;
  usagePruneInFlight = null;
}
