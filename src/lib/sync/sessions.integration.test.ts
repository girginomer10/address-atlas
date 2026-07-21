import { randomBytes, randomUUID } from "node:crypto";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { RemoteVaultSnapshot } from "./envelope";
import { closeSyncPoolForTests, ensureSyncSchema, getSyncPool } from "./postgres";
import {
  accountDeletionKeyDigest,
  authenticateBearerSession,
  createSessionGrant,
  deleteBearerAccount,
  revokeBearerSession
} from "./sessions";
import { TokenValidationError } from "./tokens";
import { normalizeRequestClientKey } from "./rate-limit";
import { setStorageLedgerAuditStateForTests } from "./storage-ledger-integrity";
import { chargeVaultIngress, saveVaultSnapshot } from "./vault-storage";

const maybeDescribe = process.env.TEST_SYNC_DATABASE_URL ? describe : describe.skip;
const REQUEST_CLIENT = normalizeRequestClientKey("session-integration-test");

const SNAPSHOT: RemoteVaultSnapshot = {
  version: 1,
  byteSize: 200,
  checksum: "a".repeat(64),
  envelope: {
    schemaVersion: 2,
    cryptoVersion: 2,
    keyId: "sync-v2",
    nonce: "AQEBAQEBAQEBAQEB",
    ciphertext: "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC",
    checksum: "b".repeat(64),
    createdAt: "2026-07-20T12:00:00Z"
  }
};

maybeDescribe("session lifecycle against real Postgres", () => {
  const users = new Set<string>();
  const receiptDigests = new Set<string>();
  let previousDatabaseURL: string | undefined;
  let previousSessionSecret: string | undefined;

  beforeAll(async () => {
    previousDatabaseURL = process.env.SYNC_DATABASE_URL;
    previousSessionSecret = process.env.SYNC_SESSION_SECRET;
    process.env.SYNC_DATABASE_URL = process.env.TEST_SYNC_DATABASE_URL;
    process.env.SYNC_SESSION_SECRET = "ci-only-public-session-secret-for-session-tests";
    await ensureSyncSchema();
  });

  beforeEach(() => {
    setStorageLedgerAuditStateForTests("valid");
  });

  afterEach(async () => {
    if (users.size > 0) {
      await getSyncPool().query("DELETE FROM users WHERE id = ANY($1::uuid[])", [[...users]]);
      users.clear();
    }
    await getSyncPool().query(
      "DELETE FROM vault_global_ingress_usage WHERE usage_date = (now() AT TIME ZONE 'UTC')::date"
    );
    if (receiptDigests.size > 0) {
      await getSyncPool().query(
        "DELETE FROM account_deletion_receipts WHERE encode(idempotency_key_digest, 'hex') = ANY($1::text[])",
        [[...receiptDigests]]
      );
      receiptDigests.clear();
    }
  });

  afterAll(async () => {
    await closeSyncPoolForTests();
    restoreEnv("SYNC_DATABASE_URL", previousDatabaseURL);
    restoreEnv("SYNC_SESSION_SECRET", previousSessionSecret);
  });

  async function createUser() {
    const userId = randomUUID();
    users.add(userId);
    await getSyncPool().query("INSERT INTO users (id) VALUES ($1)", [userId]);
    return userId;
  }

  async function grant(userId: string) {
    const client = await getSyncPool().connect();
    try {
      return await createSessionGrant(client, userId);
    } finally {
      client.release();
    }
  }

  function deletionKey() {
    const raw = randomBytes(32).toString("base64url");
    const digest = accountDeletionKeyDigest(raw);
    receiptDigests.add(digest.toString("hex"));
    return { raw, digest };
  }

  it("revokes one session without invalidating another account session", async () => {
    const userId = await createUser();
    const first = await grant(userId);
    const second = await grant(userId);

    await revokeBearerSession(`Bearer ${first.sessionToken}`, REQUEST_CLIENT);
    await expect(authenticateBearerSession(`Bearer ${first.sessionToken}`, REQUEST_CLIENT))
      .rejects.toBeInstanceOf(TokenValidationError);
    await expect(authenticateBearerSession(`Bearer ${second.sessionToken}`, REQUEST_CLIENT))
      .resolves.toMatchObject({ userId, sessionId: second.session.sessionId });
  });

  it("deletes the account with all grants, credentials, usage, vault, and storage bytes", async () => {
    const userId = await createUser();
    const issued = await grant(userId);
    await getSyncPool().query(
      `INSERT INTO passkey_credentials (id, user_id, public_key_base64url, counter)
       VALUES ($1, $2, 'AQIDBA', 0)`,
      [`delete-${randomUUID()}`, userId]
    );
    await chargeVaultIngress(userId, 500);
    await saveVaultSnapshot(userId, SNAPSHOT);
    const before = await getSyncPool().query<{ total_snapshot_bytes: string }>(
      "SELECT total_snapshot_bytes::text FROM sync_storage_usage WHERE singleton = true"
    );
    const beforeIngress = await getSyncPool().query<{ byte_count: string }>(
      `SELECT byte_count::text FROM vault_global_ingress_usage
       WHERE usage_date = (now() AT TIME ZONE 'UTC')::date`
    );

    const key = deletionKey();
    await expect(deleteBearerAccount(
      `Bearer ${issued.sessionToken}`,
      key.digest,
      true,
      REQUEST_CLIENT
    ))
      .resolves.toEqual({ replayed: false });

    const after = await getSyncPool().query<{ total_snapshot_bytes: string }>(
      "SELECT total_snapshot_bytes::text FROM sync_storage_usage WHERE singleton = true"
    );
    expect(Number(after.rows[0]?.total_snapshot_bytes))
      .toBe(Number(before.rows[0]?.total_snapshot_bytes) - SNAPSHOT.byteSize);
    const afterIngress = await getSyncPool().query<{ byte_count: string }>(
      `SELECT byte_count::text FROM vault_global_ingress_usage
       WHERE usage_date = (now() AT TIME ZONE 'UTC')::date`
    );
    expect(afterIngress.rows[0]?.byte_count).toBe(beforeIngress.rows[0]?.byte_count);
    for (const table of ["users", "passkey_credentials", "session_grants", "vault_write_usage", "vault_snapshots"]) {
      const result = await getSyncPool().query(
        `SELECT count(*)::int AS count FROM ${table} WHERE ${table === "users" ? "id" : "user_id"} = $1`,
        [userId]
      );
      expect(result.rows[0]?.count).toBe(0);
    }
    await expect(authenticateBearerSession(`Bearer ${issued.sessionToken}`, REQUEST_CLIENT))
      .rejects.toBeInstanceOf(TokenValidationError);
    await expect(deleteBearerAccount(null, key.digest, false, REQUEST_CLIENT))
      .resolves.toEqual({ replayed: true });
    const receipt = await getSyncPool().query<{ digest: Buffer }>(
      `SELECT idempotency_key_digest AS digest
       FROM account_deletion_receipts
       WHERE idempotency_key_digest = $1`,
      [key.digest]
    );
    expect(receipt.rows[0]?.digest).toEqual(key.digest);
    expect(JSON.stringify(receipt.rows)).not.toContain(key.raw);
    await getSyncPool().query(
      `UPDATE account_deletion_receipts
       SET created_at = now() - interval '400 days'
       WHERE idempotency_key_digest = $1`,
      [key.digest]
    );
    // Permanent receipts resolve a lost successful response even when a client
    // was offline for far longer than an ordinary operational retention window.
    await expect(deleteBearerAccount(null, key.digest, false, REQUEST_CLIENT))
      .resolves.toEqual({ replayed: true });
    users.delete(userId);
  });

  it("serializes concurrent first calls into one deletion and one durable replay", async () => {
    const userId = await createUser();
    const issued = await grant(userId);
    const key = deletionKey();

    const results = await Promise.all([
      deleteBearerAccount(`Bearer ${issued.sessionToken}`, key.digest, true, REQUEST_CLIENT),
      deleteBearerAccount(`Bearer ${issued.sessionToken}`, key.digest, true, REQUEST_CLIENT)
    ]);

    expect(results).toEqual(expect.arrayContaining([{ replayed: false }, { replayed: true }]));
    const account = await getSyncPool().query("SELECT 1 FROM users WHERE id = $1", [userId]);
    const receipts = await getSyncPool().query(
      "SELECT count(*)::int AS count FROM account_deletion_receipts WHERE idempotency_key_digest = $1",
      [key.digest]
    );
    expect(account.rowCount).toBe(0);
    expect(receipts.rows[0]?.count).toBe(1);
    users.delete(userId);
  });

  it("rolls back the receipt when account deletion fails after claiming the key", async () => {
    const userId = await createUser();
    const issued = await grant(userId);
    const key = deletionKey();
    const functionName = `reject_delete_${randomUUID().replaceAll("-", "_")}`;
    await getSyncPool().query(`
      CREATE FUNCTION ${functionName}()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'forced deletion rollback';
      END;
      $$
    `);
    await getSyncPool().query(`
      CREATE TRIGGER ${functionName}
      BEFORE DELETE ON users
      FOR EACH ROW EXECUTE FUNCTION ${functionName}()
    `);
    try {
      await expect(deleteBearerAccount(
        `Bearer ${issued.sessionToken}`,
        key.digest,
        true,
        REQUEST_CLIENT
      ))
        .rejects.toThrow(/forced deletion rollback/i);
      const account = await getSyncPool().query("SELECT 1 FROM users WHERE id = $1", [userId]);
      const receipt = await getSyncPool().query(
        "SELECT 1 FROM account_deletion_receipts WHERE idempotency_key_digest = $1",
        [key.digest]
      );
      expect(account.rowCount).toBe(1);
      expect(receipt.rowCount).toBe(0);
    } finally {
      await getSyncPool().query(`DROP TRIGGER ${functionName} ON users`);
      await getSyncPool().query(`DROP FUNCTION ${functionName}()`);
    }
  });
});

function restoreEnv(name: string, value: string | undefined) {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}
