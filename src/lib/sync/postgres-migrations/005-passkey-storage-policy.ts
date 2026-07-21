import { definePreparedMigration } from "./types";

/**
 * Deliberately prepared, not active. The current release converges both
 * passkey variable-width columns to EXTERNAL before this migration is ever
 * activated. A future release can therefore record the same immutable policy
 * without taking an unnecessary ACCESS EXCLUSIVE lock on a compliant N-1
 * database. This normal deployment migration contains no unbounded table scan.
 */
export const PASSKEY_STORAGE_POLICY_MIGRATION = definePreparedMigration({
  version: 5,
  name: "passkey-storage-policy",
  prepared: true,
  statements: [
    `DO $address_atlas_passkey_storage_policy$
     DECLARE
       column_name pg_catalog.text;
     BEGIN
       FOR column_name IN
         SELECT attribute.attname
         FROM pg_catalog.pg_class AS relation
         JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
         JOIN pg_catalog.pg_attribute AS attribute ON attribute.attrelid = relation.oid
         WHERE namespace.nspname OPERATOR(pg_catalog.=) pg_catalog.current_schema()
           AND relation.relname OPERATOR(pg_catalog.=) 'passkey_credentials'
           AND relation.relkind OPERATOR(pg_catalog.=) 'r'
           AND attribute.attname OPERATOR(pg_catalog.=) ANY (
             ARRAY['id', 'public_key_base64url']::pg_catalog.text[]
           )
           AND attribute.attnum > 0
           AND NOT attribute.attisdropped
           AND attribute.attstorage OPERATOR(pg_catalog.<>) 'e'
         ORDER BY attribute.attname
       LOOP
         EXECUTE pg_catalog.format(
           'ALTER TABLE %I.%I ALTER COLUMN %I SET STORAGE EXTERNAL',
           pg_catalog.current_schema(),
           'passkey_credentials',
           column_name
         );
       END LOOP;
     END
     $address_atlas_passkey_storage_policy$ LANGUAGE plpgsql`
  ]
});
