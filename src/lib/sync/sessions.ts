import { createHash, randomUUID } from "node:crypto";
import type { PoolClient } from "pg";
import {
  acquireAccountDeletionReplayDatabaseConcurrency,
  acquireBearerSessionDatabaseConcurrency,
  AuthenticationDatabaseCapacityError
} from "./auth-database-concurrency";
import { getSyncDatabasePoolSize } from "./config";
import { ensureSyncSchema, getSyncPool } from "./postgres";
import type { RequestClientKey } from "./rate-limit";
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
export async function authenticateBearerSession(
  header: string | null,
  requestClient: RequestClientKey
) {
  // Authenticate the bounded token envelope before it can allocate a permit
  // key or reach PostgreSQL. Only server-issued session IDs enter the limiter.
  const session = readBearerToken(header);
  const releaseDatabase = acquireBearerDatabasePermit(requestClient, session);
  try {
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
  } finally {
    releaseDatabase();
  }
}

export async function revokeBearerSession(
  header: string | null,
  requestClient: RequestClientKey
) {
  const session = readBearerToken(header);
  const releaseDatabase = acquireBearerDatabasePermit(requestClient, session);
  try {
    await ensureSyncSchema();
    const revoked = await getSyncPool().query(
      `DELETE FROM session_grants
       WHERE id = $1 AND user_id = $2 AND expires_at > now()
       RETURNING id`,
      [session.sessionId, session.userId]
    );
    if (revoked.rowCount !== 1) throw new TokenValidationError();
  } finally {
    releaseDatabase();
  }
}

export async function deleteBearerAccount(
  header: string | null,
  idempotencyKeyDigest: Buffer,
  confirmed: boolean,
  requestClient: RequestClientKey
): Promise<AccountDeletionResult> {
  if (!Buffer.isBuffer(idempotencyKeyDigest) || idempotencyKeyDigest.byteLength !== 32) {
    throw new AccountDeletionIdempotencyKeyError();
  }
  if (!confirmed) {
    // A durable replay intentionally remains usable after the account and its
    // session have disappeared. First calls still require explicit consent.
    const releaseReplayDatabase = acquireAccountDeletionReplayDatabasePermit(
      requestClient,
      idempotencyKeyDigest
    );
    try {
      await ensureSyncSchema();
      if (await accountDeletionReceiptExists(idempotencyKeyDigest)) {
        return { replayed: true };
      }
      throw new AccountDeletionConfirmationError();
    } finally {
      releaseReplayDatabase();
    }
  }

  const session = readBearerToken(header);
  // Destructive account deletion requires a recently issued passkey session,
  // limiting the impact of a long-lived token copied from local storage.
  if (Date.now() - session.issuedAt > 5 * 60_000) throw new TokenValidationError();
  let releaseDatabase: (() => void) | undefined = acquireBearerDatabasePermit(
    requestClient,
    session
  );
  try {
    await ensureSyncSchema();
    if (await accountDeletionReceiptExists(idempotencyKeyDigest)) {
      return { replayed: true };
    }

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
        releaseDatabase();
        releaseDatabase = undefined;
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
      // The successful locked lookup is the authorization point for this
      // transaction. Return the scarce auth slot before the account mutation;
      // subsequent work is authenticated account traffic, not a grant lookup.
      releaseDatabase();
      releaseDatabase = undefined;
      const deleted = await client.query("DELETE FROM users WHERE id = $1 RETURNING id", [session.userId]);
      if (deleted.rowCount !== 1) throw new TokenValidationError();
      await client.query("COMMIT");
      transactionOpen = false;
      return { replayed: false };
    } catch (error) {
      // A failed lookup/transaction no longer needs an authentication slot;
      // do not retain it while PostgreSQL rollback recovery runs.
      releaseDatabase?.();
      releaseDatabase = undefined;
      if (transactionOpen) discardClient = !(await rollbackQuietly(client));
      throw error;
    } finally {
      if (discardClient) client.release(true);
      else client.release();
    }
  } finally {
    releaseDatabase?.();
  }
}

function acquireBearerDatabasePermit(
  requestClient: RequestClientKey,
  session: SessionToken
) {
  const permit = acquireBearerSessionDatabaseConcurrency(
    requestClient,
    session.sessionId,
    getSyncDatabasePoolSize()
  );
  if (!permit) throw new AuthenticationDatabaseCapacityError();
  return permit;
}

function acquireAccountDeletionReplayDatabasePermit(
  requestClient: RequestClientKey,
  idempotencyKeyDigest: Buffer
) {
  const permit = acquireAccountDeletionReplayDatabaseConcurrency(
    requestClient,
    idempotencyKeyDigest.toString("hex"),
    getSyncDatabasePoolSize()
  );
  if (!permit) throw new AuthenticationDatabaseCapacityError();
  return permit;
}

async function accountDeletionReceiptExists(idempotencyKeyDigest: Buffer) {
  const receipt = await getSyncPool().query(
    `SELECT 1
     FROM account_deletion_receipts
     WHERE idempotency_key_digest = $1`,
    [idempotencyKeyDigest]
  );
  return receipt.rowCount === 1;
}

async function rollbackQuietly(client: Pick<PoolClient, "query">) {
  try {
    await client.query("ROLLBACK");
    return true;
  } catch {
    return false;
  }
}
