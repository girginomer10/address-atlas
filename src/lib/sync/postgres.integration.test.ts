import { randomUUID } from "node:crypto";
import { describe, expect, it } from "vitest";
import { ensureSyncSchema, getSyncPool } from "./postgres";

const maybeDescribe = process.env.TEST_SYNC_DATABASE_URL ? describe : describe.skip;

maybeDescribe("encrypted sync Postgres storage", () => {
  it("stores only opaque vault snapshot data", async () => {
    process.env.SYNC_DATABASE_URL = process.env.TEST_SYNC_DATABASE_URL;
    await ensureSyncSchema();
    const pool = getSyncPool();
    const userId = randomUUID();
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

    await pool.query("INSERT INTO users (id) VALUES ($1)", [userId]);
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

    await pool.query("DELETE FROM users WHERE id = $1", [userId]);
  });
});
