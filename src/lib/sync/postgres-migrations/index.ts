import { createHash } from "node:crypto";
import { CORE_SCHEMA_MIGRATION } from "./001-core-schema";
import { VAULT_ACCOUNTING_MIGRATION } from "./002-vault-accounting";
import { ACCOUNT_DELETION_RECEIPTS_MIGRATION } from "./003-account-deletion-receipts";
import { VAULT_ENVELOPE_STORAGE_BOUND_MIGRATION } from "./004-vault-envelope-storage-bound";

export type { PreparedSyncMigration, SyncMigration } from "./types";

export const SYNC_MIGRATIONS = Object.freeze([
  CORE_SCHEMA_MIGRATION,
  VAULT_ACCOUNTING_MIGRATION,
  ACCOUNT_DELETION_RECEIPTS_MIGRATION
]);

/**
 * Immutable next-head contracts accepted by this binary but not applied by it.
 * This one-release preparation window is what makes the current image a real
 * N-1 rollback target after the next schema release.
 */
export const PREPARED_SYNC_MIGRATIONS = Object.freeze([
  VAULT_ENVELOPE_STORAGE_BOUND_MIGRATION
]);

export const KNOWN_SYNC_MIGRATIONS = Object.freeze([
  ...SYNC_MIGRATIONS,
  ...PREPARED_SYNC_MIGRATIONS
]);

for (let index = 0; index < SYNC_MIGRATIONS.length; index += 1) {
  if (SYNC_MIGRATIONS[index]?.version !== index + 1) {
    throw new Error("Sync migrations must be contiguous and ordered from version 1.");
  }
}

for (let index = 0; index < KNOWN_SYNC_MIGRATIONS.length; index += 1) {
  if (KNOWN_SYNC_MIGRATIONS[index]?.version !== index + 1) {
    throw new Error("Known sync migrations must be contiguous and ordered from version 1.");
  }
}

export const LATEST_SYNC_MIGRATION_VERSION = SYNC_MIGRATIONS.length;
export const MAX_COMPATIBLE_SYNC_MIGRATION_VERSION = KNOWN_SYNC_MIGRATIONS.length;
export const SYNC_MIGRATION_CHAIN_CHECKSUMS = Object.freeze(
  KNOWN_SYNC_MIGRATIONS.map((_, index) => createHash("sha256")
    .update(JSON.stringify(KNOWN_SYNC_MIGRATIONS.slice(0, index + 1).map(
      ({ version, name, checksum }) => ({ version, name, checksum })
    )))
    .digest("hex"))
);
export const STORAGE_RECONCILIATION_VERSION = 1;
