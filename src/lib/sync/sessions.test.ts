import { createHash } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { normalizeRequestClientKey } from "./rate-limit";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const SESSION_ID = "22222222-2222-4222-8222-222222222222";
const KEY_BYTES = Buffer.alloc(32, 9);
const KEY = KEY_BYTES.toString("base64url");
const KEY_DIGEST = createHash("sha256").update(KEY_BYTES).digest();
const REQUEST_CLIENT = normalizeRequestClientKey("test-client");

const mocks = vi.hoisted(() => ({
  ensureSyncSchema: vi.fn(),
  poolQuery: vi.fn(),
  connect: vi.fn(),
  clientQuery: vi.fn(),
  release: vi.fn(),
  releaseDatabase: vi.fn(),
  releaseReplayDatabase: vi.fn(),
  acquireBearerSessionDatabaseConcurrency: vi.fn(),
  acquireAccountDeletionReplayDatabaseConcurrency: vi.fn(),
  issueSessionToken: vi.fn(),
  readBearerToken: vi.fn()
}));

vi.mock("./auth-database-concurrency", async (importOriginal) => ({
  ...(await importOriginal<typeof import("./auth-database-concurrency")>()),
  acquireBearerSessionDatabaseConcurrency: mocks.acquireBearerSessionDatabaseConcurrency,
  acquireAccountDeletionReplayDatabaseConcurrency:
    mocks.acquireAccountDeletionReplayDatabaseConcurrency
}));

vi.mock("./config", async (importOriginal) => ({
  ...(await importOriginal<typeof import("./config")>()),
  getSyncDatabasePoolSize: () => 10
}));

vi.mock("./postgres", () => ({
  ensureSyncSchema: mocks.ensureSyncSchema,
  getSyncPool: () => ({ query: mocks.poolQuery, connect: mocks.connect })
}));

vi.mock("./tokens", async (importOriginal) => ({
  ...(await importOriginal<typeof import("./tokens")>()),
  issueSessionToken: mocks.issueSessionToken,
  readBearerToken: mocks.readBearerToken
}));

import {
  AccountDeletionConfirmationError,
  accountDeletionKeyDigest,
  AccountDeletionIdempotencyKeyError,
  authenticateBearerSession,
  createSessionGrant,
  deleteBearerAccount,
  revokeBearerSession
} from "./sessions";
import { AuthenticationDatabaseCapacityError } from "./auth-database-concurrency";
import { TokenValidationError } from "./tokens";

describe("durable session lifecycle", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.ensureSyncSchema.mockResolvedValue(undefined);
    mocks.acquireBearerSessionDatabaseConcurrency.mockReturnValue(mocks.releaseDatabase);
    mocks.acquireAccountDeletionReplayDatabaseConcurrency.mockReturnValue(
      mocks.releaseReplayDatabase
    );
    mocks.readBearerToken.mockReturnValue({
      userId: USER_ID,
      sessionId: SESSION_ID,
      issuedAt: Date.now(),
      expiresAt: Date.now() + 60_000
    });
    mocks.issueSessionToken.mockReturnValue("session-token");
    mocks.poolQuery.mockResolvedValue({ rowCount: 1, rows: [{ id: SESSION_ID }] });
    mocks.connect.mockResolvedValue({ query: mocks.clientQuery, release: mocks.release });
    mocks.clientQuery.mockResolvedValue({ rowCount: 1, rows: [{ id: USER_ID }] });
  });

  it("persists a session grant before issuing its bound token", async () => {
    const client = { query: mocks.clientQuery };
    const issued = await createSessionGrant(client as never, USER_ID);

    expect(issued.sessionToken).toBe("session-token");
    expect(mocks.clientQuery).toHaveBeenCalledWith(
      expect.stringContaining("INSERT INTO session_grants"),
      [expect.stringMatching(/^[0-9a-f-]{36}$/), USER_ID, expect.any(Number)]
    );
    const insertedSessionId = mocks.clientQuery.mock.calls[0]?.[1]?.[0];
    expect(mocks.issueSessionToken).toHaveBeenCalledWith(USER_ID, insertedSessionId, expect.any(Number));
  });

  it("accepts only a live DB grant bound to the token account", async () => {
    await expect(authenticateBearerSession("Bearer token", REQUEST_CLIENT)).resolves.toMatchObject({
      userId: USER_ID,
      sessionId: SESSION_ID
    });
    expect(mocks.poolQuery).toHaveBeenCalledWith(expect.stringContaining("grant_row.expires_at > now()"), [
      SESSION_ID, USER_ID
    ]);

    mocks.poolQuery.mockResolvedValueOnce({ rowCount: 0, rows: [] });
    await expect(authenticateBearerSession("Bearer revoked", REQUEST_CLIENT))
      .rejects.toBeInstanceOf(TokenValidationError);
    expect(mocks.acquireBearerSessionDatabaseConcurrency).toHaveBeenCalledWith(
      REQUEST_CLIENT,
      SESSION_ID,
      10
    );
    expect(mocks.readBearerToken.mock.invocationCallOrder[0])
      .toBeLessThan(mocks.acquireBearerSessionDatabaseConcurrency.mock.invocationCallOrder[0]!);
    expect(mocks.acquireBearerSessionDatabaseConcurrency.mock.invocationCallOrder[0])
      .toBeLessThan(mocks.ensureSyncSchema.mock.invocationCallOrder[0]!);
    expect(mocks.releaseDatabase).toHaveBeenCalledTimes(2);
  });

  it("revokes only the current bound session", async () => {
    await expect(revokeBearerSession("Bearer token", REQUEST_CLIENT)).resolves.toBeUndefined();
    expect(mocks.poolQuery).toHaveBeenCalledWith(expect.stringContaining("DELETE FROM session_grants"), [
      SESSION_ID, USER_ID
    ]);

    mocks.poolQuery.mockResolvedValueOnce({ rowCount: 0, rows: [] });
    await expect(revokeBearerSession("Bearer token", REQUEST_CLIENT))
      .rejects.toBeInstanceOf(TokenValidationError);
    expect(mocks.releaseDatabase).toHaveBeenCalledTimes(2);
  });

  it("keeps invalid token envelopes outside permits and database work", async () => {
    mocks.readBearerToken.mockImplementation(() => {
      throw new TokenValidationError();
    });

    await expect(authenticateBearerSession("Bearer unsigned", REQUEST_CLIENT))
      .rejects.toBeInstanceOf(TokenValidationError);
    await expect(revokeBearerSession("Bearer unsigned", REQUEST_CLIENT))
      .rejects.toBeInstanceOf(TokenValidationError);
    await expect(deleteBearerAccount("Bearer unsigned", KEY_DIGEST, true, REQUEST_CLIENT))
      .rejects.toBeInstanceOf(TokenValidationError);

    expect(mocks.acquireBearerSessionDatabaseConcurrency).not.toHaveBeenCalled();
    expect(mocks.ensureSyncSchema).not.toHaveBeenCalled();
    expect(mocks.poolQuery).not.toHaveBeenCalled();
    expect(mocks.connect).not.toHaveBeenCalled();
  });

  it("rejects saturated authentication capacity before database work", async () => {
    mocks.acquireBearerSessionDatabaseConcurrency.mockReturnValueOnce(null);

    await expect(authenticateBearerSession("Bearer token", REQUEST_CLIENT))
      .rejects.toBeInstanceOf(AuthenticationDatabaseCapacityError);

    expect(mocks.readBearerToken).toHaveBeenCalledOnce();
    expect(mocks.ensureSyncSchema).not.toHaveBeenCalled();
    expect(mocks.poolQuery).not.toHaveBeenCalled();
  });

  it("releases admission when schema setup or a live grant query fails", async () => {
    mocks.ensureSyncSchema.mockRejectedValueOnce(new Error("schema unavailable"));
    await expect(authenticateBearerSession("Bearer token", REQUEST_CLIENT))
      .rejects.toThrow("schema unavailable");
    expect(mocks.releaseDatabase).toHaveBeenCalledOnce();

    mocks.releaseDatabase.mockClear();
    mocks.poolQuery.mockRejectedValueOnce(new Error("query unavailable"));
    await expect(revokeBearerSession("Bearer token", REQUEST_CLIENT))
      .rejects.toThrow("query unavailable");
    expect(mocks.releaseDatabase).toHaveBeenCalledOnce();
  });

  it("accepts only canonical 32-byte unpadded base64url deletion keys", () => {
    expect(accountDeletionKeyDigest(KEY)).toEqual(KEY_DIGEST);
    const canonicalZero = Buffer.alloc(32).toString("base64url");
    const nonCanonicalAlias = `${canonicalZero.slice(0, -1)}B`;
    for (const invalid of [null, "", "short", `${KEY}=`, nonCanonicalAlias]) {
      expect(() => accountDeletionKeyDigest(invalid)).toThrow(AccountDeletionIdempotencyKeyError);
    }
  });

  it("keeps an invalid deletion digest outside replay admission and database work", async () => {
    await expect(deleteBearerAccount(
      null,
      Buffer.alloc(31),
      false,
      REQUEST_CLIENT
    )).rejects.toBeInstanceOf(AccountDeletionIdempotencyKeyError);

    expect(mocks.acquireAccountDeletionReplayDatabaseConcurrency).not.toHaveBeenCalled();
    expect(mocks.ensureSyncSchema).not.toHaveBeenCalled();
    expect(mocks.poolQuery).not.toHaveBeenCalled();
  });

  it("returns a durable replay before parsing a now-invalid session", async () => {
    const result = await deleteBearerAccount(null, KEY_DIGEST, false, REQUEST_CLIENT);

    expect(result).toEqual({ replayed: true });
    expect(mocks.readBearerToken).not.toHaveBeenCalled();
    expect(mocks.connect).not.toHaveBeenCalled();
    expect(mocks.poolQuery).toHaveBeenCalledWith(
      expect.stringContaining("account_deletion_receipts"),
      [KEY_DIGEST]
    );
    expect(mocks.acquireAccountDeletionReplayDatabaseConcurrency).toHaveBeenCalledWith(
      REQUEST_CLIENT,
      KEY_DIGEST.toString("hex"),
      10
    );
    expect(mocks.releaseReplayDatabase).toHaveBeenCalledOnce();
  });

  it("releases live-auth admission on a confirmed durable replay", async () => {
    await expect(deleteBearerAccount("Bearer token", KEY_DIGEST, true, REQUEST_CLIENT))
      .resolves.toEqual({ replayed: true });

    expect(mocks.readBearerToken).toHaveBeenCalledOnce();
    expect(mocks.acquireBearerSessionDatabaseConcurrency).toHaveBeenCalledOnce();
    expect(mocks.connect).not.toHaveBeenCalled();
    expect(mocks.releaseDatabase).toHaveBeenCalledOnce();
  });

  it("requires confirmation for a first call before parsing authentication", async () => {
    mocks.poolQuery.mockResolvedValueOnce({ rowCount: 0, rows: [] });
    await expect(deleteBearerAccount("Bearer secret", KEY_DIGEST, false, REQUEST_CLIENT))
      .rejects.toBeInstanceOf(AccountDeletionConfirmationError);
    expect(mocks.readBearerToken).not.toHaveBeenCalled();
    expect(mocks.connect).not.toHaveBeenCalled();
    expect(mocks.releaseReplayDatabase).toHaveBeenCalledOnce();
  });

  it("rejects saturated replay capacity before schema or receipt work", async () => {
    mocks.acquireAccountDeletionReplayDatabaseConcurrency.mockReturnValueOnce(null);

    await expect(deleteBearerAccount(null, KEY_DIGEST, false, REQUEST_CLIENT))
      .rejects.toBeInstanceOf(AuthenticationDatabaseCapacityError);

    expect(mocks.ensureSyncSchema).not.toHaveBeenCalled();
    expect(mocks.poolQuery).not.toHaveBeenCalled();
    expect(mocks.releaseReplayDatabase).not.toHaveBeenCalled();
  });

  it("releases replay admission when schema setup or receipt lookup fails", async () => {
    mocks.ensureSyncSchema.mockRejectedValueOnce(new Error("schema unavailable"));

    await expect(deleteBearerAccount(null, KEY_DIGEST, false, REQUEST_CLIENT))
      .rejects.toThrow("schema unavailable");

    expect(mocks.poolQuery).not.toHaveBeenCalled();
    expect(mocks.releaseReplayDatabase).toHaveBeenCalledOnce();

    mocks.releaseReplayDatabase.mockClear();
    mocks.poolQuery.mockRejectedValueOnce(new Error("receipt unavailable"));
    await expect(deleteBearerAccount(null, KEY_DIGEST, false, REQUEST_CLIENT))
      .rejects.toThrow("receipt unavailable");
    expect(mocks.releaseReplayDatabase).toHaveBeenCalledOnce();
  });

  it("records the receipt and account deletion in one transaction", async () => {
    mocks.poolQuery.mockResolvedValueOnce({ rowCount: 0, rows: [] });

    await expect(deleteBearerAccount("Bearer token", KEY_DIGEST, true, REQUEST_CLIENT))
      .resolves.toEqual({ replayed: false });

    const statements = mocks.clientQuery.mock.calls.map(([sql]) => String(sql));
    const receiptIndex = statements.findIndex((sql) => sql.includes("INSERT INTO account_deletion_receipts"));
    const accountLockIndex = statements.findIndex((sql) => sql.includes("FOR UPDATE OF account"));
    const deleteIndex = statements.findIndex((sql) => sql.includes("DELETE FROM users"));
    expect(statements[0]).toBe("BEGIN");
    expect(receiptIndex).toBeGreaterThan(0);
    expect(accountLockIndex).toBeGreaterThan(receiptIndex);
    expect(deleteIndex).toBeGreaterThan(accountLockIndex);
    expect(statements.at(-1)).toBe("COMMIT");
    expect(mocks.clientQuery).toHaveBeenCalledWith(
      expect.stringContaining("INSERT INTO account_deletion_receipts"),
      [KEY_DIGEST]
    );
    expect(mocks.clientQuery).toHaveBeenCalledWith(
      "DELETE FROM users WHERE id = $1 RETURNING id",
      [USER_ID]
    );
    expect(mocks.releaseDatabase).toHaveBeenCalledOnce();
  });

  it("turns a concurrent unique-key winner into a successful replay", async () => {
    mocks.poolQuery.mockResolvedValueOnce({ rowCount: 0, rows: [] });
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (sql.includes("INSERT INTO account_deletion_receipts")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    await expect(deleteBearerAccount("Bearer token", KEY_DIGEST, true, REQUEST_CLIENT))
      .resolves.toEqual({ replayed: true });
    expect(mocks.clientQuery).not.toHaveBeenCalledWith(
      expect.stringContaining("FOR UPDATE OF account"),
      expect.anything()
    );
    expect(mocks.clientQuery).toHaveBeenCalledWith("COMMIT");
    expect(mocks.releaseDatabase).toHaveBeenCalledOnce();
  });

  it("requires recent passkey authentication for a first deletion", async () => {
    mocks.poolQuery.mockResolvedValueOnce({ rowCount: 0, rows: [] });
    mocks.readBearerToken.mockReturnValueOnce({
      userId: USER_ID,
      sessionId: SESSION_ID,
      issuedAt: Date.now() - 5 * 60_000 - 1,
      expiresAt: Date.now() + 60_000
    });
    await expect(deleteBearerAccount("Bearer old-token", KEY_DIGEST, true, REQUEST_CLIENT))
      .rejects.toBeInstanceOf(TokenValidationError);
    expect(mocks.acquireBearerSessionDatabaseConcurrency).not.toHaveBeenCalled();
    expect(mocks.ensureSyncSchema).not.toHaveBeenCalled();
    expect(mocks.connect).not.toHaveBeenCalled();
  });

  it("rolls back the provisional receipt and destroys an ambiguous client", async () => {
    mocks.poolQuery.mockResolvedValueOnce({ rowCount: 0, rows: [] });
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (sql.includes("FOR UPDATE OF account")) return { rowCount: 0, rows: [] };
      if (sql === "ROLLBACK") throw new Error("rollback timed out");
      return { rowCount: 1, rows: [] };
    });

    await expect(deleteBearerAccount("Bearer token", KEY_DIGEST, true, REQUEST_CLIENT))
      .rejects.toBeInstanceOf(TokenValidationError);
    expect(mocks.release).toHaveBeenCalledWith(true);
    expect(mocks.releaseDatabase).toHaveBeenCalledOnce();
    const rollbackIndex = mocks.clientQuery.mock.calls.findIndex(([sql]) => sql === "ROLLBACK");
    expect(mocks.releaseDatabase.mock.invocationCallOrder[0])
      .toBeLessThan(mocks.clientQuery.mock.invocationCallOrder[rollbackIndex]!);
  });
});
