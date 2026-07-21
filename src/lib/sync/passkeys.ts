import { randomBytes, randomUUID } from "node:crypto";
import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse
} from "@simplewebauthn/server";
import { base64urlDecode, base64urlEncode } from "./base64url";
import { getSyncLimitConfig, getSyncPasskeyConfig, type SyncPasskeyConfig } from "./config";
import { ensureSyncSchema, getSyncPool } from "./postgres";
import { assertRegistrationEnabled, reserveRegistrationAdmission } from "./registration";
import { createSessionGrant } from "./sessions";
import { ChallengeToken, issueChallengeToken, readChallengeToken } from "./tokens";

type RegistrationResponseJSON = Parameters<typeof verifyRegistrationResponse>[0]["response"];
type AuthenticationResponseJSON = Parameters<typeof verifyAuthenticationResponse>[0]["response"];
type WebAuthnCredential = Parameters<typeof verifyAuthenticationResponse>[0]["credential"];
export type PasskeyMode = "register" | "authenticate";

export class PasskeyInputError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PasskeyInputError";
  }
}

export class PasskeyVerificationError extends Error {
  constructor() {
    super("Passkey verification failed.");
    this.name = "PasskeyVerificationError";
  }
}

export interface PasskeyOptionsInput {
  mode: PasskeyMode;
  accountName?: string;
}

export interface PasskeyVerifyInput {
  mode: PasskeyMode;
  challengeToken: string;
  response: RegistrationResponseJSON | AuthenticationResponseJSON;
}

const MAX_ACCOUNT_NAME_LENGTH = 80;
const MAX_CHALLENGE_TOKEN_LENGTH = 4_096;
const CONSUMED_CHALLENGE_PRUNE_INTERVAL_MS = 60_000;

let consumedChallengePruneInFlight: Promise<void> | null = null;
let lastConsumedChallengePruneStartedAt = 0;

export function parsePasskeyOptionsInput(body: unknown): PasskeyOptionsInput {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new PasskeyInputError("A JSON request body is required.");
  }
  const input = body as { mode?: unknown; accountName?: unknown };
  if (input.mode !== "register" && input.mode !== "authenticate") {
    throw new PasskeyInputError("mode must be register or authenticate.");
  }
  if (input.accountName !== undefined && typeof input.accountName !== "string") {
    throw new PasskeyInputError("accountName must be a string.");
  }
  const accountName = typeof input.accountName === "string" ? input.accountName.trim() : undefined;
  if (accountName && (accountName.length > MAX_ACCOUNT_NAME_LENGTH || /[\u0000-\u001f\u007f]/.test(accountName))) {
    throw new PasskeyInputError(`accountName must be at most ${MAX_ACCOUNT_NAME_LENGTH} characters and contain no control characters.`);
  }
  if (input.mode === "authenticate" && accountName) {
    throw new PasskeyInputError("accountName is only accepted when registering.");
  }
  return { mode: input.mode, accountName: accountName || undefined };
}

export function parsePasskeyVerifyInput(body: unknown): PasskeyVerifyInput {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new PasskeyInputError("A JSON request body is required.");
  }
  const input = body as { mode?: unknown; challengeToken?: unknown; response?: unknown };
  if (input.mode !== "register" && input.mode !== "authenticate") {
    throw new PasskeyInputError("mode must be register or authenticate.");
  }
  if (
    typeof input.challengeToken !== "string"
    || input.challengeToken.length < 1
    || input.challengeToken.length > MAX_CHALLENGE_TOKEN_LENGTH
  ) {
    throw new PasskeyInputError("A valid challengeToken is required.");
  }
  if (!input.response || typeof input.response !== "object" || Array.isArray(input.response)) {
    throw new PasskeyInputError("A passkey response is required.");
  }
  return {
    mode: input.mode,
    challengeToken: input.challengeToken,
    response: input.response as RegistrationResponseJSON | AuthenticationResponseJSON
  };
}

export async function createPasskeyOptions(body: unknown) {
  const input = parsePasskeyOptionsInput(body);
  const config = getSyncPasskeyConfig();
  // SimpleWebAuthn treats string challenges as UTF-8 input and encodes them
  // again. Pass raw entropy and bind the token to its exact browser output.
  if (input.mode === "register") {
    assertRegistrationEnabled();
    const pendingUserId = randomUUID();
    const publicKey = await generateRegistrationOptions({
      rpName: config.rpName,
      rpID: config.rpID,
      userName: input.accountName || `address-atlas-${pendingUserId}`,
      userID: base64urlDecode(base64urlEncode(pendingUserId)),
      challenge: randomBytes(32),
      attestationType: "none",
      authenticatorSelection: {
        residentKey: "required",
        userVerification: "required"
      }
    });
    return {
      mode: "register",
      challengeToken: issueChallengeToken({
        mode: "register",
        challenge: publicKey.challenge,
        pendingUserId,
        expiresAt: Date.now() + 1000 * 60 * 5
      }),
      publicKey
    };
  }

  if (input.mode === "authenticate") {
    const publicKey = await generateAuthenticationOptions({
      rpID: config.rpID,
      challenge: randomBytes(32),
      userVerification: "required"
    });
    return {
      mode: "authenticate",
      challengeToken: issueChallengeToken({
        mode: "authenticate",
        challenge: publicKey.challenge,
        expiresAt: Date.now() + 1000 * 60 * 5
      }),
      publicKey
    };
  }

  // parsePasskeyOptionsInput only admits the two modes above, so this is
  // unreachable today. It keeps the function exhaustive: without it a future
  // third mode would return undefined and the route would serialize a 200
  // null body instead of the 400 this input error maps to.
  throw new PasskeyInputError("mode must be register or authenticate.");
}

export async function verifyPasskey(body: unknown) {
  const input = parsePasskeyVerifyInput(body);
  const config = getSyncPasskeyConfig();
  const limits = getSyncLimitConfig();
  const challenge = readChallengeToken(input.challengeToken);
  if (input.mode !== challenge.mode) {
    throw new PasskeyVerificationError();
  }
  await ensureSyncSchema();
  scheduleConsumedChallengePrune();

  // The challenge is consumed AFTER the WebAuthn assertion is verified (inside
  // verifyRegistration/verifyAuthentication), so a malformed or forged response
  // can no longer burn a legitimate single-use challenge.
  if (challenge.mode === "register") {
    // A kill-switch change must also stop already-issued registration options.
    assertRegistrationEnabled();
    return verifyRegistration(
      challenge,
      input.response as RegistrationResponseJSON,
      config,
      limits.maxAccounts
    );
  }
  return verifyAuthentication(challenge, input.response as AuthenticationResponseJSON, config);
}

// Challenge tokens live 5 minutes; rows older than that are dead weight. Keep
// cleanup best-effort and off the authentication critical path, but never start
// an unbounded number of pool waiters when PostgreSQL is slow or unavailable.
function scheduleConsumedChallengePrune() {
  const now = Date.now();
  if (
    consumedChallengePruneInFlight
    || now - lastConsumedChallengePruneStartedAt < CONSUMED_CHALLENGE_PRUNE_INTERVAL_MS
  ) {
    return;
  }

  lastConsumedChallengePruneStartedAt = now;
  const attempt = pruneConsumedChallenges();
  consumedChallengePruneInFlight = attempt;
  void attempt.finally(() => {
    if (consumedChallengePruneInFlight === attempt) {
      consumedChallengePruneInFlight = null;
    }
  });
}

async function pruneConsumedChallenges() {
  try {
    await getSyncPool().query(
      "DELETE FROM consumed_challenges WHERE consumed_at < now() - interval '15 minutes'"
    );
  } catch {
    // Ignore: pruning is opportunistic.
  }
}

export function resetPasskeyMaintenanceForTests() {
  consumedChallengePruneInFlight = null;
  lastConsumedChallengePruneStartedAt = 0;
}

async function verifyRegistration(
  challenge: ChallengeToken,
  response: RegistrationResponseJSON,
  config: SyncPasskeyConfig,
  maxAccounts: number
) {
  if (!challenge.pendingUserId) throw new PasskeyVerificationError();
  let verification: Awaited<ReturnType<typeof verifyRegistrationResponse>>;
  try {
    verification = await verifyRegistrationResponse({
      response,
      expectedChallenge: challenge.challenge,
      expectedOrigin: config.expectedOrigin,
      expectedRPID: config.rpID,
      requireUserVerification: true
    });
  } catch {
    throw new PasskeyVerificationError();
  }
  if (!verification.verified) throw new PasskeyVerificationError();

  const credential = verification.registrationInfo.credential;
  const client = await getSyncPool().connect();
  let discardClient = false;
  let sessionToken: string | undefined;
  try {
    await client.query("BEGIN");
    // Consume inside the transaction so a later failure rolls the challenge back.
    const consumed = await client.query(
      "INSERT INTO consumed_challenges (challenge) VALUES ($1) ON CONFLICT (challenge) DO NOTHING",
      [challenge.challenge]
    );
    if (consumed.rowCount === 0) throw new PasskeyVerificationError();

    // Serialize registrations while enforcing a configurable service-wide
    // account ceiling. This keeps an internet-facing registration endpoint from
    // creating unbounded durable rows even if edge limits are bypassed/restarted.
    await client.query("SELECT pg_advisory_xact_lock(1094992972)");
    const accountCount = await client.query<{ count: string }>("SELECT count(*)::text AS count FROM users");
    if (Number(accountCount.rows[0]?.count ?? 0) >= maxAccounts) {
      throw new PasskeyVerificationError();
    }

    // Reserve durable admission only after WebAuthn succeeds and inside the
    // same transaction as account creation. Forged assertions and abandoned
    // options cannot consume registration capacity, while any later insert
    // failure rolls the reservation back with the account changes.
    await reserveRegistrationAdmission(client);

    await client.query("INSERT INTO users (id) VALUES ($1) ON CONFLICT (id) DO NOTHING", [challenge.pendingUserId]);
    // A credential ID is globally unique at the RP. Never mutate or reuse an
    // existing row: an authenticator-controlled duplicate ID must not become a
    // bridge into the credential's original account.
    const credentialResult = await client.query(
      `INSERT INTO passkey_credentials (id, user_id, public_key_base64url, counter)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (id) DO NOTHING
       RETURNING id`,
      [
        credential.id,
        challenge.pendingUserId,
        base64urlEncode(credential.publicKey),
        credential.counter
      ]
    );
    if (credentialResult.rowCount === 0) {
      throw new PasskeyVerificationError();
    }
    sessionToken = (await createSessionGrant(client, challenge.pendingUserId)).sessionToken;
    await client.query("COMMIT");
  } catch (error) {
    discardClient = !(await rollbackQuietly(client));
    throw error;
  } finally {
    if (discardClient) client.release(true);
    else client.release();
  }

  return {
    verified: true,
    userId: challenge.pendingUserId,
    sessionToken: sessionToken!
  };
}

async function verifyAuthentication(
  challenge: ChallengeToken,
  response: AuthenticationResponseJSON,
  config: SyncPasskeyConfig
) {
  const client = await getSyncPool().connect();
  let discardClient = false;
  try {
    await client.query("BEGIN");
    // Lock before verification so concurrent assertions cannot both validate
    // against the same counter. The monotonic UPDATE is a second line of defense
    // for authenticators that always report counter zero.
    const credentialRow = await client.query<{
      id: string;
      user_id: string;
      public_key_base64url: string;
      counter: string;
    }>(
      `SELECT id, user_id, public_key_base64url, counter
       FROM passkey_credentials WHERE id = $1 FOR UPDATE`,
      [response.id]
    );
    const row = credentialRow.rows[0];
    if (!row) throw new PasskeyVerificationError();

    const credential: WebAuthnCredential = {
      id: row.id,
      publicKey: base64urlDecode(row.public_key_base64url),
      counter: Number(row.counter)
    };
    let verification: Awaited<ReturnType<typeof verifyAuthenticationResponse>>;
    try {
      verification = await verifyAuthenticationResponse({
        response,
        expectedChallenge: challenge.challenge,
        expectedOrigin: config.expectedOrigin,
        expectedRPID: config.rpID,
        credential,
        requireUserVerification: true
      });
    } catch {
      throw new PasskeyVerificationError();
    }
    if (!verification.verified) throw new PasskeyVerificationError();

    const consumed = await client.query(
      "INSERT INTO consumed_challenges (challenge) VALUES ($1) ON CONFLICT (challenge) DO NOTHING",
      [challenge.challenge]
    );
    if (consumed.rowCount === 0) throw new PasskeyVerificationError();
    await client.query(
      `UPDATE passkey_credentials
       SET counter = GREATEST(counter, $2), updated_at = now()
       WHERE id = $1`,
      [row.id, verification.authenticationInfo.newCounter]
    );
    const sessionToken = (await createSessionGrant(client, row.user_id)).sessionToken;
    await client.query("COMMIT");

    return {
      verified: true,
      userId: row.user_id,
      sessionToken
    };
  } catch (error) {
    discardClient = !(await rollbackQuietly(client));
    throw error;
  } finally {
    if (discardClient) client.release(true);
    else client.release();
  }
}

async function rollbackQuietly(client: { query: (sql: string) => Promise<unknown> }) {
  try {
    await client.query("ROLLBACK");
    return true;
  } catch {
    // A timed-out statement may still be executing in Postgres. The caller
    // discards this client rather than exposing an ambiguous transaction state.
    return false;
  }
}
