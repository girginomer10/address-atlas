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
  saveVaultSnapshot,
  VaultConflictError,
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

  it("rejects an invalid byte charge before opening a transaction", async () => {
    await expect(saveVaultSnapshot(USER_ID, SNAPSHOT, 0)).rejects.toBeInstanceOf(VaultQuotaError);
    expect(mocks.connect).not.toHaveBeenCalled();
  });

  it("destroys the client when an ambiguous BEGIN failure cannot be rolled back", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql === "BEGIN") throw new Error("begin timed out");
      if (sql === "ROLLBACK") throw new Error("rollback timed out");
      return { rowCount: 1, rows: [] };
    });

    await expect(saveVaultSnapshot(USER_ID, SNAPSHOT, 500)).rejects.toThrow("begin timed out");
    expect(mocks.query).toHaveBeenCalledWith("ROLLBACK");
    expect(mocks.release).toHaveBeenCalledWith(true);
  });

  it("charges exact-replay bytes without incrementing writes or rewriting storage", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT id FROM users")) return { rowCount: 1, rows: [{ id: USER_ID }] };
      if (sql.includes("FROM vault_snapshots")) {
        return { rowCount: 1, rows: [{ version: 2, checksum: SNAPSHOT.checksum, byte_size: 200, same_envelope: true }] };
      }
      return { rowCount: 1, rows: [] };
    });

    await expect(saveVaultSnapshot(USER_ID, SNAPSHOT, 500)).resolves.toEqual({ idempotent: true });
    const sql = mocks.query.mock.calls.map(([statement]) => String(statement)).join("\n");
    expect(mocks.query).toHaveBeenCalledWith(expect.stringContaining("INSERT INTO vault_write_usage"), [
      USER_ID, 500, 0, 100, 64_000_000
    ]);
    expect(sql).not.toContain("INSERT INTO vault_snapshots");
    expect(sql).not.toContain("UPDATE sync_storage_usage");
    expect(mocks.query).toHaveBeenCalledWith("COMMIT");
  });

  it("charges stale or same-version request bytes without incrementing writes", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT id FROM users")) return { rowCount: 1, rows: [{ id: USER_ID }] };
      if (sql.includes("FROM vault_snapshots")) {
        return { rowCount: 1, rows: [{ version: 3, checksum: "different", byte_size: 1, same_envelope: false }] };
      }
      return { rowCount: 1, rows: [] };
    });

    await expect(saveVaultSnapshot(USER_ID, SNAPSHOT, 500)).rejects.toBeInstanceOf(VaultConflictError);
    expect(mocks.query).toHaveBeenCalledWith(expect.stringContaining("INSERT INTO vault_write_usage"), [
      USER_ID, 500, 0, 100, 64_000_000
    ]);
    expect(mocks.query).toHaveBeenCalledWith("COMMIT");
    expect(mocks.query).not.toHaveBeenCalledWith("ROLLBACK");
  });

  it("raises the version conflict, not the quota error, when a stale write finds the quota exhausted", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT id FROM users")) return { rowCount: 1, rows: [{ id: USER_ID }] };
      if (sql.includes("FROM vault_snapshots")) {
        return { rowCount: 1, rows: [{ version: 3, checksum: "different", byte_size: 1, same_envelope: false }] };
      }
      if (sql.includes("INSERT INTO vault_write_usage")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    await expect(saveVaultSnapshot(USER_ID, SNAPSHOT, 500)).rejects.toBeInstanceOf(VaultConflictError);
    expect(mocks.query).toHaveBeenCalledWith("ROLLBACK");
    expect(mocks.query).not.toHaveBeenCalledWith("COMMIT");
    expect(mocks.release).toHaveBeenCalledWith();
  });

  it("raises the SQL version-gate conflict even when its byte charge is rejected", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT id FROM users")) return { rowCount: 1, rows: [{ id: USER_ID }] };
      if (sql.includes("FROM vault_snapshots")) {
        return { rowCount: 1, rows: [{ version: 1, checksum: "older", byte_size: 1, same_envelope: false }] };
      }
      if (sql.includes("INSERT INTO vault_snapshots")) return { rowCount: 0, rows: [] };
      if (sql.includes("INSERT INTO vault_write_usage")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    await expect(saveVaultSnapshot(USER_ID, SNAPSHOT, 600)).rejects.toBeInstanceOf(VaultConflictError);
    expect(mocks.query).toHaveBeenCalledWith("ROLLBACK");
    expect(mocks.query).not.toHaveBeenCalledWith("COMMIT");
  });

  it("destroys the client when a stale write's failed charge cannot be rolled back", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT id FROM users")) return { rowCount: 1, rows: [{ id: USER_ID }] };
      if (sql.includes("FROM vault_snapshots")) {
        return { rowCount: 1, rows: [{ version: 3, checksum: "different", byte_size: 1, same_envelope: false }] };
      }
      if (sql.includes("INSERT INTO vault_write_usage")) return { rowCount: 0, rows: [] };
      if (sql === "ROLLBACK") throw new Error("rollback timed out");
      return { rowCount: 1, rows: [] };
    });

    await expect(saveVaultSnapshot(USER_ID, SNAPSHOT, 500)).rejects.toBeInstanceOf(VaultConflictError);
    expect(mocks.release).toHaveBeenCalledWith(true);
  });

  it("rolls back the tentative snapshot when the durable daily quota is exhausted", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT id FROM users")) return { rowCount: 1, rows: [{ id: USER_ID }] };
      if (sql.includes("FROM vault_snapshots")) return { rowCount: 0, rows: [] };
      if (sql.includes("INSERT INTO vault_write_usage")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    await expect(saveVaultSnapshot(USER_ID, SNAPSHOT, 500)).rejects.toBeInstanceOf(VaultQuotaError);
    expect(mocks.query.mock.calls.map(([statement]) => String(statement)).join("\n")).toContain("INSERT INTO vault_snapshots");
    expect(mocks.query).toHaveBeenCalledWith("ROLLBACK");
  });

  it("charges bytes without a logical write when the SQL version gate rejects a race", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT id FROM users")) return { rowCount: 1, rows: [{ id: USER_ID }] };
      if (sql.includes("FROM vault_snapshots")) {
        return { rowCount: 1, rows: [{ version: 1, checksum: "older", byte_size: 1, same_envelope: false }] };
      }
      if (sql.includes("INSERT INTO vault_snapshots")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    await expect(saveVaultSnapshot(USER_ID, SNAPSHOT, 600)).rejects.toBeInstanceOf(VaultConflictError);
    expect(mocks.query).toHaveBeenCalledWith(expect.stringContaining("INSERT INTO vault_write_usage"), [
      USER_ID, 600, 0, 100, 64_000_000
    ]);
    expect(mocks.query).toHaveBeenCalledWith("COMMIT");
    expect(mocks.query).not.toHaveBeenCalledWith("ROLLBACK");
  });

  it("charges actual request bytes and stores only a strictly newer snapshot", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT id FROM users")) return { rowCount: 1, rows: [{ id: USER_ID }] };
      if (sql.includes("FROM vault_snapshots")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [{ version: 2 }] };
    });

    await expect(saveVaultSnapshot(USER_ID, SNAPSHOT, 777)).resolves.toEqual({ idempotent: false });
    expect(mocks.query).toHaveBeenCalledWith(expect.stringContaining("INSERT INTO vault_write_usage"), [
      USER_ID, 777, 1, 100, 64_000_000
    ]);
    expect(mocks.query).toHaveBeenCalledWith(expect.stringContaining("UPDATE sync_storage_usage"), [
      200, 10_000_000_000
    ]);
    expect(mocks.query).toHaveBeenCalledWith(expect.stringContaining("vault_snapshots.version < excluded.version"), expect.any(Array));
    const statements = mocks.query.mock.calls.map(([statement]) => String(statement));
    expect(statements.find((sql) => sql.includes("FROM vault_snapshots"))).toContain("FOR UPDATE");
    expect(statements.findIndex((sql) => sql.includes("INSERT INTO vault_snapshots")))
      .toBeLessThan(statements.findIndex((sql) => sql.includes("UPDATE sync_storage_usage")));
    expect(mocks.query).toHaveBeenCalledWith("COMMIT");
  });

  it("atomically rolls back the snapshot and daily usage when aggregate storage is full", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT id FROM users")) return { rowCount: 1, rows: [{ id: USER_ID }] };
      if (sql.includes("FROM vault_snapshots")) return { rowCount: 0, rows: [] };
      if (sql.includes("INSERT INTO vault_write_usage")) return { rowCount: 1, rows: [{ write_count: 1 }] };
      if (sql.includes("UPDATE sync_storage_usage")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    await expect(saveVaultSnapshot(USER_ID, SNAPSHOT, 777)).rejects.toBeInstanceOf(VaultStorageCapacityError);
    expect(mocks.query.mock.calls.map(([statement]) => String(statement)).join("\n")).toContain("INSERT INTO vault_snapshots");
    expect(mocks.query).toHaveBeenCalledWith("ROLLBACK");
  });

  it("destroys a client whose rollback also times out", async () => {
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("SELECT id FROM users")) return { rowCount: 1, rows: [{ id: USER_ID }] };
      if (sql.includes("FROM vault_snapshots")) return { rowCount: 0, rows: [] };
      if (sql.includes("INSERT INTO vault_write_usage")) return { rowCount: 0, rows: [] };
      if (sql === "ROLLBACK") throw new Error("rollback timed out");
      return { rowCount: 1, rows: [] };
    });

    await expect(saveVaultSnapshot(USER_ID, SNAPSHOT, 500)).rejects.toBeInstanceOf(VaultQuotaError);
    expect(mocks.release).toHaveBeenCalledWith(true);
  });
});
