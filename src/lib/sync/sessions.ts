import { createHash, randomUUID } from "node:crypto";
import type { PoolClient } from "pg";
import { ensureSyncSchema, getSyncPool } from "./postgres";
import {
  issueSessionToken,
  readBearerToken,
  SESSION_TTL_MS,
  type SessionToken,
  TokenValidationError
} from "./tokens";

export interface IssuedSession {
  sessionToken: string;
  session: SessionToken;
}

export class AccountDeletionIdempotencyKeyError extends Error {
  constructor() {
    super("A valid account deletion idempotency key is required.");
    this.name = "AccountDeletionIdempotencyKeyError";
  }
}

export class AccountDeletionConfirmationError extends Error {
  constructor() {
    super("Account deletion confirmation is required.");
    this.name = "AccountDeletionConfirmationError";
  }
}

export interface AccountDeletionResult {
  replayed: boolean;
}

/** Parse the wire key once and retain only its irreversible database digest. */
export function accountDeletionKeyDigest(value: string | null) {
  if (!value || !/^[A-Za-z0-9_-]{43}$/.test(value)) {
    throw new AccountDeletionIdempotencyKeyError();
  }
  const decoded = Buffer.from(value, "base64url");
  // Length alone is insufficient: the final base64url character contains two
  // padding bits. Re-encoding rejects non-canonical aliases for the same key.
  if (decoded.byteLength !== 32 || decoded.toString("base64url") !== value) {
    throw new AccountDeletionIdempotencyKeyError();
  }
  return createHash("sha256").update(decoded).digest();
}

export async function createSessionGrant(
  client: Pick<PoolClient, "query">,
  userId: string
): Promise<IssuedSession> {
  const sessionId = randomUUID();
  const issuedAt = Date.now();
  const expiresAt = issuedAt + SESSION_TTL_MS;
  await client.query(
    `WITH pruned AS (
       DELETE FROM session_grants
       WHERE ctid IN (
         SELECT ctid FROM session_grants
         WHERE expires_at <= now()
         ORDER BY expires_at
         FOR UPDATE SKIP LOCKED
         LIMIT 1000
       )
     )
     INSERT INTO session_grants (id, user_id, expires_at)
     VALUES ($1, $2, to_timestamp($3 / 1000.0))`,
    [sessionId, userId, expiresAt]
  );
  return {
    sessionToken: issueSessionToken(userId, sessionId, issuedAt),
    session: { userId, sessionId, issuedAt, expiresAt }
  };
}

/** Validate both the HMAC envelope and its live, non-revoked DB grant. */
export async function authenticateBearerSession(header: string | null) {
  const session = readBearerToken(header);
  await ensureSyncSchema();
  const active = await getSyncPool().query(
    `SELECT 1
     FROM session_grants AS grant_row
     JOIN users AS account ON account.id = grant_row.user_id
     WHERE grant_row.id = $1
       AND grant_row.user_id = $2
       AND grant_row.expires_at > now()`,
    [session.sessionId, session.userId]
  );
  if (active.rowCount !== 1) throw new TokenValidationError();
  return session;
}

export async function revokeBearerSession(header: string | null) {
  const session = readBearerToken(header);
  await ensureSyncSchema();
  const revoked = await getSyncPool().query(
    `DELETE FROM session_grants
     WHERE id = $1 AND user_id = $2 AND expires_at > now()
     RETURNING id`,
    [session.sessionId, session.userId]
  );
  if (revoked.rowCount !== 1) throw new TokenValidationError();
}

export async function deleteBearerAccount(
  header: string | null,
  idempotencyKeyDigest: Buffer,
  confirmed: boolean
): Promise<AccountDeletionResult> {
  if (!Buffer.isBuffer(idempotencyKeyDigest) || idempotencyKeyDigest.byteLength !== 32) {
    throw new AccountDeletionIdempotencyKeyError();
  }
  await ensureSyncSchema();
  const receipt = await getSyncPool().query(
    `SELECT 1
     FROM account_deletion_receipts
     WHERE idempotency_key_digest = $1`,
    [idempotencyKeyDigest]
  );
  if (receipt.rowCount === 1) return { replayed: true };
  if (!confirmed) throw new AccountDeletionConfirmationError();

  const session = readBearerToken(header);
  // Destructive account deletion requires a recently issued passkey session,
  // limiting the impact of a long-lived token copied from local storage.
  if (Date.now() - session.issuedAt > 5 * 60_000) throw new TokenValidationError();
  const client = await getSyncPool().connect();
  let transactionOpen = false;
  let discardClient = false;
  try {
    transactionOpen = true;
    await client.query("BEGIN");
    const claimed = await client.query(
      `INSERT INTO account_deletion_receipts (idempotency_key_digest)
       VALUES ($1)
       ON CONFLICT (idempotency_key_digest) DO NOTHING
       RETURNING idempotency_key_digest`,
      [idempotencyKeyDigest]
    );
    if (claimed.rowCount !== 1) {
      // A concurrent first call committed the same high-entropy receipt while
      // this INSERT waited on the unique index. Its successful outcome is now
      // durable even though the account/session rows have disappeared.
      await client.query("COMMIT");
      transactionOpen = false;
      return { replayed: true };
    }
    const active = await client.query(
      `SELECT account.id
       FROM users AS account
       JOIN session_grants AS grant_row ON grant_row.user_id = account.id
       WHERE account.id = $1
         AND grant_row.id = $2
         AND grant_row.expires_at > now()
       FOR UPDATE OF account`,
      [session.userId, session.sessionId]
    );
    if (active.rowCount !== 1) throw new TokenValidationError();
    const deleted = await client.query("DELETE FROM users WHERE id = $1 RETURNING id", [session.userId]);
    if (deleted.rowCount !== 1) throw new TokenValidationError();
    await client.query("COMMIT");
    transactionOpen = false;
    return { replayed: false };
  } catch (error) {
    if (transactionOpen) discardClient = !(await rollbackQuietly(client));
    throw error;
  } finally {
    if (discardClient) client.release(true);
    else client.release();
  }
}

async function rollbackQuietly(client: Pick<PoolClient, "query">) {
  try {
    await client.query("ROLLBACK");
    return true;
  } catch {
    return false;
  }
}
