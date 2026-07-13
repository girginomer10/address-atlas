import { randomUUID } from "node:crypto";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { RemoteVaultSnapshot } from "./envelope";
import { closeSyncPoolForTests, ensureSyncSchema, getSyncPool } from "./postgres";
import { saveVaultSnapshot, VaultConflictError, VaultQuotaError } from "./vault-storage";

const maybeDescribe = process.env.TEST_SYNC_DATABASE_URL ? describe : describe.skip;

maybeDescribe("encrypted sync Postgres storage", () => {
  const testUserIds = new Set<string>();
  let previousDatabaseURL: string | undefined;
  let previousWriteLimit: string | undefined;

  beforeAll(async () => {
    previousDatabaseURL = process.env.SYNC_DATABASE_URL;
    previousWriteLimit = process.env.SYNC_VAULT_DAILY_WRITE_LIMIT;
    process.env.SYNC_DATABASE_URL = process.env.TEST_SYNC_DATABASE_URL;
    await ensureSyncSchema();
  });

  afterEach(async () => {
    restoreEnv("SYNC_VAULT_DAILY_WRITE_LIMIT", previousWriteLimit);
    if (testUserIds.size > 0) {
      await getSyncPool().query("DELETE FROM users WHERE id = ANY($1::uuid[])", [[...testUserIds]]);
      testUserIds.clear();
    }
  });

  afterAll(async () => {
    await closeSyncPoolForTests();
    restoreEnv("SYNC_DATABASE_URL", previousDatabaseURL);
    restoreEnv("SYNC_VAULT_DAILY_WRITE_LIMIT", previousWriteLimit);
  });

  async function createUser() {
    const userId = randomUUID();
    testUserIds.add(userId);
    await getSyncPool().query("INSERT INTO users (id) VALUES ($1)", [userId]);
    return userId;
  }

  it("stores only opaque vault snapshot data", async () => {
    const pool = getSyncPool();
    const userId = await createUser();
    const snapshot = {
      schemaVersion: 1,
      cryptoVersion: 1,
      keyId: "sync-v1",
      nonce: "abc123_-",
      ciphertext: "opaqueCiphertext_-",
      checksum: "b".repeat(64)
    };
    const checksum = "a".repeat(64);
    const plaintextMarkers = [
      "0x742d35cc6634c0532925a3b844bc454e4438f44e",
      "wallet-alpha",
      "12345.67",
      "binance-secret-key",
      "usdc-token-list",
      "scan-run-history",
      "preferred-currency"
    ];

    await pool.query(
      `INSERT INTO vault_snapshots (user_id, version, envelope, byte_size, checksum)
       VALUES ($1, $2, $3::jsonb, $4, $5)`,
      [userId, 1, JSON.stringify(snapshot), JSON.stringify(snapshot).length, checksum]
    );

    const result = await pool.query(
      "SELECT user_id, version, envelope, byte_size, checksum FROM vault_snapshots WHERE user_id = $1",
      [userId]
    );
    const serialized = JSON.stringify(result.rows[0]).toLowerCase();

    expect(serialized).toContain("opaqueciphertext");
    for (const marker of plaintextMarkers) {
      expect(serialized).not.toContain(marker);
    }
  });

  it("enforces the real SQL version gate without charging a rejected conflict", async () => {
    const userId = await createUser();
    const original = remoteSnapshot(2, "a");
    await saveVaultSnapshot(userId, original, 500);

    await expect(saveVaultSnapshot(userId, remoteSnapshot(2, "b"), 700))
      .rejects.toBeInstanceOf(VaultConflictError);

    const stored = await getSyncPool().query(
      "SELECT version, checksum FROM vault_snapshots WHERE user_id = $1",
      [userId]
    );
    const usage = await getSyncPool().query(
      "SELECT write_count, byte_count FROM vault_write_usage WHERE user_id = $1",
      [userId]
    );
    expect(stored.rows[0]).toMatchObject({ version: 2, checksum: original.checksum });
    expect(Number(usage.rows[0]?.write_count)).toBe(1);
    expect(Number(usage.rows[0]?.byte_count)).toBe(500);
  });

  it("rolls back the snapshot when the real daily quota SQL rejects a write", async () => {
    process.env.SYNC_VAULT_DAILY_WRITE_LIMIT = "1";
    const userId = await createUser();
    const original = remoteSnapshot(1, "c");
    await saveVaultSnapshot(userId, original, 500);

    await expect(saveVaultSnapshot(userId, remoteSnapshot(2, "d"), 700))
      .rejects.toBeInstanceOf(VaultQuotaError);

    const stored = await getSyncPool().query(
      "SELECT version, checksum FROM vault_snapshots WHERE user_id = $1",
      [userId]
    );
    const usage = await getSyncPool().query(
      "SELECT write_count, byte_count FROM vault_write_usage WHERE user_id = $1",
      [userId]
    );
    expect(stored.rows[0]).toMatchObject({ version: 1, checksum: original.checksum });
    expect(Number(usage.rows[0]?.write_count)).toBe(1);
    expect(Number(usage.rows[0]?.byte_count)).toBe(500);
  });

  it("keeps exact retries idempotent in the real quota tables", async () => {
    process.env.SYNC_VAULT_DAILY_WRITE_LIMIT = "1";
    const userId = await createUser();
    const snapshot = remoteSnapshot(1, "e");
    await saveVaultSnapshot(userId, snapshot, 500);
    await expect(saveVaultSnapshot(userId, snapshot, 500)).resolves.toEqual({ idempotent: true });

    const usage = await getSyncPool().query(
      "SELECT write_count, byte_count FROM vault_write_usage WHERE user_id = $1",
      [userId]
    );
    expect(usage.rows[0]).toMatchObject({ write_count: 1 });
    expect(Number(usage.rows[0]?.byte_count)).toBe(500);
  });
});

function remoteSnapshot(version: number, marker: string): RemoteVaultSnapshot {
  return {
    version,
    byteSize: 200,
    checksum: marker.repeat(64),
    envelope: {
      schemaVersion: 2,
      cryptoVersion: 2,
      keyId: "sync-v2",
      nonce: "AQEBAQEBAQEBAQEB",
      ciphertext: "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC",
      checksum: marker.repeat(64),
      createdAt: "2026-07-13T10:00:00Z"
    }
  };
}

function restoreEnv(name: string, value: string | undefined) {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}
