import {
  MAX_ENVELOPE_BYTES,
  MAX_SNAPSHOT_REQUEST_BYTES,
  MAX_SNAPSHOT_VERSION,
  StoredVaultSnapshotIntegrityError,
  validateStoredVaultSnapshot
} from "./envelope";

export interface GuardedStoredVaultRow {
  version: unknown;
  envelope: unknown | null;
  byte_size: unknown;
  checksum: unknown | null;
  updated_at: unknown | null;
  stored_row_valid: boolean;
}

// jsonb's binary container adds only small structural overhead above the
// bounded JSON wire representation. The extra 64 KiB keeps every valid vault
// admissible while turning the uncompressed on-disk datum into a hard, cheap
// pre-detoast allocation ceiling.
export const MAX_STORED_ENVELOPE_JSONB_BYTES = MAX_SNAPSHOT_REQUEST_BYTES + 64 * 1024;
export const MAX_STORED_CHECKSUM_BYTES = 128;

/**
 * Classify variable-width vault columns inside PostgreSQL before node-postgres
 * can deserialize them. `OFFSET 0` keeps an explicit per-row sentinel/result
 * boundary, and every variable-width projection below remains behind it.
 *
 * Keep the alias `vault` stable in callers. These are static SQL fragments,
 * never request-derived strings.
 */
export const STORED_VAULT_SAFETY_LATERAL_SQL = `CROSS JOIN LATERAL (
         SELECT (CASE
           WHEN pg_catalog.pg_column_compression(vault.envelope) IS NULL
             AND pg_catalog.pg_column_size(vault.envelope)
               BETWEEN 1 AND ${MAX_STORED_ENVELOPE_JSONB_BYTES}
             AND pg_catalog.pg_column_compression(vault.checksum) IS NULL
             AND pg_catalog.pg_column_size(vault.checksum)
               BETWEEN 1 AND ${MAX_STORED_CHECKSUM_BYTES}
           THEN (
             vault.version BETWEEN 1 AND ${MAX_SNAPSHOT_VERSION}
             AND vault.byte_size BETWEEN 1 AND ${MAX_ENVELOPE_BYTES}
             AND pg_catalog.jsonb_typeof(vault.envelope) = 'object'
             AND pg_catalog.octet_length(vault.envelope::pg_catalog.text)
               BETWEEN 1 AND ${MAX_SNAPSHOT_REQUEST_BYTES}
             AND pg_catalog.octet_length(vault.checksum) = 64
             AND vault.checksum OPERATOR(pg_catalog.~) '^[0-9a-f]{64}$'
             AND pg_catalog.isfinite(vault.created_at)
             AND pg_catalog.isfinite(vault.updated_at)
           )
           ELSE false
         END) IS TRUE AS stored_row_valid
         OFFSET 0
       ) AS safety`;

export const GUARDED_STORED_VAULT_PROJECTION_SQL = `vault.version,
       CASE WHEN safety.stored_row_valid THEN vault.envelope ELSE NULL END AS envelope,
       vault.byte_size,
       CASE WHEN safety.stored_row_valid THEN vault.checksum ELSE NULL END AS checksum,
       CASE WHEN safety.stored_row_valid THEN vault.updated_at ELSE NULL END AS updated_at,
       safety.stored_row_valid`;

/** Fail with one typed, privacy-safe error for either SQL or content integrity. */
export function validateGuardedStoredVaultRow(row: GuardedStoredVaultRow) {
  if (row.stored_row_valid !== true) {
    throw new StoredVaultSnapshotIntegrityError();
  }
  return validateStoredVaultSnapshot({
    version: row.version,
    envelope: row.envelope,
    byteSize: row.byte_size,
    checksum: row.checksum,
    updatedAt: row.updated_at
  });
}
