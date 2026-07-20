export interface ColumnContract {
  readonly table: string;
  readonly column: string;
  readonly type: string;
  readonly hasDefault: boolean;
}

export interface ConstraintContract {
  readonly table: string;
  readonly name: string;
  readonly type: "p" | "f" | "c";
  readonly cascadeDelete?: true;
}

const column = (
  table: string,
  name: string,
  type: string,
  hasDefault = false
): ColumnContract => ({ table, column: name, type, hasDefault });

export const LEGACY_SYNC_TABLES = Object.freeze([
  "users",
  "passkey_credentials",
  "consumed_challenges",
  "vault_write_usage",
  "sync_storage_usage",
  "vault_snapshots"
]);

export const PRE_LEDGER_SYNC_TABLES = Object.freeze([
  ...LEGACY_SYNC_TABLES,
  "registration_usage",
  "session_grants",
  "vault_global_ingress_usage"
]);

export const SYNC_TABLES = Object.freeze([
  "sync_schema_migrations",
  ...PRE_LEDGER_SYNC_TABLES,
  "account_deletion_receipts"
]);

export const SYNC_COLUMN_CONTRACT = Object.freeze([
  column("sync_schema_migrations", "version", "int4"),
  column("sync_schema_migrations", "name", "text"),
  column("sync_schema_migrations", "checksum", "text"),
  column("sync_schema_migrations", "applied_at", "timestamptz", true),
  column("users", "id", "uuid"),
  column("users", "created_at", "timestamptz", true),
  column("users", "updated_at", "timestamptz", true),
  column("passkey_credentials", "id", "text"),
  column("passkey_credentials", "user_id", "uuid"),
  column("passkey_credentials", "public_key_base64url", "text"),
  column("passkey_credentials", "counter", "int8", true),
  column("passkey_credentials", "transports", "jsonb", true),
  column("passkey_credentials", "created_at", "timestamptz", true),
  column("passkey_credentials", "updated_at", "timestamptz", true),
  column("consumed_challenges", "challenge", "text"),
  column("consumed_challenges", "consumed_at", "timestamptz", true),
  column("registration_usage", "window_started_at", "timestamptz"),
  column("registration_usage", "admission_count", "int4"),
  column("registration_usage", "updated_at", "timestamptz", true),
  column("session_grants", "id", "uuid"),
  column("session_grants", "user_id", "uuid"),
  column("session_grants", "expires_at", "timestamptz"),
  column("session_grants", "created_at", "timestamptz", true),
  column("vault_global_ingress_usage", "usage_date", "date"),
  column("vault_global_ingress_usage", "byte_count", "int8"),
  column("vault_global_ingress_usage", "updated_at", "timestamptz", true),
  column("vault_write_usage", "user_id", "uuid"),
  column("vault_write_usage", "usage_date", "date"),
  column("vault_write_usage", "write_count", "int4"),
  column("vault_write_usage", "byte_count", "int8"),
  column("vault_write_usage", "updated_at", "timestamptz", true),
  column("sync_storage_usage", "singleton", "bool", true),
  column("sync_storage_usage", "total_snapshot_bytes", "int8"),
  column("sync_storage_usage", "reconciled_contract_version", "int4", true),
  column("sync_storage_usage", "reconcile_required", "bool", true),
  column("sync_storage_usage", "updated_at", "timestamptz", true),
  column("vault_snapshots", "user_id", "uuid"),
  column("vault_snapshots", "version", "int4"),
  column("vault_snapshots", "envelope", "jsonb"),
  column("vault_snapshots", "byte_size", "int4"),
  column("vault_snapshots", "checksum", "text"),
  column("vault_snapshots", "created_at", "timestamptz", true),
  column("vault_snapshots", "updated_at", "timestamptz", true),
  column("account_deletion_receipts", "idempotency_key_digest", "bytea"),
  column("account_deletion_receipts", "created_at", "timestamptz", true)
]);

const constraint = (
  table: string,
  name: string,
  type: ConstraintContract["type"],
  cascadeDelete?: true
): ConstraintContract => ({ table, name, type, ...(cascadeDelete ? { cascadeDelete } : {}) });

export const SYNC_CONSTRAINT_CONTRACT = Object.freeze([
  constraint("sync_schema_migrations", "sync_schema_migrations_pkey", "p"),
  constraint("sync_schema_migrations", "sync_schema_migrations_version_positive", "c"),
  constraint("sync_schema_migrations", "sync_schema_migrations_name_bounded", "c"),
  constraint("sync_schema_migrations", "sync_schema_migrations_checksum_format", "c"),
  constraint("users", "users_pkey", "p"),
  constraint("passkey_credentials", "passkey_credentials_pkey", "p"),
  constraint("passkey_credentials", "passkey_credentials_user_id_fkey", "f", true),
  constraint("passkey_credentials", "passkey_credentials_counter_uint32_check", "c"),
  constraint("passkey_credentials", "passkey_credentials_transports_bounded", "c"),
  constraint("consumed_challenges", "consumed_challenges_pkey", "p"),
  constraint("registration_usage", "registration_usage_pkey", "p"),
  constraint("registration_usage", "registration_usage_admission_count_check", "c"),
  constraint("session_grants", "session_grants_pkey", "p"),
  constraint("session_grants", "session_grants_user_id_fkey", "f", true),
  constraint("vault_global_ingress_usage", "vault_global_ingress_usage_pkey", "p"),
  constraint("vault_global_ingress_usage", "vault_global_ingress_usage_byte_count_check", "c"),
  constraint("vault_write_usage", "vault_write_usage_pkey", "p"),
  constraint("vault_write_usage", "vault_write_usage_user_id_fkey", "f", true),
  constraint("vault_write_usage", "vault_write_usage_write_count_check", "c"),
  constraint("vault_write_usage", "vault_write_usage_byte_count_check", "c"),
  constraint("sync_storage_usage", "sync_storage_usage_pkey", "p"),
  constraint("sync_storage_usage", "sync_storage_usage_singleton_check", "c"),
  constraint("sync_storage_usage", "sync_storage_usage_total_snapshot_bytes_check", "c"),
  constraint("sync_storage_usage", "sync_storage_usage_reconciled_contract_version_check", "c"),
  constraint("vault_snapshots", "vault_snapshots_pkey", "p"),
  constraint("vault_snapshots", "vault_snapshots_user_id_fkey", "f", true),
  constraint("vault_snapshots", "vault_snapshots_version_bound_check", "c"),
  constraint("vault_snapshots", "vault_snapshots_byte_size_bound_check", "c"),
  constraint("account_deletion_receipts", "account_deletion_receipts_pkey", "p"),
  constraint(
    "account_deletion_receipts",
    "account_deletion_receipts_digest_length_check",
    "c"
  )
]);

export const SYNC_INDEX_CONTRACT = Object.freeze([
  "sync_schema_migrations_pkey",
  "users_pkey",
  "passkey_credentials_pkey",
  "consumed_challenges_pkey",
  "consumed_challenges_consumed_at_idx",
  "registration_usage_pkey",
  "session_grants_pkey",
  "session_grants_expires_at_idx",
  "session_grants_user_id_idx",
  "vault_global_ingress_usage_pkey",
  "vault_write_usage_pkey",
  "vault_write_usage_date_idx",
  "sync_storage_usage_pkey",
  "vault_snapshots_pkey",
  "account_deletion_receipts_pkey"
]);

export const SYNC_RUNTIME_PRIVILEGES = Object.freeze({
  sync_schema_migrations: ["SELECT"],
  // PostgreSQL requires UPDATE privilege for SELECT ... FOR UPDATE even when
  // the application never issues a direct UPDATE against these rows.
  users: ["SELECT", "INSERT", "UPDATE", "DELETE"],
  passkey_credentials: ["SELECT", "INSERT", "UPDATE"],
  consumed_challenges: ["SELECT", "INSERT", "DELETE"],
  registration_usage: ["SELECT", "INSERT", "UPDATE", "DELETE"],
  session_grants: ["SELECT", "INSERT", "UPDATE", "DELETE"],
  vault_global_ingress_usage: ["SELECT", "INSERT", "UPDATE", "DELETE"],
  vault_write_usage: ["SELECT", "INSERT", "UPDATE", "DELETE"],
  sync_storage_usage: ["SELECT", "UPDATE"],
  vault_snapshots: ["SELECT", "INSERT", "UPDATE"],
  account_deletion_receipts: ["SELECT", "INSERT"]
} satisfies Record<string, readonly string[]>);
