import { CORE_SCHEMA_MIGRATION } from "./001-core-schema";
import { VAULT_ACCOUNTING_MIGRATION } from "./002-vault-accounting";
import { ACCOUNT_DELETION_RECEIPTS_MIGRATION } from "./003-account-deletion-receipts";

export type { SyncMigration } from "./types";

export const SYNC_MIGRATIONS = Object.freeze([
  CORE_SCHEMA_MIGRATION,
  VAULT_ACCOUNTING_MIGRATION,
  ACCOUNT_DELETION_RECEIPTS_MIGRATION
]);

for (let index = 0; index < SYNC_MIGRATIONS.length; index += 1) {
  if (SYNC_MIGRATIONS[index]?.version !== index + 1) {
    throw new Error("Sync migrations must be contiguous and ordered from version 1.");
  }
}

export const LATEST_SYNC_MIGRATION_VERSION = SYNC_MIGRATIONS.length;
export const STORAGE_RECONCILIATION_VERSION = 1;
