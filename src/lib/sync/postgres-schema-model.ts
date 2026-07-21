export interface ColumnContract {
  readonly table: string;
  readonly column: string;
  readonly typeNamespace: "pg_catalog";
  readonly type: string;
  readonly typeOID: number;
  readonly typeModifier: -1;
  readonly defaultExpression: string | null;
}

export interface ConstraintContract {
  readonly table: string;
  readonly name: string;
  readonly type: "p" | "f" | "c";
  readonly columns: readonly string[];
  readonly checkExpression?: string;
  readonly referencedTable?: string;
  readonly referencedColumns?: readonly string[];
  readonly updateAction?: "a";
  readonly deleteAction?: "c";
  readonly matchType?: "s";
  readonly introducedInVersion?: number;
  /** null means normal release migrations intentionally leave it NOT VALID. */
  readonly validatedInVersion?: number | null;
}

export interface IndexContract {
  readonly table: string;
  readonly name: string;
  readonly columns: readonly string[];
  readonly unique: boolean;
  readonly primary: boolean;
}

export interface RelationContract {
  readonly table: string;
  readonly name: string;
  readonly kind: "r" | "i";
}

export interface RoutineContract {
  readonly requiredTable: string;
  readonly name: string;
  readonly kind: "f";
  readonly identityArguments: "";
}

export interface ImplicitRelationTypeContract {
  readonly table: string;
  readonly rowType: string;
  readonly arrayType: string;
}

const column = (
  table: string,
  name: string,
  type: string,
  defaultExpression: string | null = null
): ColumnContract => ({
  table,
  column: name,
  typeNamespace: "pg_catalog",
  type,
  typeOID: pgCatalogTypeOID(type),
  typeModifier: -1,
  defaultExpression
});

function pgCatalogTypeOID(type: string) {
  const oid = {
    bool: 16,
    bytea: 17,
    int8: 20,
    int4: 23,
    text: 25,
    date: 1082,
    timestamptz: 1184,
    uuid: 2950,
    jsonb: 3802
  }[type];
  if (!oid) throw new Error(`Unsupported sync schema type: ${type}`);
  return oid;
}

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

export const VERSION_1_SYNC_TABLES = Object.freeze([
  "sync_schema_migrations",
  ...PRE_LEDGER_SYNC_TABLES.filter((table) => table !== "vault_snapshots")
]);

export const VERSION_2_SYNC_TABLES = Object.freeze([
  "sync_schema_migrations",
  ...PRE_LEDGER_SYNC_TABLES
]);

export const SYNC_TABLES = Object.freeze([
  ...VERSION_2_SYNC_TABLES,
  "account_deletion_receipts"
]);

/** Index by applied migration version; index zero has no versioned schema. */
export const SYNC_TABLES_BY_MIGRATION_VERSION: readonly (
  readonly string[] | null
)[] = Object.freeze([
  null,
  VERSION_1_SYNC_TABLES,
  VERSION_2_SYNC_TABLES,
  SYNC_TABLES,
  SYNC_TABLES,
  SYNC_TABLES
]);

export const SYNC_COLUMN_CONTRACT = Object.freeze([
  column("sync_schema_migrations", "version", "int4"),
  column("sync_schema_migrations", "name", "text"),
  column("sync_schema_migrations", "checksum", "text"),
  column("sync_schema_migrations", "applied_at", "timestamptz", "now()"),
  column("users", "id", "uuid"),
  column("users", "created_at", "timestamptz", "now()"),
  column("users", "updated_at", "timestamptz", "now()"),
  column("passkey_credentials", "id", "text"),
  column("passkey_credentials", "user_id", "uuid"),
  column("passkey_credentials", "public_key_base64url", "text"),
  column("passkey_credentials", "counter", "int8", "0"),
  column("passkey_credentials", "transports", "jsonb", "'[]'::jsonb"),
  column("passkey_credentials", "created_at", "timestamptz", "now()"),
  column("passkey_credentials", "updated_at", "timestamptz", "now()"),
  column("consumed_challenges", "challenge", "text"),
  column("consumed_challenges", "consumed_at", "timestamptz", "now()"),
  column("registration_usage", "window_started_at", "timestamptz"),
  column("registration_usage", "admission_count", "int4"),
  column("registration_usage", "updated_at", "timestamptz", "now()"),
  column("session_grants", "id", "uuid"),
  column("session_grants", "user_id", "uuid"),
  column("session_grants", "expires_at", "timestamptz"),
  column("session_grants", "created_at", "timestamptz", "now()"),
  column("vault_global_ingress_usage", "usage_date", "date"),
  column("vault_global_ingress_usage", "byte_count", "int8"),
  column("vault_global_ingress_usage", "updated_at", "timestamptz", "now()"),
  column("vault_write_usage", "user_id", "uuid"),
  column("vault_write_usage", "usage_date", "date"),
  column("vault_write_usage", "write_count", "int4"),
  column("vault_write_usage", "byte_count", "int8"),
  column("vault_write_usage", "updated_at", "timestamptz", "now()"),
  column("sync_storage_usage", "singleton", "bool", "true"),
  column("sync_storage_usage", "total_snapshot_bytes", "int8"),
  column("sync_storage_usage", "reconciled_contract_version", "int4", "0"),
  column("sync_storage_usage", "reconcile_required", "bool", "true"),
  column("sync_storage_usage", "updated_at", "timestamptz", "now()"),
  column("vault_snapshots", "user_id", "uuid"),
  column("vault_snapshots", "version", "int4"),
  column("vault_snapshots", "envelope", "jsonb"),
  column("vault_snapshots", "byte_size", "int4"),
  column("vault_snapshots", "checksum", "text"),
  column("vault_snapshots", "created_at", "timestamptz", "now()"),
  column("vault_snapshots", "updated_at", "timestamptz", "now()"),
  column("account_deletion_receipts", "idempotency_key_digest", "bytea"),
  column("account_deletion_receipts", "created_at", "timestamptz", "now()")
]);

const primaryKey = (
  table: string,
  name: string,
  columns: readonly string[]
): ConstraintContract => ({ table, name, type: "p", columns });

const check = (
  table: string,
  name: string,
  columns: readonly string[],
  checkExpression: string
): ConstraintContract => ({ table, name, type: "c", columns, checkExpression });

const foreignKey = (
  table: string,
  name: string,
  columns: readonly string[],
  referencedTable: string,
  referencedColumns: readonly string[]
): ConstraintContract => ({
  table,
  name,
  type: "f",
  columns,
  referencedTable,
  referencedColumns,
  updateAction: "a",
  deleteAction: "c",
  matchType: "s"
});

export const SYNC_CONSTRAINT_CONTRACT = Object.freeze([
  primaryKey("sync_schema_migrations", "sync_schema_migrations_pkey", ["version"]),
  check("sync_schema_migrations", "sync_schema_migrations_version_positive", ["version"], "(version > 0)"),
  check(
    "sync_schema_migrations",
    "sync_schema_migrations_name_bounded",
    ["name"],
    "((octet_length(name) >= 1) AND (octet_length(name) <= 128))"
  ),
  check(
    "sync_schema_migrations",
    "sync_schema_migrations_checksum_format",
    ["checksum"],
    "(checksum ~ '^[0-9a-f]{64}$'::text)"
  ),
  primaryKey("users", "users_pkey", ["id"]),
  primaryKey("passkey_credentials", "passkey_credentials_pkey", ["id"]),
  foreignKey("passkey_credentials", "passkey_credentials_user_id_fkey", ["user_id"], "users", ["id"]),
  check(
    "passkey_credentials",
    "passkey_credentials_counter_uint32_check",
    ["counter"],
    "((counter >= 0) AND (counter <= '4294967295'::bigint))"
  ),
  check(
    "passkey_credentials",
    "passkey_credentials_transports_bounded",
    ["transports"],
    "((jsonb_typeof(transports) = 'array'::text) AND (octet_length((transports)::text) <= 2048))"
  ),
  primaryKey("consumed_challenges", "consumed_challenges_pkey", ["challenge"]),
  primaryKey("registration_usage", "registration_usage_pkey", ["window_started_at"]),
  check(
    "registration_usage",
    "registration_usage_admission_count_check",
    ["admission_count"],
    "(admission_count >= 0)"
  ),
  primaryKey("session_grants", "session_grants_pkey", ["id"]),
  foreignKey("session_grants", "session_grants_user_id_fkey", ["user_id"], "users", ["id"]),
  primaryKey("vault_global_ingress_usage", "vault_global_ingress_usage_pkey", ["usage_date"]),
  check(
    "vault_global_ingress_usage",
    "vault_global_ingress_usage_byte_count_check",
    ["byte_count"],
    "(byte_count >= 0)"
  ),
  primaryKey("vault_write_usage", "vault_write_usage_pkey", ["user_id", "usage_date"]),
  foreignKey("vault_write_usage", "vault_write_usage_user_id_fkey", ["user_id"], "users", ["id"]),
  check("vault_write_usage", "vault_write_usage_write_count_check", ["write_count"], "(write_count >= 0)"),
  check("vault_write_usage", "vault_write_usage_byte_count_check", ["byte_count"], "(byte_count >= 0)"),
  primaryKey("sync_storage_usage", "sync_storage_usage_pkey", ["singleton"]),
  check("sync_storage_usage", "sync_storage_usage_singleton_check", ["singleton"], "singleton"),
  check(
    "sync_storage_usage",
    "sync_storage_usage_total_snapshot_bytes_check",
    ["total_snapshot_bytes"],
    "(total_snapshot_bytes >= 0)"
  ),
  check(
    "sync_storage_usage",
    "sync_storage_usage_reconciled_contract_version_check",
    ["reconciled_contract_version"],
    "(reconciled_contract_version >= 0)"
  ),
  primaryKey("vault_snapshots", "vault_snapshots_pkey", ["user_id"]),
  foreignKey("vault_snapshots", "vault_snapshots_user_id_fkey", ["user_id"], "users", ["id"]),
  check(
    "vault_snapshots",
    "vault_snapshots_version_bound_check",
    ["version"],
    "((version >= 1) AND (version <= 2000000000))"
  ),
  check(
    "vault_snapshots",
    "vault_snapshots_byte_size_bound_check",
    ["byte_size"],
    "((byte_size >= 1) AND (byte_size <= 8000000))"
  ),
  {
    ...check(
      "vault_snapshots",
      "vault_snapshots_envelope_storage_bound_check",
      ["envelope"],
      "\nCASE\n    WHEN ((pg_column_compression(envelope) IS NULL) AND ((pg_column_size(envelope) >= 1) AND (pg_column_size(envelope) <= 8165536))) THEN ((octet_length((envelope)::text) >= 1) AND (octet_length((envelope)::text) <= 8100000))\n    ELSE false\nEND"
    ),
    introducedInVersion: 4,
    // New writes are enforced immediately. Historical validation can scan the
    // configured 10 TB vault, so it is deliberately excluded from normal
    // release migrations and their short schema-operation timeout.
    validatedInVersion: null
  },
  primaryKey("account_deletion_receipts", "account_deletion_receipts_pkey", ["idempotency_key_digest"]),
  check(
    "account_deletion_receipts",
    "account_deletion_receipts_digest_length_check",
    ["idempotency_key_digest"],
    "(octet_length(idempotency_key_digest) = 32)"
  )
]);

const index = (
  table: string,
  name: string,
  columns: readonly string[],
  primary = false
): IndexContract => ({ table, name, columns, unique: primary, primary });

export const SYNC_INDEX_CONTRACT = Object.freeze([
  index("sync_schema_migrations", "sync_schema_migrations_pkey", ["version"], true),
  index("users", "users_pkey", ["id"], true),
  index("passkey_credentials", "passkey_credentials_pkey", ["id"], true),
  index("consumed_challenges", "consumed_challenges_pkey", ["challenge"], true),
  index("consumed_challenges", "consumed_challenges_consumed_at_idx", ["consumed_at"]),
  index("registration_usage", "registration_usage_pkey", ["window_started_at"], true),
  index("session_grants", "session_grants_pkey", ["id"], true),
  index("session_grants", "session_grants_expires_at_idx", ["expires_at"]),
  index("session_grants", "session_grants_user_id_idx", ["user_id"]),
  index("vault_global_ingress_usage", "vault_global_ingress_usage_pkey", ["usage_date"], true),
  index("vault_write_usage", "vault_write_usage_pkey", ["user_id", "usage_date"], true),
  index("vault_write_usage", "vault_write_usage_date_idx", ["usage_date"]),
  index("sync_storage_usage", "sync_storage_usage_pkey", ["singleton"], true),
  index("vault_snapshots", "vault_snapshots_pkey", ["user_id"], true),
  index("account_deletion_receipts", "account_deletion_receipts_pkey", ["idempotency_key_digest"], true)
]);

/**
 * Every user-visible pg_class relation owned by the sync schema. PostgreSQL's
 * per-table TOAST relations live in pg_toast and are intentionally outside
 * this namespace-scoped contract.
 */
export const SYNC_RELATION_CONTRACT: readonly RelationContract[] = Object.freeze([
  ...SYNC_TABLES.map((table) => ({ table, name: table, kind: "r" as const })),
  ...SYNC_INDEX_CONTRACT.map(({ table, name }) => ({ table, name, kind: "i" as const }))
]);

/** The only routine deliberately installed in the sync schema. */
export const SYNC_ROUTINE_CONTRACT: readonly RoutineContract[] = Object.freeze([
  {
    requiredTable: "vault_snapshots",
    name: "address_atlas_decrement_snapshot_usage",
    kind: "f",
    identityArguments: ""
  }
]);

/**
 * CREATE TABLE installs one composite row type and its array type in the
 * table's namespace. No other user-defined type is part of this schema.
 */
export const SYNC_IMPLICIT_RELATION_TYPE_CONTRACT: readonly ImplicitRelationTypeContract[] =
  Object.freeze(SYNC_TABLES.map((table) => ({
    table,
    rowType: table,
    arrayType: `_${table}`
  })));

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
