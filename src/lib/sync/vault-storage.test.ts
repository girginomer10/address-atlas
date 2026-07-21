import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  query: vi.fn(),
  connect: vi.fn(),
  release: vi.fn()
}));

vi.mock("./postgres", () => ({
  getSyncPool: () => ({ connect: mocks.connect })
}));

import type { RemoteVaultSnapshot } from "./envelope";
import {
  assertVaultIngressCapacity,
  chargeVaultIngress,
  saveVaultSnapshot,
  VaultAccountMissingError,
  VaultConflictError,
  VaultGlobalIngressQuotaError,
  VaultQuotaError,
  VaultStorageCapacityError
} from "./vault-storage";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const SNAPSHOT: RemoteVaultSnapshot = {
  version: 2,
  byteSize: 200,
  checksum: "a".repeat(64),
  envelope: {
    schemaVersion: 2,
    cryptoVersion: 2,
    keyId: "sync-v2",
    nonce: "AQEBAQEBAQEBAQEB",
    ciphertext: "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC",
    checksum: "b".repeat(64),
    createdAt: "2026-07-12T12:00:00Z"
  }
};

describe("vault storage abuse controls", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.connect.mockResolvedValue({ query: mocks.query, release: mocks.release });
  });

  it("rejects an invalid ingress charge before opening a transaction", async () => {
    await expect(chargeVaultIngress(USER_ID, 0)).rejects.toBeInstanceOf(VaultQuotaError);
    expect(mocks.connect).not.toHaveBeenCalled();
  });

  it("checks durable account and global capacity in deterministic lock order", async () => {
    mockIngressQueries({ accountBytes: "1200", globalBytes: "1200" });

    await expect(assertVaultIngressCapacity(USER_ID)).resolves.toMatchObject({ userId: USER_ID });

    const statements = mocks.query.mock.calls.map(([sql]) => String(sql));
    const userIndex = statements.findIndex((sql) => sql.includes("SELECT id FROM users"));
    const accountIndex = statements.findIndex((sql) => sql.includes("FROM vault_write_usage"));
    const globalIndex = statements.findIndex((sql) => sql.includes("FROM vault_global_ingress_usage"));
    expect(userIndex).toBeLessThan(accountIndex);
    expect(accountIndex).toBeLessThan(globalIndex);
    expect(globalIndex).toBeLessThan(statements.indexOf("COMMIT"));
  });

  it("rejects exhausted account capacity without touching global usage", async () => {
    mockIngressQueries({ accountBytes: "64000000", globalBytes: "1200" });

    await expect(assertVaultIngressCapacity(USER_ID)).rejects.toBeInstanceOf(VaultQuotaError);

    const statements = mocks.query.mock.calls.map(([sql]) => String(sql));
    expect(statements.some((sql) => sql.includes("vault_global_ingress_usage"))).toBe(false);
    expect(mocks.query).toHaveBeenCalledWith("ROLLBACK");
  });

  it("rejects exhausted global capacity before a body can be read", async () => {
    mockIngressQueries({ accountBytes: "1200", globalBytes: "2000000000" });

    await expect(assertVaultIngressCapacity(USER_ID))
      .rejects.toBeInstanceOf(VaultGlobalIngressQuotaError);

    expect(mocks.query).toHaveBeenCalledWith("ROLLBACK");
  });

  it("charges account and global ingress before request semantics", async () => {
    mockIngressQueries({ accountBytes: "1200", globalBytes: "1200" });

    await expect(chargeVaultIngress(USER_ID, 777)).resolves.toBeUndefined();
    const statements = mocks.query.mock.calls.map(([sql]) => String(sql));
    expect(mocks.query).toHaveBeenCalledWith(expect.stringContaining("UPDATE vault_global_ingress_usage"), [
      777
    ]);
    expect(mocks.query).toHaveBeenCalledWith(expect.stringContaining("UPDATE vault_write_usage"), [
      USER_ID, 777, 64_000_000
    ]);
    const accountIndex = statements.findIndex((sql) => sql.includes("FROM vault_write_usage"));
    const globalIndex = statements.findIndex((sql) => sql.includes("FROM vault_global_ingress_usage"));
    const commitIndexes = statements.flatMap((sql, index) => sql === "COMMIT" ? [index] : []);
    expect(statements.filter((sql) => sql === "BEGIN")).toHaveLength(1);
    expect(commitIndexes).toHaveLength(1);
    expect(accountIndex).toBeLessThan(globalIndex);
    expect(globalIndex).toBeLessThan(commitIndexes[0]!);
  });

  it("does not charge global ingress when an account is missing", async () => {
    mockIngressQueries({ accountExists: false });

    await expect(chargeVaultIngress(USER_ID, 100)).rejects.toBeInstanceOf(VaultAccountMissingError);
    const statements = mocks.query.mock.calls.map(([sql]) => String(sql));
    expect(statements).not.toContain("COMMIT");
    expect(statements.some((sql) => sql.includes("vault_global_ingress_usage"))).toBe(false);
    expect(mocks.query).toHaveBeenCalledWith("ROLLBACK");
    expect(mocks.query.mock.calls.some(([sql]) => String(sql).includes("vault_write_usage"))).toBe(false);
  });

  it("charges shared ingress after an admitted account is concurrently deleted", async () => {
    mockIngressQueries({ accountBytes: "1200", globalBytes: "1200" });
    const admission = await assertVaultIngressCapacity(USER_ID);
    mocks.query.mockClear();
    mockIngressQueries({ accountExists: false, globalBytes: "1200" });

    await expect(chargeVaultIngress(USER_ID, 100, admission))
      .rejects.toBeInstanceOf(VaultAccountMissingError);

    const statements = mocks.query.mock.calls.map(([sql]) => String(sql));
    expect(statements.some((sql) => sql.includes("UPDATE vault_write_usage"))).toBe(false);
    expect(mocks.query).toHaveBeenCalledWith(
      expect.stringContaining("UPDATE vault_global_ingress_usage"),
      [100]
    );
    expect(statements).toContain("COMMIT");
    expect(statements).not.toContain("ROLLBACK");
  });

  it("does not let an ingress admission be reused after account deletion", async () => {
    mockIngressQueries({ accountBytes: "1200", globalBytes: "1200" });
    const admission = await assertVaultIngressCapacity(USER_ID);
    mocks.query.mockClear();
    mockIngressQueries({ accountExists: false, globalBytes: "1200" });

    await expect(chargeVaultIngress(USER_ID, 100, admission))
      .rejects.toBeInstanceOf(VaultAccountMissingError);
    mocks.query.mockClear();
    await expect(chargeVaultIngress(USER_ID, 100, admission))
      .rejects.toBeInstanceOf(VaultAccountMissingError);

    expect(mocks.query.mock.calls.some(([sql]) =>
      String(sql).includes("vault_global_ingress_usage"))).toBe(false);
    expect(mocks.query).toHaveBeenCalledWith("ROLLBACK");
  });

  it("commits actual bytes before reporting newly exhausted global ingress", async () => {
    mockIngressQueries({ accountBytes: "100", globalBytes: "1999999950" });

    await expect(chargeVaultIngress(USER_ID, 100)).rejects.toBeInstanceOf(VaultGlobalIngressQuotaError);
    expect(mocks.query).toHaveBeenCalledWith(expect.stringContaining("UPDATE vault_write_usage"), [
      USER_ID, 100, 64_000_000
    ]);
    expect(mocks.query).toHaveBeenCalledWith(expect.stringContaining("UPDATE vault_global_ingress_usage"), [100]);
    expect(mocks.query).toHaveBeenCalledWith("COMMIT");
    expect(mocks.query).not.toHaveBeenCalledWith("ROLLBACK");
  });

  it("saturates account usage and commits actual global bytes before rejecting", async () => {
    mockIngressQueries({ accountBytes: "63999950", globalBytes: "1000" });

    await expect(chargeVaultIngress(USER_ID, 100)).rejects.toBeInstanceOf(VaultQuotaError);
    const statements = mocks.query.mock.calls.map(([sql]) => String(sql));
    expect(statements.some((sql) => sql.includes("UPDATE vault_global_ingress_usage"))).toBe(true);
    expect(statements).toContain("COMMIT");
    expect(mocks.query).not.toHaveBeenCalledWith("ROLLBACK");
    const accountUpdate = String(mocks.query.mock.calls.find(([sql]) =>
      String(sql).includes("UPDATE vault_write_usage"))?.[0]);
    expect(accountUpdate).toContain("LEAST($3::bigint");
  });

  it("destroys the client when an ambiguous ingress transaction cannot roll back", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql === "BEGIN") throw new Error("begin timed out");
      if (sql === "ROLLBACK") throw new Error("rollback timed out");
      return { rowCount: 1, rows: [] };
    });

    await expect(chargeVaultIngress(USER_ID, 100)).rejects.toThrow("begin timed out");
    expect(mocks.release).toHaveBeenCalledWith(true);
  });

  it("returns exact replays without rewriting storage or logical usage", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT id FROM users")) return { rowCount: 1, rows: [{ id: USER_ID }] };
      if (sql.includes("FROM vault_snapshots")) {
        return {
          rowCount: 1,
          rows: [{ version: 2, checksum: SNAPSHOT.checksum, byte_size: 200, same_envelope: true }]
        };
      }
      return { rowCount: 1, rows: [] };
    });

    await expect(saveVaultSnapshot(USER_ID, SNAPSHOT)).resolves.toEqual({ idempotent: true });
    const sql = mocks.query.mock.calls.map(([statement]) => String(statement)).join("\n");
    expect(sql).not.toContain("INSERT INTO vault_write_usage");
    expect(sql).not.toContain("INSERT INTO vault_snapshots");
    expect(sql).not.toContain("UPDATE sync_storage_usage");
    expect(mocks.query).toHaveBeenCalledWith("COMMIT");
  });

  it("returns a stale conflict only after the separate ingress charge can commit", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT id FROM users")) return { rowCount: 1, rows: [{ id: USER_ID }] };
      if (sql.includes("FROM vault_snapshots")) {
        return { rowCount: 1, rows: [{ version: 3, checksum: "different", byte_size: 1, same_envelope: false }] };
      }
      return { rowCount: 1, rows: [] };
    });

    await expect(saveVaultSnapshot(USER_ID, SNAPSHOT)).rejects.toBeInstanceOf(VaultConflictError);
    expect(mocks.query).toHaveBeenCalledWith("COMMIT");
    expect(mocks.query).not.toHaveBeenCalledWith("ROLLBACK");
  });

  it("stores only a strictly newer snapshot and increments only logical writes", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT id FROM users")) return { rowCount: 1, rows: [{ id: USER_ID }] };
      if (sql.includes("FROM vault_snapshots")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [{ version: 2 }] };
    });

    await expect(saveVaultSnapshot(USER_ID, SNAPSHOT)).resolves.toEqual({ idempotent: false });
    expect(mocks.query).toHaveBeenCalledWith(expect.stringContaining("INSERT INTO vault_write_usage"), [
      USER_ID, 100
    ]);
    expect(mocks.query).toHaveBeenCalledWith(expect.stringContaining("UPDATE sync_storage_usage"), [
      200, 10_000_000_000
    ]);
    const dailySQL = String(mocks.query.mock.calls.find(([sql]) => String(sql).includes("INSERT INTO vault_write_usage"))?.[0]);
    expect(dailySQL).toContain("VALUES ($1, (now() AT TIME ZONE 'UTC')::date, 1, 0)");
    expect(dailySQL).not.toContain("byte_count = vault_write_usage.byte_count +");
  });

  it("rolls back a tentative snapshot when logical write quota is exhausted", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT id FROM users")) return { rowCount: 1, rows: [] };
      if (sql.includes("FROM vault_snapshots")) return { rowCount: 0, rows: [] };
      if (sql.includes("INSERT INTO vault_write_usage")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [{ version: 2 }] };
    });

    await expect(saveVaultSnapshot(USER_ID, SNAPSHOT)).rejects.toBeInstanceOf(VaultQuotaError);
    expect(mocks.query).toHaveBeenCalledWith("ROLLBACK");
  });

  it("rolls back snapshot and logical usage when aggregate storage is full", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT id FROM users")) return { rowCount: 1, rows: [] };
      if (sql.includes("FROM vault_snapshots")) return { rowCount: 0, rows: [] };
      if (sql.includes("UPDATE sync_storage_usage")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [{ version: 2 }] };
    });

    await expect(saveVaultSnapshot(USER_ID, SNAPSHOT)).rejects.toBeInstanceOf(VaultStorageCapacityError);
    expect(mocks.query).toHaveBeenCalledWith("ROLLBACK");
  });
});

function mockIngressQueries({
  accountExists = true,
  accountBytes = "0",
  globalBytes = "0"
}: {
  accountExists?: boolean;
  accountBytes?: string;
  globalBytes?: string;
} = {}) {
  mocks.query.mockImplementation(async (sql: string) => {
    if (sql.includes("SELECT id FROM users")) {
      return accountExists
        ? { rowCount: 1, rows: [{ id: USER_ID }] }
        : { rowCount: 0, rows: [] };
    }
    if (sql.includes("FROM vault_write_usage")) {
      return { rowCount: 1, rows: [{ byte_count: accountBytes }] };
    }
    if (sql.includes("FROM vault_global_ingress_usage")) {
      return { rowCount: 1, rows: [{ byte_count: globalBytes }] };
    }
    return { rowCount: 1, rows: [] };
  });
}
