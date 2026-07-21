import { definePreparedMigration } from "./types";

// PostgreSQL's jsonb binary representation has small structural overhead above
// the 8.1 MB wire ceiling. Keep a fixed 64 KiB allowance, then perform the
// exact text-length check only after the uncompressed physical value is proven
// bounded. These literals are part of the immutable migration checksum.
const MAX_STORED_ENVELOPE_JSONB_BYTES = 8_165_536;
const MAX_SNAPSHOT_REQUEST_BYTES = 8_100_000;

/**
 * Deliberately prepared, not active. Release N publishes this exact contract so
 * it can safely run as N-1 after release N+1 applies it. Activating it requires
 * moving the unchanged definition into SYNC_MIGRATIONS in a later release.
 */
export const VAULT_ENVELOPE_STORAGE_BOUND_MIGRATION = definePreparedMigration({
  version: 4,
  name: "vault-envelope-storage-bound",
  prepared: true,
  statements: [
    `DO $address_atlas_storage_policy$
     BEGIN
       IF EXISTS (
         SELECT 1
         FROM pg_catalog.pg_class AS relation
         JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
         JOIN pg_catalog.pg_attribute AS attribute ON attribute.attrelid = relation.oid
         WHERE namespace.nspname OPERATOR(pg_catalog.=) pg_catalog.current_schema()
           AND relation.relname OPERATOR(pg_catalog.=) 'vault_snapshots'
           AND relation.relkind OPERATOR(pg_catalog.=) 'r'
           AND attribute.attname OPERATOR(pg_catalog.=) 'envelope'
           AND attribute.attnum > 0
           AND NOT attribute.attisdropped
           AND attribute.attstorage OPERATOR(pg_catalog.<>) 'e'
       ) THEN
         EXECUTE pg_catalog.format(
           'ALTER TABLE %I.%I ALTER COLUMN %I SET STORAGE EXTERNAL',
           pg_catalog.current_schema(),
           'vault_snapshots',
           'envelope'
         );
       END IF;
     END
     $address_atlas_storage_policy$ LANGUAGE plpgsql`,
    `ALTER TABLE vault_snapshots
       ADD CONSTRAINT vault_snapshots_envelope_storage_bound_check
       CHECK (
         CASE
           WHEN pg_catalog.pg_column_compression(envelope) IS NULL
             AND pg_catalog.pg_column_size(envelope)
               BETWEEN 1 AND ${MAX_STORED_ENVELOPE_JSONB_BYTES}
           THEN pg_catalog.octet_length(envelope::pg_catalog.text)
             BETWEEN 1 AND ${MAX_SNAPSHOT_REQUEST_BYTES}
           ELSE false
         END
       ) NOT VALID`
  ]
});
