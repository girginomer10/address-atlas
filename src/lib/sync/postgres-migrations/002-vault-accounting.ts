import { defineMigration } from "./types";

export const VAULT_ACCOUNTING_MIGRATION = defineMigration({
  version: 2,
  name: "vault-accounting-trigger",
  statements: [
    `CREATE TABLE IF NOT EXISTS vault_snapshots (
       user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
       version integer NOT NULL
         CONSTRAINT vault_snapshots_version_bound_check
         CHECK (version BETWEEN 1 AND 2000000000),
       envelope jsonb NOT NULL,
       byte_size integer NOT NULL
         CONSTRAINT vault_snapshots_byte_size_bound_check
         CHECK (byte_size BETWEEN 1 AND 8000000),
       checksum text NOT NULL,
       created_at timestamptz NOT NULL DEFAULT now(),
       updated_at timestamptz NOT NULL DEFAULT now()
     )`,
    `UPDATE sync_storage_usage
     SET reconcile_required = true, updated_at = now()
     WHERE singleton = true`,
    `CREATE OR REPLACE FUNCTION address_atlas_decrement_snapshot_usage()
     RETURNS trigger
     LANGUAGE plpgsql
     VOLATILE
     CALLED ON NULL INPUT
     SECURITY INVOKER
     PARALLEL UNSAFE
     AS $address_atlas_function$
     DECLARE
       updated_rows bigint;
     BEGIN
       EXECUTE pg_catalog.format(
         'UPDATE %I.sync_storage_usage
          SET total_snapshot_bytes = total_snapshot_bytes - $1,
              updated_at = pg_catalog.now()
          WHERE singleton = true
            AND total_snapshot_bytes >= $1',
         TG_TABLE_SCHEMA
       ) USING OLD.byte_size;
       GET DIAGNOSTICS updated_rows = ROW_COUNT;
       IF updated_rows <> 1 THEN
         RAISE EXCEPTION 'Address Atlas snapshot usage counter is missing or inconsistent.'
           USING ERRCODE = '23514';
       END IF;
       RETURN OLD;
     END;
     $address_atlas_function$`,
    `ALTER FUNCTION address_atlas_decrement_snapshot_usage() RESET ALL`,
    `DROP TRIGGER IF EXISTS address_atlas_snapshot_delete_usage ON vault_snapshots`,
    `CREATE TRIGGER address_atlas_snapshot_delete_usage
     AFTER DELETE ON vault_snapshots
     FOR EACH ROW EXECUTE FUNCTION address_atlas_decrement_snapshot_usage()`
  ]
});
