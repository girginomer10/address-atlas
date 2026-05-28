import { randomBytes, randomUUID } from "node:crypto";
import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse
} from "@simplewebauthn/server";
import { base64urlDecode, base64urlEncode } from "./base64url";
import { ensureSyncSchema, getSyncPool } from "./postgres";
import { ChallengeToken, issueSessionToken, signToken, verifyToken } from "./tokens";

type RegistrationResponseJSON = Parameters<typeof verifyRegistrationResponse>[0]["response"];
type AuthenticationResponseJSON = Parameters<typeof verifyAuthenticationResponse>[0]["response"];
type WebAuthnCredential = Parameters<typeof verifyAuthenticationResponse>[0]["credential"];

function rpID() {
  return process.env.PASSKEY_RP_ID || "localhost";
}

function rpName() {
  return process.env.PASSKEY_RP_NAME || "Address Atlas";
}

function expectedOrigin() {
  return process.env.PASSKEY_ORIGIN || "http://localhost:3000";
}

export async function createPasskeyOptions(body: unknown) {
  const input = body as { mode?: string; accountName?: string };
  if (input.mode === "register") {
    const pendingUserId = randomUUID();
    const challenge = base64urlEncode(randomBytes(32));
    const publicKey = await generateRegistrationOptions({
      rpName: rpName(),
      rpID: rpID(),
      userName: input.accountName?.trim() || `address-atlas-${pendingUserId}`,
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
      challengeToken: signToken<ChallengeToken>({
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
      challengeToken: signToken<ChallengeToken>({
        mode: "authenticate",
        challenge,
        expiresAt: Date.now() + 1000 * 60 * 5
      }),
      publicKey
    };
  }

  throw new Error("mode must be register or authenticate.");
}

export async function verifyPasskey(body: unknown) {
  const input = body as {
    mode?: string;
    challengeToken?: string;
    response?: RegistrationResponseJSON | AuthenticationResponseJSON;
  };
  if (!input.challengeToken || !input.response) {
    throw new Error("challengeToken and response are required.");
  }
  const challenge = verifyToken<ChallengeToken>(input.challengeToken);
  if (input.mode !== challenge.mode) {
    throw new Error("Challenge mode mismatch.");
  }
  await ensureSyncSchema();
  await consumeChallenge(challenge.challenge);

  if (challenge.mode === "register") {
    return verifyRegistration(challenge, input.response as RegistrationResponseJSON);
  }
  return verifyAuthentication(challenge, input.response as AuthenticationResponseJSON);
}

async function consumeChallenge(challenge: string) {
  const result = await getSyncPool().query(
    "INSERT INTO consumed_challenges (challenge) VALUES ($1) ON CONFLICT (challenge) DO NOTHING",
    [challenge]
  );
  if (result.rowCount === 0) {
    throw new Error("Challenge has already been used.");
  }
}

async function verifyRegistration(challenge: ChallengeToken, response: RegistrationResponseJSON) {
  if (!challenge.pendingUserId) throw new Error("Registration challenge missing pending user id.");
  const verification = await verifyRegistrationResponse({
    response,
    expectedChallenge: challenge.challenge,
    expectedOrigin: expectedOrigin(),
    expectedRPID: rpID(),
    requireUserVerification: true
  });
  if (!verification.verified) throw new Error("Passkey registration failed.");

  const credential = verification.registrationInfo.credential;
  const client = await getSyncPool().connect();
  try {
    await client.query("BEGIN");
    await client.query("INSERT INTO users (id) VALUES ($1) ON CONFLICT (id) DO NOTHING", [challenge.pendingUserId]);
    await client.query(
      `INSERT INTO passkey_credentials (id, user_id, public_key_base64url, counter, transports)
       VALUES ($1, $2, $3, $4, $5::jsonb)
       ON CONFLICT (id) DO UPDATE SET updated_at = now()`,
      [
        credential.id,
        challenge.pendingUserId,
        base64urlEncode(credential.publicKey),
        credential.counter,
        JSON.stringify(response.response.transports ?? [])
      ]
    );
    await client.query("COMMIT");
  } catch (error) {
    await client.query("ROLLBACK");
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
  const credentialRow = await getSyncPool().query<{
    id: string;
    user_id: string;
    public_key_base64url: string;
    counter: string;
    transports: string[];
  }>(
    "SELECT id, user_id, public_key_base64url, counter, transports FROM passkey_credentials WHERE id = $1",
    [response.id]
  );
  const row = credentialRow.rows[0];
  if (!row) throw new Error("Unknown passkey credential.");

  const credential: WebAuthnCredential = {
    id: row.id,
    publicKey: base64urlDecode(row.public_key_base64url),
    counter: Number(row.counter),
    transports: row.transports as WebAuthnCredential["transports"]
  };
  const verification = await verifyAuthenticationResponse({
    response,
    expectedChallenge: challenge.challenge,
    expectedOrigin: expectedOrigin(),
    expectedRPID: rpID(),
    credential,
    requireUserVerification: true
  });
  if (!verification.verified) throw new Error("Passkey authentication failed.");
  await getSyncPool().query(
    "UPDATE passkey_credentials SET counter = $2, updated_at = now() WHERE id = $1",
    [row.id, verification.authenticationInfo.newCounter]
  );

  return {
    verified: true,
    userId: row.user_id,
    sessionToken: issueSessionToken(row.user_id)
  };
}
