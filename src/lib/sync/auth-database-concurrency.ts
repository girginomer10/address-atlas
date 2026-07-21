import {
  acquireConcurrencyMany,
  normalizeRequestClientKey,
  type ConcurrencyLimitRule,
  type RequestClientKey
} from "./rate-limit";

const AUTHENTICATION_DATABASE_ACTIVE_KEY = "auth-database-active:global";
// Two preserves the product's legitimate parallel read/write and idempotent
// deletion retry paths while rejecting a third same-client/session lookup.
const CLIENT_ACTIVE_BEARER_LIMIT = 2;
const SESSION_ACTIVE_BEARER_LIMIT = 2;
const CLIENT_ACTIVE_DELETION_REPLAY_LIMIT = 2;

export class AuthenticationDatabaseCapacityError extends Error {
  constructor() {
    super("Authentication database capacity is temporarily exhausted.");
    this.name = "AuthenticationDatabaseCapacityError";
  }
}

/**
 * Atomically reserve public authentication work against at most half of this
 * process's PostgreSQL pool. Every authentication mechanism must use this
 * primitive so separate endpoints cannot each consume an independent budget.
 */
export function acquireAuthenticationDatabaseConcurrency(
  poolSize: number,
  operationRules: ConcurrencyLimitRule[]
) {
  if (!Number.isSafeInteger(poolSize) || poolSize < 2) {
    throw new Error("Authentication requires a database pool with reserved capacity.");
  }
  return acquireConcurrencyMany([
    {
      key: AUTHENTICATION_DATABASE_ACTIVE_KEY,
      limit: Math.floor(poolSize / 2)
    },
    ...operationRules
  ]);
}

/**
 * Bound live bearer-grant checks before PostgreSQL work can queue. The caller
 * must first authenticate the token envelope; otherwise attacker-controlled
 * session identifiers could consume the bounded permit map.
 */
export function acquireBearerSessionDatabaseConcurrency(
  client: RequestClientKey,
  sessionId: string,
  poolSize: number
) {
  const requestClient = normalizeRequestClientKey(client);
  return acquireAuthenticationDatabaseConcurrency(poolSize, [
    {
      key: `auth-bearer-active:client:${requestClient}`,
      limit: CLIENT_ACTIVE_BEARER_LIMIT
    },
    {
      key: `auth-bearer-active:session:${sessionId}`,
      limit: SESSION_ACTIVE_BEARER_LIMIT
    }
  ]);
}

/** Bound public durable-receipt reads that intentionally do not require auth. */
export function acquireAccountDeletionReplayDatabaseConcurrency(
  client: RequestClientKey,
  idempotencyKeyDigestHex: string,
  poolSize: number
) {
  if (!/^[a-f0-9]{64}$/.test(idempotencyKeyDigestHex)) {
    throw new Error("Account deletion replay requires a valid key digest.");
  }
  const requestClient = normalizeRequestClientKey(client);
  return acquireAuthenticationDatabaseConcurrency(poolSize, [
    {
      key: `auth-account-replay-active:client:${requestClient}`,
      limit: CLIENT_ACTIVE_DELETION_REPLAY_LIMIT
    },
    {
      key: `auth-account-replay-active:digest:${idempotencyKeyDigestHex}`,
      limit: 1
    }
  ]);
}
