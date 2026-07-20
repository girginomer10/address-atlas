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

  it("durably charges account and global ingress before request semantics", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT id FROM users")) return { rowCount: 1, rows: [{ id: USER_ID }] };
      if (sql.includes("INSERT INTO vault_global_ingress_usage")) {
        return { rowCount: 1, rows: [{ byte_count: "1977" }] };
      }
      if (sql.includes("INSERT INTO vault_write_usage")) return { rowCount: 1, rows: [{ byte_count: "1977" }] };
      return { rowCount: 1, rows: [] };
    });

    await expect(chargeVaultIngress(USER_ID, 777)).resolves.toBeUndefined();
    const statements = mocks.query.mock.calls.map(([sql]) => String(sql));
    expect(mocks.query).toHaveBeenCalledWith(expect.stringContaining("INSERT INTO vault_global_ingress_usage"), [
      777, 2_000_000_000
    ]);
    expect(mocks.query).toHaveBeenCalledWith(expect.stringContaining("INSERT INTO vault_write_usage"), [
      USER_ID, 777, 64_000_000
    ]);
    const globalIndex = statements.findIndex((sql) => sql.includes("vault_global_ingress_usage"));
    const accountIndex = statements.findIndex((sql) => sql.includes("vault_write_usage"));
    const commitIndexes = statements.flatMap((sql, index) => sql === "COMMIT" ? [index] : []);
    expect(statements.filter((sql) => sql === "BEGIN")).toHaveLength(2);
    expect(commitIndexes).toHaveLength(2);
    expect(globalIndex).toBeLessThan(commitIndexes[0]!);
    expect(commitIndexes[0]!).toBeLessThan(accountIndex);
    expect(accountIndex).toBeLessThan(commitIndexes[1]!);
  });

  it("keeps the global charge when a concurrently deleted account is rejected", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("INSERT INTO vault_global_ingress_usage")) {
        return { rowCount: 1, rows: [{ byte_count: "100" }] };
      }
      if (sql.includes("SELECT id FROM users")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    await expect(chargeVaultIngress(USER_ID, 100)).rejects.toBeInstanceOf(VaultAccountMissingError);
    const statements = mocks.query.mock.calls.map(([sql]) => String(sql));
    const globalIndex = statements.findIndex((sql) => sql.includes("vault_global_ingress_usage"));
    const firstCommitIndex = statements.indexOf("COMMIT");
    const accountLookupIndex = statements.findIndex((sql) => sql.includes("SELECT id FROM users"));
    expect(globalIndex).toBeLessThan(firstCommitIndex);
    expect(firstCommitIndex).toBeLessThan(accountLookupIndex);
    expect(mocks.query).toHaveBeenCalledWith("ROLLBACK");
    expect(mocks.query.mock.calls.some(([sql]) => String(sql).includes("vault_write_usage"))).toBe(false);
  });

  it("fails closed when the durable global ingress budget is exhausted", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT id FROM users")) return { rowCount: 1, rows: [] };
      if (sql.includes("INSERT INTO vault_global_ingress_usage")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    await expect(chargeVaultIngress(USER_ID, 100)).rejects.toBeInstanceOf(VaultGlobalIngressQuotaError);
    expect(mocks.query).toHaveBeenCalledWith("ROLLBACK");
    expect(mocks.query.mock.calls.some(([sql]) => String(sql).includes("SELECT id FROM users"))).toBe(false);
  });

  it("commits global ingress before rolling back an exhausted account budget", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT id FROM users")) return { rowCount: 1, rows: [] };
      if (sql.includes("INSERT INTO vault_global_ingress_usage")) return { rowCount: 1, rows: [] };
      if (sql.includes("INSERT INTO vault_write_usage")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    await expect(chargeVaultIngress(USER_ID, 100)).rejects.toBeInstanceOf(VaultQuotaError);
    const statements = mocks.query.mock.calls.map(([sql]) => String(sql));
    const globalIndex = statements.findIndex((sql) => sql.includes("vault_global_ingress_usage"));
    const firstCommitIndex = statements.indexOf("COMMIT");
    const accountIndex = statements.findIndex((sql) => sql.includes("vault_write_usage"));
    expect(globalIndex).toBeLessThan(firstCommitIndex);
    expect(firstCommitIndex).toBeLessThan(accountIndex);
    expect(mocks.query).toHaveBeenCalledWith("ROLLBACK");
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
