import { randomBytes, randomUUID } from "node:crypto";
import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse
} from "@simplewebauthn/server";
import { base64urlDecode, base64urlEncode } from "./base64url";
import { ensureSyncSchema, getSyncPool } from "./postgres";
import { ChallengeToken, issueChallengeToken, issueSessionToken, readChallengeToken } from "./tokens";

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

function rpID() {
  return process.env.PASSKEY_RP_ID || "localhost";
}

function rpName() {
  return process.env.PASSKEY_RP_NAME || "Address Atlas";
}

function expectedOrigin() {
  return process.env.PASSKEY_ORIGIN || "http://localhost:3000";
}

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
  if (input.mode === "register") {
    const pendingUserId = randomUUID();
    const challenge = base64urlEncode(randomBytes(32));
    const publicKey = await generateRegistrationOptions({
      rpName: rpName(),
      rpID: rpID(),
      userName: input.accountName || `address-atlas-${pendingUserId}`,
      userID: base64urlDecode(base64urlEncode(pendingUserId)),
      challenge,
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
        challenge,
        pendingUserId,
        expiresAt: Date.now() + 1000 * 60 * 5
      }),
      publicKey
    };
  }

  if (input.mode === "authenticate") {
    const challenge = base64urlEncode(randomBytes(32));
    const publicKey = await generateAuthenticationOptions({
      rpID: rpID(),
      challenge,
      userVerification: "required"
    });
    return {
      mode: "authenticate",
      challengeToken: issueChallengeToken({
        mode: "authenticate",
        challenge,
        expiresAt: Date.now() + 1000 * 60 * 5
      }),
      publicKey
    };
  }
}

export async function verifyPasskey(body: unknown) {
  const input = parsePasskeyVerifyInput(body);
  const challenge = readChallengeToken(input.challengeToken);
  if (input.mode !== challenge.mode) {
    throw new PasskeyVerificationError();
  }
  await ensureSyncSchema();
  void pruneConsumedChallenges();

  // The challenge is consumed AFTER the WebAuthn assertion is verified (inside
  // verifyRegistration/verifyAuthentication), so a malformed or forged response
  // can no longer burn a legitimate single-use challenge.
  if (challenge.mode === "register") {
    return verifyRegistration(challenge, input.response as RegistrationResponseJSON);
  }
  return verifyAuthentication(challenge, input.response as AuthenticationResponseJSON);
}

// Challenge tokens live 5 minutes; rows older than that are dead weight. Best
// effort — never block or fail a verification on cleanup.
async function pruneConsumedChallenges() {
  try {
    await getSyncPool().query(
      "DELETE FROM consumed_challenges WHERE consumed_at < now() - interval '15 minutes'"
    );
  } catch {
    // Ignore: pruning is opportunistic.
  }
}

async function verifyRegistration(challenge: ChallengeToken, response: RegistrationResponseJSON) {
  if (!challenge.pendingUserId) throw new PasskeyVerificationError();
  let verification: Awaited<ReturnType<typeof verifyRegistrationResponse>>;
  try {
    verification = await verifyRegistrationResponse({
      response,
      expectedChallenge: challenge.challenge,
      expectedOrigin: expectedOrigin(),
      expectedRPID: rpID(),
      requireUserVerification: true
    });
  } catch {
    throw new PasskeyVerificationError();
  }
  if (!verification.verified) throw new PasskeyVerificationError();

  const credential = verification.registrationInfo.credential;
  const client = await getSyncPool().connect();
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
    if (Number(accountCount.rows[0]?.count ?? 0) >= maxAccounts()) {
      throw new PasskeyVerificationError();
    }

    await client.query("INSERT INTO users (id) VALUES ($1) ON CONFLICT (id) DO NOTHING", [challenge.pendingUserId]);
    // A credential ID is globally unique at the RP. Never mutate or reuse an
    // existing row: an authenticator-controlled duplicate ID must not become a
    // bridge into the credential's original account.
    const credentialResult = await client.query(
      `INSERT INTO passkey_credentials (id, user_id, public_key_base64url, counter, transports)
       VALUES ($1, $2, $3, $4, $5::jsonb)
       ON CONFLICT (id) DO NOTHING
       RETURNING id`,
      [
        credential.id,
        challenge.pendingUserId,
        base64urlEncode(credential.publicKey),
        credential.counter,
        JSON.stringify(response.response.transports ?? [])
      ]
    );
    if (credentialResult.rowCount === 0) {
      throw new PasskeyVerificationError();
    }
    await client.query("COMMIT");
  } catch (error) {
    await rollbackQuietly(client);
    throw error;
  } finally {
    client.release();
  }

  return {
    verified: true,
    userId: challenge.pendingUserId,
    sessionToken: issueSessionToken(challenge.pendingUserId)
  };
}

async function verifyAuthentication(challenge: ChallengeToken, response: AuthenticationResponseJSON) {
  const client = await getSyncPool().connect();
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
      transports: string[];
    }>(
      `SELECT id, user_id, public_key_base64url, counter, transports
       FROM passkey_credentials WHERE id = $1 FOR UPDATE`,
      [response.id]
    );
    const row = credentialRow.rows[0];
    if (!row) throw new PasskeyVerificationError();

    const credential: WebAuthnCredential = {
      id: row.id,
      publicKey: base64urlDecode(row.public_key_base64url),
      counter: Number(row.counter),
      transports: row.transports as WebAuthnCredential["transports"]
    };
    let verification: Awaited<ReturnType<typeof verifyAuthenticationResponse>>;
    try {
      verification = await verifyAuthenticationResponse({
        response,
        expectedChallenge: challenge.challenge,
        expectedOrigin: expectedOrigin(),
        expectedRPID: rpID(),
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
    await client.query("COMMIT");

    return {
      verified: true,
      userId: row.user_id,
      sessionToken: issueSessionToken(row.user_id)
    };
  } catch (error) {
    await rollbackQuietly(client);
    throw error;
  } finally {
    client.release();
  }
}

function maxAccounts() {
  const parsed = Number(process.env.SYNC_MAX_ACCOUNTS ?? 100_000);
  return Number.isSafeInteger(parsed) && parsed >= 1 && parsed <= 10_000_000 ? parsed : 100_000;
}

async function rollbackQuietly(client: { query: (sql: string) => Promise<unknown> }) {
  try {
    await client.query("ROLLBACK");
  } catch {
    // Preserve the authentication/database error that caused the rollback.
  }
}
