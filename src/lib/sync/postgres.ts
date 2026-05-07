import { Pool } from "pg";

let pool: Pool | null = null;
let schemaReady: Promise<void> | null = null;

export function getSyncPool() {
  if (!pool) {
    const connectionString = process.env.SYNC_DATABASE_URL || process.env.DATABASE_URL;
    if (!connectionString || !/^postgres(ql)?:\/\//.test(connectionString)) {
      throw new Error("SYNC_DATABASE_URL must point to Postgres for encrypted sync.");
    }
    pool = new Pool({ connectionString });
  }
  return pool;
}

export async function ensureSyncSchema() {
  if (!schemaReady) {
    schemaReady = getSyncPool().query(`
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
    `).then(() => undefined);
  }
  return schemaReady;
}
