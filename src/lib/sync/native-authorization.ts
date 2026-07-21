import { createHash, timingSafeEqual } from "node:crypto";
import type { PoolClient } from "pg";
import { lockAccountForAuthentication } from "./authentication-lock-order";
import { base64urlDecode } from "./base64url";
import { ensureSyncSchema, getSyncPool } from "./postgres";
import {
  isCanonical32ByteBase64url,
  issueSessionToken,
  readNativeAuthorizationCode,
  type NativeAuthorizationCode,
  TokenValidationError
} from "./tokens";

const MAX_AUTHORIZATION_CODE_LENGTH = 4_096;
const AUTHORIZATION_CODE_RE = /^[A-Za-z0-9._-]+$/;

export class NativeAuthorizationExchangeError extends Error {
  constructor() {
    super("Native authorization exchange failed.");
    this.name = "NativeAuthorizationExchangeError";
  }
}

export interface NativeAuthorizationExchangeInput {
  authorizationCode: string;
  codeVerifier: string;
}

export function parseNativeAuthorizationExchangeInput(
  body: unknown
): NativeAuthorizationExchangeInput {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new NativeAuthorizationExchangeError();
  }
  const keys = Object.keys(body);
  if (
    keys.length !== 2
    || !keys.includes("authorizationCode")
    || !keys.includes("codeVerifier")
  ) {
    throw new NativeAuthorizationExchangeError();
  }
  const input = body as { authorizationCode?: unknown; codeVerifier?: unknown };
  if (
    typeof input.authorizationCode !== "string"
    || input.authorizationCode.length < 1
    || input.authorizationCode.length > MAX_AUTHORIZATION_CODE_LENGTH
    || !AUTHORIZATION_CODE_RE.test(input.authorizationCode)
    || !isCanonical32ByteBase64url(input.codeVerifier)
  ) {
    throw new NativeAuthorizationExchangeError();
  }
  return {
    authorizationCode: input.authorizationCode,
    codeVerifier: input.codeVerifier
  };
}

export async function exchangeNativeAuthorization(body: unknown) {
  const input = parseNativeAuthorizationExchangeInput(body);
  let authorization: NativeAuthorizationCode;
  try {
    authorization = readNativeAuthorizationCode(input.authorizationCode);
  } catch (error) {
    if (error instanceof TokenValidationError) throw new NativeAuthorizationExchangeError();
    throw error;
  }

  const verifierDigest = createHash("sha256")
    .update(input.codeVerifier, "ascii")
    .digest();
  const expectedChallenge = base64urlDecode(authorization.codeChallenge);
  if (
    verifierDigest.byteLength !== expectedChallenge.byteLength
    || !timingSafeEqual(verifierDigest, expectedChallenge)
  ) {
    throw new NativeAuthorizationExchangeError();
  }

  await ensureSyncSchema();
  const client = await getSyncPool().connect();
  let transactionOpen = false;
  let discardClient = false;
  try {
    transactionOpen = true;
    await client.query("BEGIN");
    const consumed = await client.query(
      `INSERT INTO consumed_challenges (challenge)
       VALUES ($1)
       ON CONFLICT (challenge) DO NOTHING
       RETURNING challenge`,
      [nativeAuthorizationConsumptionKey(input.authorizationCode)]
    );
    if (consumed.rowCount !== 1) throw new NativeAuthorizationExchangeError();

    // Use the same parent-first order as passkey authentication and account
    // deletion. A joined locking clause does not guarantee relation lock order.
    if (!(await lockAccountForAuthentication(client, authorization.userId))) {
      throw new NativeAuthorizationExchangeError();
    }
    const active = await client.query(
      `SELECT grant_row.id
       FROM session_grants AS grant_row
       WHERE grant_row.id = $1
         AND grant_row.user_id = $2
         AND grant_row.expires_at > now()
         AND to_timestamp($3::double precision / 1000.0) > now()
       FOR SHARE OF grant_row`,
      [authorization.sessionId, authorization.userId, authorization.expiresAt]
    );
    if (active.rowCount !== 1) throw new NativeAuthorizationExchangeError();

    const sessionToken = issueSessionToken(
      authorization.userId,
      authorization.sessionId,
      authorization.issuedAt
    );
    await client.query("COMMIT");
    transactionOpen = false;
    return { userId: authorization.userId, sessionToken };
  } catch (error) {
    if (transactionOpen) discardClient = !(await rollbackQuietly(client));
    if (error instanceof NativeAuthorizationExchangeError) throw error;
    throw error;
  } finally {
    if (discardClient) client.release(true);
    else client.release();
  }
}

export function nativeAuthorizationConsumptionKey(authorizationCode: string) {
  return `native-code:${createHash("sha256").update(authorizationCode, "utf8").digest("base64url")}`;
}

async function rollbackQuietly(client: Pick<PoolClient, "query">) {
  try {
    await client.query("ROLLBACK");
    return true;
  } catch {
    return false;
  }
}
