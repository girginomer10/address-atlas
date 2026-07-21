import { describe, expect, it } from "vitest";
import { SYNC_MIGRATIONS } from "./postgres-migrations";
import {
  SYNC_COLUMN_CONTRACT,
  SYNC_TABLES,
  SYNC_TABLES_BY_MIGRATION_VERSION
} from "./postgres-schema-model";

describe("immutable sync migration contract", () => {
  it("keeps ordered migration identities and checksums stable", () => {
    expect(SYNC_MIGRATIONS.map(({ version, name, checksum }) => ({ version, name, checksum })))
      .toEqual([
        {
          version: 1,
          name: "core-schema-ledger",
          checksum: "95334a9cc097e1f3ee3a6dcd21b65720c359235a0737531938837799df71fe46"
        },
        {
          version: 2,
          name: "vault-accounting-trigger",
          checksum: "370460a2d8e85eb9a1471ac300e7d82efcc16bf9b7f6339e2559507ce2c8d518"
        },
        {
          version: 3,
          name: "account-deletion-receipts",
          checksum: "1a7393b31cfcfd3135532e911a2e824385cb25b7d9f6611e48ad4cda91db0555"
        }
      ]);
  });

  it("models deletion receipts without account, session, token, or raw-key fields", () => {
    expect(SYNC_TABLES).toContain("account_deletion_receipts");
    expect(SYNC_COLUMN_CONTRACT
      .filter((item) => item.table === "account_deletion_receipts")
      .map((item) => item.column))
      .toEqual(["idempotency_key_digest", "created_at"]);
  });

  it("contains no destructive table-history rewrite", () => {
    const migrationSQL = SYNC_MIGRATIONS.flatMap((migration) => migration.statements).join("\n");
    expect(migrationSQL).not.toMatch(/\bDROP\s+(?:TABLE|SCHEMA)\b/i);
    expect(new Set(SYNC_MIGRATIONS.map((migration) => migration.checksum)).size)
      .toBe(SYNC_MIGRATIONS.length);
  });

  it("maps every durable migration version to its exact table surface", () => {
    expect(SYNC_TABLES_BY_MIGRATION_VERSION).toHaveLength(SYNC_MIGRATIONS.length + 1);
    expect(SYNC_TABLES_BY_MIGRATION_VERSION[0]).toBeNull();
    expect(SYNC_TABLES_BY_MIGRATION_VERSION[1]).not.toContain("vault_snapshots");
    expect(SYNC_TABLES_BY_MIGRATION_VERSION[1]).not.toContain("account_deletion_receipts");
    expect(SYNC_TABLES_BY_MIGRATION_VERSION[2]).toContain("vault_snapshots");
    expect(SYNC_TABLES_BY_MIGRATION_VERSION[2]).not.toContain("account_deletion_receipts");
    expect(SYNC_TABLES_BY_MIGRATION_VERSION[SYNC_MIGRATIONS.length]).toEqual(SYNC_TABLES);
  });
});
