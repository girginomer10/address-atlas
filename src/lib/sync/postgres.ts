import { Pool } from "pg";

let pool: Pool | null = null;
let schemaReady: Promise<void> | null = null;

export function getSyncPool() {
  if (!pool) {
    const connectionString = process.env.SYNC_DATABASE_URL || process.env.DATABASE_URL;
    if (!connectionString || !/^postgres(ql)?:\/\//.test(connectionString)) {
      throw new Error("SYNC_DATABASE_URL must point to Postgres for encrypted sync.");
    }
    pool = new Pool({
      connectionString,
      application_name: "address-atlas-sync",
      max: boundedIntegerFromEnv("SYNC_DB_POOL_SIZE", 10, 1, 50),
      connectionTimeoutMillis: boundedIntegerFromEnv("SYNC_DB_CONNECT_TIMEOUT_MS", 5_000, 500, 60_000),
      idleTimeoutMillis: boundedIntegerFromEnv("SYNC_DB_IDLE_TIMEOUT_MS", 30_000, 1_000, 300_000),
      statement_timeout: boundedIntegerFromEnv("SYNC_DB_STATEMENT_TIMEOUT_MS", 10_000, 500, 120_000),
      query_timeout: boundedIntegerFromEnv("SYNC_DB_QUERY_TIMEOUT_MS", 12_000, 500, 120_000)
    });
  }
  return pool;
}

export async function ensureSyncSchema() {
  if (!schemaReady) {
    const attempt = getSyncPool().query(`
      CREATE TABLE IF NOT EXISTS users (
        id uuid PRIMARY KEY,
        created_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
      );

      CREATE TABLE IF NOT EXISTS passkey_credentials (
        id text PRIMARY KEY,
        user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        public_key_base64url text NOT NULL,
        counter bigint NOT NULL DEFAULT 0,
        transports jsonb NOT NULL DEFAULT '[]'::jsonb,
        created_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
      );

      CREATE TABLE IF NOT EXISTS vault_snapshots (
        user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        version integer NOT NULL,
        envelope jsonb NOT NULL,
        byte_size integer NOT NULL,
        checksum text NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
      );

      CREATE TABLE IF NOT EXISTS consumed_challenges (
        challenge text PRIMARY KEY,
        consumed_at timestamptz NOT NULL DEFAULT now()
      );

      CREATE INDEX IF NOT EXISTS consumed_challenges_consumed_at_idx
        ON consumed_challenges (consumed_at);

      CREATE TABLE IF NOT EXISTS vault_write_usage (
        user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        usage_date date NOT NULL,
        write_count integer NOT NULL CHECK (write_count >= 0),
        byte_count bigint NOT NULL CHECK (byte_count >= 0),
        updated_at timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (user_id, usage_date)
      );

      CREATE INDEX IF NOT EXISTS vault_write_usage_date_idx
        ON vault_write_usage (usage_date);

      CREATE TABLE IF NOT EXISTS sync_storage_usage (
        singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
        total_snapshot_bytes bigint NOT NULL CHECK (total_snapshot_bytes >= 0),
        updated_at timestamptz NOT NULL DEFAULT now()
      );

      INSERT INTO sync_storage_usage (singleton, total_snapshot_bytes)
      SELECT true, COALESCE(sum(byte_size), 0)::bigint FROM vault_snapshots
      ON CONFLICT (singleton) DO NOTHING;
    `).then(() => undefined);
    schemaReady = attempt;
    // A transient startup failure must not permanently poison this process.
    // Clear only our own attempt so a later caller can retry safely.
    void attempt.catch(() => {
      if (schemaReady === attempt) schemaReady = null;
    });
  }
  return schemaReady;
}

function boundedIntegerFromEnv(name: string, fallback: number, min: number, max: number) {
  const raw = process.env[name];
  if (!raw) return fallback;
  const parsed = Number(raw);
  return Number.isSafeInteger(parsed) && parsed >= min && parsed <= max ? parsed : fallback;
}

export async function closeSyncPoolForTests() {
  if (pool) await pool.end();
  pool = null;
  schemaReady = null;
}
