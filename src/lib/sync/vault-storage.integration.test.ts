import { createHash, randomUUID } from "node:crypto";
import { NextRequest } from "next/server";
import { types as pgTypes } from "pg";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { GET as getHealth, resetHealthReadinessForTests } from "@/app/healthz/route";
import { GET as getLatestVault, PUT as putLatestVault } from "@/app/vault/latest/route";
import { base64urlEncode } from "./base64url";
import {
  canonicalEnvelopeBytes,
  computeSnapshotChecksum,
  StoredVaultSnapshotIntegrityError,
  type EncryptedVaultEnvelope,
  type RemoteVaultSnapshot
} from "./envelope";
import {
  closeSyncPoolForTests,
  ensureSyncSchema,
  getSyncPool
} from "./postgres";
import { resetRateLimitsForTests } from "./rate-limit";
import { issueSessionToken } from "./tokens";
import { setStorageLedgerAuditStateForTests } from "./storage-ledger-integrity";
import { assertStoredVaultIntegrity } from "./vault-integrity";
import {
  assertVaultIngressCapacity,
  chargeVaultIngress,
  saveVaultSnapshot,
  VaultAccountMissingError,
  VaultConflictError,
  VaultGlobalIngressQuotaError,
  VaultQuotaError
} from "./vault-storage";

const maybeDescribe = process.env.TEST_SYNC_DATABASE_URL ? describe : describe.skip;
maybeDescribe("encrypted vault Postgres storage and routes", () => {
  const testUserIds = new Set<string>();
  let previousDatabaseURL: string | undefined;
  let previousSessionSecret: string | undefined;
  let previousByteLimit: string | undefined;
  let previousWriteLimit: string | undefined;
  let previousGlobalIngressLimit: string | undefined;

  beforeAll(async () => {
    previousDatabaseURL = process.env.SYNC_DATABASE_URL;
    previousSessionSecret = process.env.SYNC_SESSION_SECRET;
    previousByteLimit = process.env.SYNC_VAULT_DAILY_BYTE_LIMIT;
    previousWriteLimit = process.env.SYNC_VAULT_DAILY_WRITE_LIMIT;
    previousGlobalIngressLimit = process.env.SYNC_GLOBAL_VAULT_DAILY_INGRESS_BYTE_LIMIT;
    process.env.SYNC_DATABASE_URL = process.env.TEST_SYNC_DATABASE_URL;
    process.env.SYNC_SESSION_SECRET = "ci-only-public-session-secret-for-integration-tests";
    await ensureSyncSchema();
  });

  beforeEach(() => {
    setStorageLedgerAuditStateForTests("valid");
  });

  afterEach(async () => {
    resetRateLimitsForTests();
    restoreEnv("SYNC_VAULT_DAILY_BYTE_LIMIT", previousByteLimit);
    restoreEnv("SYNC_VAULT_DAILY_WRITE_LIMIT", previousWriteLimit);
    restoreEnv("SYNC_GLOBAL_VAULT_DAILY_INGRESS_BYTE_LIMIT", previousGlobalIngressLimit);
    await getSyncPool().query(
      "DELETE FROM vault_global_ingress_usage WHERE usage_date = (now() AT TIME ZONE 'UTC')::date"
    );
    if (testUserIds.size > 0) {
      await getSyncPool().query("DELETE FROM users WHERE id = ANY($1::uuid[])", [[...testUserIds]]);
      testUserIds.clear();
    }
  });

  afterAll(async () => {
    await closeSyncPoolForTests();
    restoreEnv("SYNC_DATABASE_URL", previousDatabaseURL);
    restoreEnv("SYNC_SESSION_SECRET", previousSessionSecret);
    restoreEnv("SYNC_VAULT_DAILY_BYTE_LIMIT", previousByteLimit);
    restoreEnv("SYNC_VAULT_DAILY_WRITE_LIMIT", previousWriteLimit);
    restoreEnv("SYNC_GLOBAL_VAULT_DAILY_INGRESS_BYTE_LIMIT", previousGlobalIngressLimit);
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

    const byteSize = JSON.stringify(snapshot).length;
    await pool.query(
      `INSERT INTO vault_snapshots (user_id, version, envelope, byte_size, checksum)
       VALUES ($1, $2, $3::jsonb, $4, $5)`,
      [userId, 1, JSON.stringify(snapshot), byteSize, checksum]
    );
    // This bypasses saveVaultSnapshot, so mirror its global-counter charge:
    // the strict delete trigger fails closed if the cascade decrement at
    // cleanup would push the counter below zero.
    await pool.query(
      `UPDATE sync_storage_usage
       SET total_snapshot_bytes = total_snapshot_bytes + $1, updated_at = now()
       WHERE singleton = true`,
      [byteSize]
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

  it("returns 404 for a real account that has no vault snapshot", async () => {
    const userId = await createUser();

    const response = await getLatestVault(vaultRequest(await createSessionToken(userId)));

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "No vault snapshot." });
  });

  it("returns 401 when a real account is deleted after its session was issued", async () => {
    const userId = await createUser();
    const sessionToken = await createSessionToken(userId);
    await getSyncPool().query("DELETE FROM users WHERE id = $1", [userId]);

    const response = await getLatestVault(vaultRequest(sessionToken));

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "Authentication required." });
  });

  it("round-trips an uploaded snapshot through the real PUT and GET handlers", async () => {
    const userId = await createUser();
    const sessionToken = await createSessionToken(userId);
    const snapshot = uploadableSnapshot(3, 7);

    const putResponse = await putLatestVault(new NextRequest("http://localhost/vault/latest", {
      method: "PUT",
      headers: {
        authorization: `Bearer ${sessionToken}`,
        "content-type": "application/json"
      },
      body: JSON.stringify(snapshot)
    }));

    expect(putResponse.status).toBe(200);
    expect(await putResponse.json()).toEqual({ ok: true, idempotent: false });

    const getResponse = await getLatestVault(vaultRequest(sessionToken));

    expect(getResponse.status).toBe(200);
    expect(getResponse.headers.get("cache-control")).toBe("no-store");
    const body = await getResponse.json();
    expect(body).toEqual({
      version: snapshot.version,
      envelope: snapshot.envelope,
      byteSize: snapshot.byteSize,
      checksum: snapshot.checksum,
      updatedAt: expect.any(String)
    });
    expect(new Date(body.updatedAt).toISOString()).toBe(body.updatedAt);
  });

  it.each([
    ["non-object", "'[]'::jsonb"],
    [
      "oversized",
      "pg_catalog.jsonb_build_object('blob', pg_catalog.repeat('x', 8100001))"
    ]
  ])("rejects a %s stored envelope without returning it to the pg client", async (_case, envelopeSQL) => {
    const userId = await createUser();
    const sessionToken = await createSessionToken(userId);
    await getSyncPool().query(
      `INSERT INTO vault_snapshots (user_id, version, envelope, byte_size, checksum)
       VALUES ($1, 1, ${envelopeSQL}, 1, pg_catalog.repeat('a', 64))`,
      [userId]
    );
    await getSyncPool().query(
      `UPDATE sync_storage_usage
       SET total_snapshot_bytes = total_snapshot_bytes + 1, updated_at = now()
       WHERE singleton = true`
    );

    const originalJSONBParser = pgTypes.getTypeParser(3802, "text");
    let jsonbDeserializations = 0;
    pgTypes.setTypeParser(3802, (value) => {
      jsonbDeserializations += 1;
      return originalJSONBParser(value);
    });
    const errorLog = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      const response = await getLatestVault(vaultRequest(sessionToken));

      expect(response.status).toBe(500);
      expect(await response.json()).toEqual({ error: "Vault snapshot could not be loaded." });
      expect(jsonbDeserializations).toBe(0);
      expect(JSON.parse(String(errorLog.mock.calls.at(-1)?.[0]))).toMatchObject({
        reason: "stored_snapshot_invalid",
        errorCode: "vault_snapshot_invalid"
      });
    } finally {
      errorLog.mockRestore();
      pgTypes.setTypeParser(3802, originalJSONBParser);
    }
  });

  it("fails a restore scan on a non-object row without deserializing its envelope", async () => {
    const userId = await createUser();
    await getSyncPool().query(
      `INSERT INTO vault_snapshots (user_id, version, envelope, byte_size, checksum)
       VALUES ($1, 1, '[]'::jsonb, 1, pg_catalog.repeat('a', 64))`,
      [userId]
    );
    await getSyncPool().query(
      `UPDATE sync_storage_usage
       SET total_snapshot_bytes = total_snapshot_bytes + 1, updated_at = now()
       WHERE singleton = true`
    );

    const originalJSONBParser = pgTypes.getTypeParser(3802, "text");
    let jsonbDeserializations = 0;
    pgTypes.setTypeParser(3802, (value) => {
      jsonbDeserializations += 1;
      return originalJSONBParser(value);
    });
    try {
      await expect(assertStoredVaultIntegrity(getSyncPool()))
        .rejects.toBeInstanceOf(StoredVaultSnapshotIntegrityError);
      expect(jsonbDeserializations).toBe(0);
    } finally {
      pgTypes.setTypeParser(3802, originalJSONBParser);
    }
  });

  it("reports healthy only after the initial real storage-ledger audit completes", async () => {
    resetHealthReadinessForTests();

    const initial = await getHealth();
    expect(initial.status).toBe(503);

    let response: Response | undefined;
    await vi.waitFor(async () => {
      response = await getHealth();
      expect(response.status).toBe(200);
    }, { timeout: 3_000, interval: 100 });

    expect(response!.headers.get("cache-control")).toBe("no-store");
    expect(await response!.json()).toEqual({ ok: true, service: "address-atlas-sync" });
  });

  it("charges real request bytes for a rejected conflict without incrementing writes", async () => {
    const userId = await createUser();
    const original = remoteSnapshot(2, "a");
    await chargeVaultIngress(userId, 500);
    await saveVaultSnapshot(userId, original);

    await chargeVaultIngress(userId, 700);
    await expect(saveVaultSnapshot(userId, remoteSnapshot(2, "b")))
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
    expect(Number(usage.rows[0]?.byte_count)).toBe(1_200);
  });

  it("rolls back the snapshot when the real daily quota SQL rejects a write", async () => {
    process.env.SYNC_VAULT_DAILY_WRITE_LIMIT = "1";
    const userId = await createUser();
    const original = remoteSnapshot(1, "c");
    await chargeVaultIngress(userId, 500);
    await saveVaultSnapshot(userId, original);

    await chargeVaultIngress(userId, 700);
    await expect(saveVaultSnapshot(userId, remoteSnapshot(2, "d")))
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
    expect(Number(usage.rows[0]?.byte_count)).toBe(1_200);
  });

  it("charges exact-retry bytes without incrementing the real write counter", async () => {
    process.env.SYNC_VAULT_DAILY_WRITE_LIMIT = "1";
    const userId = await createUser();
    const snapshot = remoteSnapshot(1, "e");
    await chargeVaultIngress(userId, 500);
    await saveVaultSnapshot(userId, snapshot);
    await chargeVaultIngress(userId, 500);
    await expect(saveVaultSnapshot(userId, snapshot)).resolves.toEqual({ idempotent: true });

    const usage = await getSyncPool().query(
      "SELECT write_count, byte_count FROM vault_write_usage WHERE user_id = $1",
      [userId]
    );
    expect(usage.rows[0]).toMatchObject({ write_count: 1 });
    expect(Number(usage.rows[0]?.byte_count)).toBe(1_000);
  });

  it("saturates account ingress and commits actual global bytes before rejecting", async () => {
    process.env.SYNC_VAULT_DAILY_BYTE_LIMIT = "8100000";
    process.env.SYNC_GLOBAL_VAULT_DAILY_INGRESS_BYTE_LIMIT = "20000000";
    const userId = await createUser();
    const snapshot = remoteSnapshot(1, "f");
    await chargeVaultIngress(userId, 4_100_000);
    await saveVaultSnapshot(userId, snapshot);

    await expect(chargeVaultIngress(userId, 4_100_000))
      .rejects.toBeInstanceOf(VaultQuotaError);

    const usage = await getSyncPool().query(
      "SELECT write_count, byte_count FROM vault_write_usage WHERE user_id = $1",
      [userId]
    );
    const globalUsage = await getSyncPool().query(
      "SELECT byte_count FROM vault_global_ingress_usage WHERE usage_date = (now() AT TIME ZONE 'UTC')::date"
    );
    expect(usage.rows[0]).toMatchObject({ write_count: 1 });
    expect(Number(usage.rows[0]?.byte_count)).toBe(8_100_000);
    expect(Number(globalUsage.rows[0]?.byte_count)).toBe(8_200_000);
    await expect(assertVaultIngressCapacity(userId)).rejects.toBeInstanceOf(VaultQuotaError);
  });

  it("does not create or charge global ingress for a missing account", async () => {
    const missingUserId = randomUUID();

    await expect(assertVaultIngressCapacity(missingUserId))
      .rejects.toBeInstanceOf(VaultAccountMissingError);
    await expect(chargeVaultIngress(missingUserId, 500))
      .rejects.toBeInstanceOf(VaultAccountMissingError);

    const globalUsage = await getSyncPool().query(
      "SELECT byte_count FROM vault_global_ingress_usage WHERE usage_date = (now() AT TIME ZONE 'UTC')::date"
    );
    expect(globalUsage.rowCount).toBe(0);
  });

  it("charges global ingress when deletion wins after durable admission", async () => {
    const userId = await createUser();
    const admission = await assertVaultIngressCapacity(userId);
    await getSyncPool().query("DELETE FROM users WHERE id = $1", [userId]);

    await expect(chargeVaultIngress(userId, 500, admission))
      .rejects.toBeInstanceOf(VaultAccountMissingError);

    const globalUsage = await getSyncPool().query(
      "SELECT byte_count FROM vault_global_ingress_usage WHERE usage_date = (now() AT TIME ZONE 'UTC')::date"
    );
    expect(Number(globalUsage.rows[0]?.byte_count)).toBe(500);
  });

  it("accounts for both bodies admitted concurrently before account exhaustion", async () => {
    process.env.SYNC_VAULT_DAILY_BYTE_LIMIT = "8100000";
    process.env.SYNC_GLOBAL_VAULT_DAILY_INGRESS_BYTE_LIMIT = "20000000";
    const userId = await createUser();

    await Promise.all([
      assertVaultIngressCapacity(userId),
      assertVaultIngressCapacity(userId)
    ]);
    const results = await Promise.allSettled([
      chargeVaultIngress(userId, 4_500_000),
      chargeVaultIngress(userId, 4_500_000)
    ]);

    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(results.find((result) => result.status === "rejected")).toMatchObject({
      status: "rejected",
      reason: expect.any(VaultQuotaError)
    });
    const accountUsage = await getSyncPool().query(
      "SELECT byte_count FROM vault_write_usage WHERE user_id = $1",
      [userId]
    );
    const globalUsage = await getSyncPool().query(
      "SELECT byte_count FROM vault_global_ingress_usage WHERE usage_date = (now() AT TIME ZONE 'UTC')::date"
    );
    expect(Number(accountUsage.rows[0]?.byte_count)).toBe(8_100_000);
    expect(Number(globalUsage.rows[0]?.byte_count)).toBe(9_000_000);
    await expect(assertVaultIngressCapacity(userId)).rejects.toBeInstanceOf(VaultQuotaError);
  });

  it("serializes concurrent same-version CAS so exactly one writer commits", async () => {
    const userId = await createUser();
    await Promise.all([
      chargeVaultIngress(userId, 500),
      chargeVaultIngress(userId, 700)
    ]);

    const results = await Promise.allSettled([
      saveVaultSnapshot(userId, remoteSnapshot(1, "i")),
      saveVaultSnapshot(userId, remoteSnapshot(1, "j"))
    ]);
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    const rejected = results.find((result) => result.status === "rejected");
    expect(rejected).toMatchObject({ status: "rejected", reason: expect.any(VaultConflictError) });

    const stored = await getSyncPool().query(
      "SELECT version, checksum FROM vault_snapshots WHERE user_id = $1",
      [userId]
    );
    const usage = await getSyncPool().query(
      "SELECT write_count, byte_count FROM vault_write_usage WHERE user_id = $1",
      [userId]
    );
    expect(stored.rows[0]?.version).toBe(1);
    expect(["i".repeat(64), "j".repeat(64)]).toContain(stored.rows[0]?.checksum);
    expect(Number(usage.rows[0]?.write_count)).toBe(1);
    expect(Number(usage.rows[0]?.byte_count)).toBe(1_200);
  });

  it("enforces the durable global ingress boundary across concurrent accounts", async () => {
    process.env.SYNC_GLOBAL_VAULT_DAILY_INGRESS_BYTE_LIMIT = "8100000";
    const firstUser = await createUser();
    const secondUser = await createUser();

    const results = await Promise.allSettled([
      chargeVaultIngress(firstUser, 4_500_000),
      chargeVaultIngress(secondUser, 4_500_000)
    ]);
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    const rejected = results.find((result) => result.status === "rejected");
    expect(rejected).toMatchObject({
      status: "rejected",
      reason: expect.any(VaultGlobalIngressQuotaError)
    });

    const global = await getSyncPool().query(
      `SELECT byte_count FROM vault_global_ingress_usage
       WHERE usage_date = (now() AT TIME ZONE 'UTC')::date`
    );
    expect(Number(global.rows[0]?.byte_count)).toBe(9_000_000);
    await expect(assertVaultIngressCapacity(firstUser))
      .rejects.toBeInstanceOf(VaultGlobalIngressQuotaError);
    await expect(assertVaultIngressCapacity(secondUser))
      .rejects.toBeInstanceOf(VaultGlobalIngressQuotaError);
  });
});

function vaultRequest(sessionToken: string) {
  return new NextRequest("http://localhost/vault/latest", {
    headers: { authorization: `Bearer ${sessionToken}` }
  });
}

async function createSessionToken(userId: string) {
  const sessionId = randomUUID();
  await getSyncPool().query(
    `INSERT INTO session_grants (id, user_id, expires_at)
     VALUES ($1, $2, now() + interval '1 hour')`,
    [sessionId, userId]
  );
  return issueSessionToken(userId, sessionId);
}

/** A v2 snapshot whose inner and outer checksums survive the route's real validation chain. */
function uploadableSnapshot(version: number, fill: number): RemoteVaultSnapshot {
  const nonce = Buffer.alloc(12, fill);
  const ciphertext = Buffer.alloc(48, fill + 1);
  const envelope: EncryptedVaultEnvelope = {
    schemaVersion: 2,
    cryptoVersion: 2,
    keyId: "sync-v2",
    nonce: base64urlEncode(nonce),
    ciphertext: base64urlEncode(ciphertext),
    checksum: createHash("sha256")
      .update(Buffer.from("schema:2|crypto:2|key:sync-v2|", "utf8"))
      .update(nonce)
      .update(ciphertext)
      .digest("hex"),
    createdAt: "2026-07-13T10:00:00Z"
  };
  const canonical = canonicalEnvelopeBytes(envelope);
  return {
    version,
    envelope,
    byteSize: canonical.byteLength,
    checksum: computeSnapshotChecksum(version, envelope, canonical)
  };
}

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
