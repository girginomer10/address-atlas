import { describe, expect, it } from "vitest";
import {
  KNOWN_SYNC_MIGRATIONS,
  PREPARED_SYNC_MIGRATIONS,
  SYNC_MIGRATION_CHAIN_CHECKSUMS,
  SYNC_MIGRATIONS
} from "./postgres-migrations";
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

  it("ships the next immutable schema head one release before activation", () => {
    expect(PREPARED_SYNC_MIGRATIONS.map(({ version, name, checksum, prepared }) => ({
      version,
      name,
      checksum,
      prepared
    }))).toEqual([{
      version: 4,
      name: "vault-envelope-storage-bound",
      checksum: "6de6b790dd0c185d9a6193c399edb34d209c774a67d090f133d34a35ad8dbfa5",
      prepared: true
    }]);
    expect(PREPARED_SYNC_MIGRATIONS[0]?.statements).toHaveLength(2);
    expect(PREPARED_SYNC_MIGRATIONS[0]?.statements[0]).toMatch(/DO .*storage_policy/s);
    expect(PREPARED_SYNC_MIGRATIONS[0]?.statements[0]).toMatch(/attstorage.*<>.*'e'/s);
    expect(PREPARED_SYNC_MIGRATIONS[0]?.statements[0]).toMatch(/EXECUTE.*ALTER TABLE/s);
    expect(PREPARED_SYNC_MIGRATIONS[0]?.statements.join("\n"))
      .not.toMatch(/VALIDATE\s+CONSTRAINT/i);
    expect(SYNC_MIGRATIONS).toHaveLength(3);
  });

  it("models deletion receipts without account, session, token, or raw-key fields", () => {
    expect(SYNC_TABLES).toContain("account_deletion_receipts");
    expect(SYNC_COLUMN_CONTRACT
      .filter((item) => item.table === "account_deletion_receipts")
      .map((item) => item.column))
      .toEqual(["idempotency_key_digest", "created_at"]);
  });

  it("contains no destructive table-history rewrite", () => {
    const migrationSQL = KNOWN_SYNC_MIGRATIONS.flatMap((migration) => migration.statements).join("\n");
    expect(migrationSQL).not.toMatch(/\bDROP\s+(?:TABLE|SCHEMA)\b/i);
    expect(new Set(SYNC_MIGRATIONS.map((migration) => migration.checksum)).size)
      .toBe(SYNC_MIGRATIONS.length);
  });

  it("maps every durable migration version to its exact table surface", () => {
    expect(SYNC_TABLES_BY_MIGRATION_VERSION).toHaveLength(KNOWN_SYNC_MIGRATIONS.length + 1);
    expect(SYNC_TABLES_BY_MIGRATION_VERSION[0]).toBeNull();
    expect(SYNC_TABLES_BY_MIGRATION_VERSION[1]).not.toContain("vault_snapshots");
    expect(SYNC_TABLES_BY_MIGRATION_VERSION[1]).not.toContain("account_deletion_receipts");
    expect(SYNC_TABLES_BY_MIGRATION_VERSION[2]).toContain("vault_snapshots");
    expect(SYNC_TABLES_BY_MIGRATION_VERSION[2]).not.toContain("account_deletion_receipts");
    expect(SYNC_TABLES_BY_MIGRATION_VERSION[SYNC_MIGRATIONS.length]).toEqual(SYNC_TABLES);
    expect(SYNC_TABLES_BY_MIGRATION_VERSION[KNOWN_SYNC_MIGRATIONS.length]).toEqual(SYNC_TABLES);
  });

  it("binds every compatible head to the exact cumulative migration chain", () => {
    expect(SYNC_MIGRATION_CHAIN_CHECKSUMS).toEqual([
      "f691f22e3dfa04c237e2bbe6485e6f1acf97e0f71046f01601898280adf0ff5b",
      "a5e1e1bc789daadbb5e13d86227c80413764ef2547832cb8bbfdc917330ef99d",
      "47ad43aa7438c5c8969f7c01162bb73eab8d51066abef482a03fed86a7890ee3",
      "ceb0b725a162b5be512bf35e63ecaf178aa67e7c1335e2807a116f2ef7f65dfe"
    ]);
  });
});
