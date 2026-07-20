import { defineMigration } from "./types";

export const CORE_SCHEMA_MIGRATION = defineMigration({
  version: 1,
  name: "core-schema-ledger",
  statements: [
    `CREATE TABLE sync_schema_migrations (
       version integer PRIMARY KEY
         CONSTRAINT sync_schema_migrations_version_positive CHECK (version > 0),
       name text NOT NULL
         CONSTRAINT sync_schema_migrations_name_bounded
         CHECK (octet_length(name) BETWEEN 1 AND 128),
       checksum text NOT NULL
         CONSTRAINT sync_schema_migrations_checksum_format
         CHECK (checksum ~ '^[0-9a-f]{64}$'),
       applied_at timestamptz NOT NULL DEFAULT now()
     )`,
    `CREATE TABLE IF NOT EXISTS users (
       id uuid PRIMARY KEY,
       created_at timestamptz NOT NULL DEFAULT now(),
       updated_at timestamptz NOT NULL DEFAULT now()
     )`,
    `CREATE TABLE IF NOT EXISTS passkey_credentials (
       id text PRIMARY KEY,
       user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
       public_key_base64url text NOT NULL,
       counter bigint NOT NULL DEFAULT 0
         CONSTRAINT passkey_credentials_counter_uint32_check
         CHECK (counter BETWEEN 0 AND 4294967295),
       transports jsonb NOT NULL DEFAULT '[]'::jsonb
         CONSTRAINT passkey_credentials_transports_bounded
         CHECK (jsonb_typeof(transports) = 'array' AND octet_length(transports::text) <= 2048),
       created_at timestamptz NOT NULL DEFAULT now(),
       updated_at timestamptz NOT NULL DEFAULT now()
     )`,
    `CREATE TABLE IF NOT EXISTS consumed_challenges (
       challenge text PRIMARY KEY,
       consumed_at timestamptz NOT NULL DEFAULT now()
     )`,
    `CREATE INDEX IF NOT EXISTS consumed_challenges_consumed_at_idx
       ON consumed_challenges (consumed_at)`,
    `CREATE TABLE IF NOT EXISTS registration_usage (
       window_started_at timestamptz PRIMARY KEY,
       admission_count integer NOT NULL
         CONSTRAINT registration_usage_admission_count_check CHECK (admission_count >= 0),
       updated_at timestamptz NOT NULL DEFAULT now()
     )`,
    `CREATE TABLE IF NOT EXISTS session_grants (
       id uuid PRIMARY KEY,
       user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
       expires_at timestamptz NOT NULL,
       created_at timestamptz NOT NULL DEFAULT now()
     )`,
    `CREATE INDEX IF NOT EXISTS session_grants_expires_at_idx
       ON session_grants (expires_at)`,
    `CREATE INDEX IF NOT EXISTS session_grants_user_id_idx
       ON session_grants (user_id)`,
    `CREATE TABLE IF NOT EXISTS vault_global_ingress_usage (
       usage_date date PRIMARY KEY,
       byte_count bigint NOT NULL
         CONSTRAINT vault_global_ingress_usage_byte_count_check CHECK (byte_count >= 0),
       updated_at timestamptz NOT NULL DEFAULT now()
     )`,
    `CREATE TABLE IF NOT EXISTS vault_write_usage (
       user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
       usage_date date NOT NULL,
       write_count integer NOT NULL
         CONSTRAINT vault_write_usage_write_count_check CHECK (write_count >= 0),
       byte_count bigint NOT NULL
         CONSTRAINT vault_write_usage_byte_count_check CHECK (byte_count >= 0),
       updated_at timestamptz NOT NULL DEFAULT now(),
       PRIMARY KEY (user_id, usage_date)
     )`,
    `CREATE INDEX IF NOT EXISTS vault_write_usage_date_idx
       ON vault_write_usage (usage_date)`,
    `CREATE TABLE IF NOT EXISTS sync_storage_usage (
       singleton boolean PRIMARY KEY DEFAULT true
         CONSTRAINT sync_storage_usage_singleton_check CHECK (singleton),
       total_snapshot_bytes bigint NOT NULL
         CONSTRAINT sync_storage_usage_total_snapshot_bytes_check
         CHECK (total_snapshot_bytes >= 0),
       reconciled_contract_version integer NOT NULL DEFAULT 0
         CONSTRAINT sync_storage_usage_reconciled_contract_version_check
         CHECK (reconciled_contract_version >= 0),
       reconcile_required boolean NOT NULL DEFAULT true,
       updated_at timestamptz NOT NULL DEFAULT now()
     )`,
    `INSERT INTO sync_storage_usage (singleton, total_snapshot_bytes)
     VALUES (true, 0)
     ON CONFLICT (singleton) DO NOTHING`
  ]
});
