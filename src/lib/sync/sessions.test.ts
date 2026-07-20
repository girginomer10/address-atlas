import { createHash } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const SESSION_ID = "22222222-2222-4222-8222-222222222222";
const KEY_BYTES = Buffer.alloc(32, 9);
const KEY = KEY_BYTES.toString("base64url");
const KEY_DIGEST = createHash("sha256").update(KEY_BYTES).digest();

const mocks = vi.hoisted(() => ({
  ensureSyncSchema: vi.fn(),
  poolQuery: vi.fn(),
  connect: vi.fn(),
  clientQuery: vi.fn(),
  release: vi.fn(),
  issueSessionToken: vi.fn(),
  readBearerToken: vi.fn()
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
import { TokenValidationError } from "./tokens";

describe("durable session lifecycle", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.ensureSyncSchema.mockResolvedValue(undefined);
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
    await expect(authenticateBearerSession("Bearer token")).resolves.toMatchObject({
      userId: USER_ID,
      sessionId: SESSION_ID
    });
    expect(mocks.poolQuery).toHaveBeenCalledWith(expect.stringContaining("grant_row.expires_at > now()"), [
      SESSION_ID, USER_ID
    ]);

    mocks.poolQuery.mockResolvedValueOnce({ rowCount: 0, rows: [] });
    await expect(authenticateBearerSession("Bearer revoked")).rejects.toBeInstanceOf(TokenValidationError);
  });

  it("revokes only the current bound session", async () => {
    await expect(revokeBearerSession("Bearer token")).resolves.toBeUndefined();
    expect(mocks.poolQuery).toHaveBeenCalledWith(expect.stringContaining("DELETE FROM session_grants"), [
      SESSION_ID, USER_ID
    ]);

    mocks.poolQuery.mockResolvedValueOnce({ rowCount: 0, rows: [] });
    await expect(revokeBearerSession("Bearer token")).rejects.toBeInstanceOf(TokenValidationError);
  });

  it("accepts only canonical 32-byte unpadded base64url deletion keys", () => {
    expect(accountDeletionKeyDigest(KEY)).toEqual(KEY_DIGEST);
    const canonicalZero = Buffer.alloc(32).toString("base64url");
    const nonCanonicalAlias = `${canonicalZero.slice(0, -1)}B`;
    for (const invalid of [null, "", "short", `${KEY}=`, nonCanonicalAlias]) {
      expect(() => accountDeletionKeyDigest(invalid)).toThrow(AccountDeletionIdempotencyKeyError);
    }
  });

  it("returns a durable replay before parsing a now-invalid session", async () => {
    const result = await deleteBearerAccount(null, KEY_DIGEST, false);

    expect(result).toEqual({ replayed: true });
    expect(mocks.readBearerToken).not.toHaveBeenCalled();
    expect(mocks.connect).not.toHaveBeenCalled();
    expect(mocks.poolQuery).toHaveBeenCalledWith(
      expect.stringContaining("account_deletion_receipts"),
      [KEY_DIGEST]
    );
  });

  it("requires confirmation for a first call before parsing authentication", async () => {
    mocks.poolQuery.mockResolvedValueOnce({ rowCount: 0, rows: [] });
    await expect(deleteBearerAccount("Bearer secret", KEY_DIGEST, false))
      .rejects.toBeInstanceOf(AccountDeletionConfirmationError);
    expect(mocks.readBearerToken).not.toHaveBeenCalled();
    expect(mocks.connect).not.toHaveBeenCalled();
  });

  it("records the receipt and account deletion in one transaction", async () => {
    mocks.poolQuery.mockResolvedValueOnce({ rowCount: 0, rows: [] });

    await expect(deleteBearerAccount("Bearer token", KEY_DIGEST, true))
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
  });

  it("turns a concurrent unique-key winner into a successful replay", async () => {
    mocks.poolQuery.mockResolvedValueOnce({ rowCount: 0, rows: [] });
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (sql.includes("INSERT INTO account_deletion_receipts")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    await expect(deleteBearerAccount("Bearer token", KEY_DIGEST, true))
      .resolves.toEqual({ replayed: true });
    expect(mocks.clientQuery).not.toHaveBeenCalledWith(
      expect.stringContaining("FOR UPDATE OF account"),
      expect.anything()
    );
    expect(mocks.clientQuery).toHaveBeenCalledWith("COMMIT");
  });

  it("requires recent passkey authentication for a first deletion", async () => {
    mocks.poolQuery.mockResolvedValueOnce({ rowCount: 0, rows: [] });
    mocks.readBearerToken.mockReturnValueOnce({
      userId: USER_ID,
      sessionId: SESSION_ID,
      issuedAt: Date.now() - 5 * 60_000 - 1,
      expiresAt: Date.now() + 60_000
    });
    await expect(deleteBearerAccount("Bearer old-token", KEY_DIGEST, true))
      .rejects.toBeInstanceOf(TokenValidationError);
    expect(mocks.ensureSyncSchema).toHaveBeenCalledOnce();
    expect(mocks.connect).not.toHaveBeenCalled();
  });

  it("rolls back the provisional receipt and destroys an ambiguous client", async () => {
    mocks.poolQuery.mockResolvedValueOnce({ rowCount: 0, rows: [] });
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (sql.includes("FOR UPDATE OF account")) return { rowCount: 0, rows: [] };
      if (sql === "ROLLBACK") throw new Error("rollback timed out");
      return { rowCount: 1, rows: [] };
    });

    await expect(deleteBearerAccount("Bearer token", KEY_DIGEST, true))
      .rejects.toBeInstanceOf(TokenValidationError);
    expect(mocks.release).toHaveBeenCalledWith(true);
  });
});
