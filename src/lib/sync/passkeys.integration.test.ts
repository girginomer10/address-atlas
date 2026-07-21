import { randomUUID } from "node:crypto";
import { NextRequest } from "next/server";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

// The WebAuthn assertion check is the one inherent seam: exercising it for real
// needs an authenticator. Everything else — routes, option generation, tokens,
// rate limits, and Postgres — runs unmocked below.
const mocks = vi.hoisted(() => ({
  verifyRegistrationResponse: vi.fn(),
  verifyAuthenticationResponse: vi.fn()
}));

vi.mock("@simplewebauthn/server", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@simplewebauthn/server")>()),
  verifyRegistrationResponse: mocks.verifyRegistrationResponse,
  verifyAuthenticationResponse: mocks.verifyAuthenticationResponse
}));

import { POST as postPasskeyOptions } from "@/app/auth/passkey/options/route";
import { POST as postPasskeyVerify } from "@/app/auth/passkey/verify/route";
import { base64urlDecode, base64urlEncode } from "./base64url";
import { getSyncPasskeyConfig } from "./config";
import { verifyPasskey } from "./passkeys";
import { closeSyncPoolForTests, ensureSyncSchema, getSyncPool } from "./postgres";
import { resetRateLimitsForTests } from "./rate-limit";
import {
  RegistrationAdmissionQuotaError,
  reserveRegistrationAdmission
} from "./registration";
import { issueChallengeToken, readBearerToken, readChallengeToken } from "./tokens";

const maybeDescribe = process.env.TEST_SYNC_DATABASE_URL ? describe : describe.skip;
const VALID_CREDENTIAL_PUBLIC_KEY = Buffer.from(
  "a50102032620012158206b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2962258204fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
  "hex"
);
const VALID_CREDENTIAL_PUBLIC_KEY_BASE64URL = VALID_CREDENTIAL_PUBLIC_KEY.toString("base64url");

function newCredentialId(prefix: string) {
  return base64urlEncode(`${prefix}:${randomUUID()}`);
}

maybeDescribe("passkey invariants against real Postgres", () => {
  const testUserIds = new Set<string>();
  const testChallenges = new Set<string>();
  let previousDatabaseURL: string | undefined;
  let previousSessionSecret: string | undefined;
  let previousMaxAccounts: string | undefined;
  let previousRegistrationEnabled: string | undefined;
  let previousRegistrationHourlyLimit: string | undefined;

  beforeAll(async () => {
    previousDatabaseURL = process.env.SYNC_DATABASE_URL;
    previousSessionSecret = process.env.SYNC_SESSION_SECRET;
    previousMaxAccounts = process.env.SYNC_MAX_ACCOUNTS;
    previousRegistrationEnabled = process.env.SYNC_REGISTRATION_ENABLED;
    previousRegistrationHourlyLimit = process.env.SYNC_REGISTRATION_HOURLY_LIMIT;
    process.env.SYNC_DATABASE_URL = process.env.TEST_SYNC_DATABASE_URL;
    process.env.SYNC_SESSION_SECRET = "ci-only-public-session-secret-for-integration-tests";
    process.env.SYNC_REGISTRATION_ENABLED = "true";
    await ensureSyncSchema();
  });

  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(async () => {
    resetRateLimitsForTests();
    restoreEnv("SYNC_MAX_ACCOUNTS", previousMaxAccounts);
    restoreEnv("SYNC_REGISTRATION_HOURLY_LIMIT", previousRegistrationHourlyLimit);
    if (testUserIds.size > 0) {
      await getSyncPool().query("DELETE FROM users WHERE id = ANY($1::uuid[])", [[...testUserIds]]);
      testUserIds.clear();
    }
    if (testChallenges.size > 0) {
      await getSyncPool().query("DELETE FROM consumed_challenges WHERE challenge = ANY($1::text[])", [[...testChallenges]]);
      testChallenges.clear();
    }
  });

  afterAll(async () => {
    await closeSyncPoolForTests();
    restoreEnv("SYNC_DATABASE_URL", previousDatabaseURL);
    restoreEnv("SYNC_SESSION_SECRET", previousSessionSecret);
    restoreEnv("SYNC_MAX_ACCOUNTS", previousMaxAccounts);
    restoreEnv("SYNC_REGISTRATION_ENABLED", previousRegistrationEnabled);
    restoreEnv("SYNC_REGISTRATION_HOURLY_LIMIT", previousRegistrationHourlyLimit);
  });

  function challenge(prefix: string) {
    const value = `${prefix}-${randomUUID()}`;
    testChallenges.add(value);
    return value;
  }

  function optionsRequest(body: unknown) {
    return new NextRequest("http://localhost/auth/passkey/options", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body)
    });
  }

  function verifyRequest(body: unknown) {
    return new NextRequest("http://localhost/auth/passkey/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body)
    });
  }

  it("issues real registration options whose challenge token binds the WebAuthn challenge", async () => {
    const config = getSyncPasskeyConfig();
    const admissionBefore = await currentRegistrationAdmissions();

    const response = await postPasskeyOptions(optionsRequest({
      mode: "register",
      accountName: "Integration Mac"
    }));

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = await response.json();
    expect(body.mode).toBe("register");
    expect(body.publicKey.rp).toMatchObject({ id: config.rpID, name: config.rpName });
    expect(body.publicKey.user.name).toBe("Integration Mac");
    expect(body.publicKey.authenticatorSelection).toMatchObject({
      residentKey: "required",
      userVerification: "required"
    });
    expect(body.publicKey.pubKeyCredParams).toEqual([
      { alg: -7, type: "public-key" },
      { alg: -257, type: "public-key" }
    ]);
    // 32 bytes of raw entropy encode to 43 base64url characters.
    expect(body.publicKey.challenge).toMatch(/^[A-Za-z0-9_-]{43}$/);

    const issued = readChallengeToken(body.challengeToken);
    testChallenges.add(issued.challenge);
    expect(issued.mode).toBe("register");
    expect(issued.challenge).toBe(body.publicKey.challenge);
    expect(base64urlDecode(body.publicKey.user.id).toString("utf8")).toBe(issued.pendingUserId);
    expect(await currentRegistrationAdmissions()).toBe(admissionBefore);
  });

  it("issues real authentication options whose challenge token binds the WebAuthn challenge", async () => {
    const config = getSyncPasskeyConfig();

    const response = await postPasskeyOptions(optionsRequest({ mode: "authenticate" }));

    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.mode).toBe("authenticate");
    expect(body.publicKey.rpId).toBe(config.rpID);
    expect(body.publicKey.userVerification).toBe("required");
    expect(body.publicKey.challenge).toMatch(/^[A-Za-z0-9_-]{43}$/);

    const issued = readChallengeToken(body.challengeToken);
    testChallenges.add(issued.challenge);
    expect(issued.mode).toBe("authenticate");
    expect(issued.challenge).toBe(body.publicKey.challenge);
    expect(issued.pendingUserId).toBeUndefined();
  });

  it("registers through the real routes and binds verification to the configured origin and RP ID", async () => {
    const config = getSyncPasskeyConfig();
    const admissionBefore = await currentRegistrationAdmissions();
    const optionsResponse = await postPasskeyOptions(optionsRequest({ mode: "register" }));
    expect(optionsResponse.status).toBe(200);
    const options = await optionsResponse.json();
    const issued = readChallengeToken(options.challengeToken);
    testChallenges.add(issued.challenge);
    testUserIds.add(issued.pendingUserId!);

    const credentialId = newCredentialId("route-registration");
    mocks.verifyRegistrationResponse.mockResolvedValue({
      verified: true,
      registrationInfo: {
        credential: { id: credentialId, publicKey: VALID_CREDENTIAL_PUBLIC_KEY, counter: 0 }
      }
    });

    const verifyResponse = await postPasskeyVerify(verifyRequest({
      mode: "register",
      challengeToken: options.challengeToken,
      response: { id: credentialId }
    }));

    expect(verifyResponse.status).toBe(200);
    const verified = await verifyResponse.json();
    expect(verified).toMatchObject({ verified: true, userId: issued.pendingUserId });
    expect(readBearerToken(`Bearer ${verified.sessionToken}`).userId).toBe(issued.pendingUserId);

    // The untestable authenticator seam must still receive the exact configured
    // origin/RP ID and the challenge from the issued token — nothing else.
    expect(mocks.verifyRegistrationResponse).toHaveBeenCalledOnce();
    expect(mocks.verifyRegistrationResponse).toHaveBeenCalledWith({
      response: { id: credentialId },
      expectedChallenge: issued.challenge,
      expectedOrigin: config.expectedOrigin,
      expectedRPID: config.rpID,
      requireUserVerification: true,
      supportedAlgorithmIDs: [-7, -257]
    });

    const credentials = await getSyncPool().query(
      "SELECT count(*)::int AS count FROM passkey_credentials WHERE id = $1 AND user_id = $2",
      [credentialId, issued.pendingUserId]
    );
    expect(credentials.rows[0]?.count).toBe(1);
    expect(await currentRegistrationAdmissions()).toBe(admissionBefore + 1);
  });

  it("does not consume durable admission for a failed WebAuthn verification", async () => {
    const pendingUserId = randomUUID();
    const challengeValue = challenge("failed-registration");
    const challengeToken = issueChallengeToken({
      mode: "register",
      challenge: challengeValue,
      pendingUserId,
      expiresAt: Date.now() + 60_000
    });
    mocks.verifyRegistrationResponse.mockResolvedValue({ verified: false });
    const admissionBefore = await currentRegistrationAdmissions();

    await expect(verifyPasskey({
      mode: "register",
      challengeToken,
      response: { id: `failed-${randomUUID()}` }
    })).rejects.toThrow(/verification failed/i);

    expect(await currentRegistrationAdmissions()).toBe(admissionBefore);
    const consumed = await getSyncPool().query(
      "SELECT challenge FROM consumed_challenges WHERE challenge = $1",
      [challengeValue]
    );
    expect(consumed.rowCount).toBe(0);
  });

  it("consumes a registration challenge once and rejects its replay", async () => {
    const pendingUserId = randomUUID();
    const credentialId = newCredentialId("registration");
    const challengeValue = challenge("register");
    testUserIds.add(pendingUserId);
    const challengeToken = issueChallengeToken({
      mode: "register",
      challenge: challengeValue,
      pendingUserId,
      expiresAt: Date.now() + 60_000
    });
    mocks.verifyRegistrationResponse.mockResolvedValue({
      verified: true,
      registrationInfo: {
        credential: { id: credentialId, publicKey: VALID_CREDENTIAL_PUBLIC_KEY, counter: 0 }
      }
    });
    const input = {
      mode: "register",
      challengeToken,
      response: { id: credentialId }
    };

    const result = await verifyPasskey(input);
    expect(result).toMatchObject({ verified: true, userId: pendingUserId });
    expect(readBearerToken(`Bearer ${result.sessionToken}`).userId).toBe(pendingUserId);
    await expect(verifyPasskey(input)).rejects.toThrow(/verification failed/i);

    const consumed = await getSyncPool().query(
      "SELECT count(*)::int AS count FROM consumed_challenges WHERE challenge = $1",
      [challengeValue]
    );
    const credentials = await getSyncPool().query(
      "SELECT count(*)::int AS count FROM passkey_credentials WHERE id = $1 AND user_id = $2",
      [credentialId, pendingUserId]
    );
    expect(consumed.rows[0]?.count).toBe(1);
    expect(credentials.rows[0]?.count).toBe(1);
  });

  it("rolls back challenge consumption when the real account ceiling query rejects registration", async () => {
    process.env.SYNC_MAX_ACCOUNTS = "1";
    const existingUserId = randomUUID();
    const pendingUserId = randomUUID();
    const credentialId = newCredentialId("ceiling");
    const challengeValue = challenge("ceiling");
    testUserIds.add(existingUserId);
    testUserIds.add(pendingUserId);
    await getSyncPool().query("INSERT INTO users (id) VALUES ($1)", [existingUserId]);
    const challengeToken = issueChallengeToken({
      mode: "register",
      challenge: challengeValue,
      pendingUserId,
      expiresAt: Date.now() + 60_000
    });
    mocks.verifyRegistrationResponse.mockResolvedValue({
      verified: true,
      registrationInfo: {
        credential: { id: credentialId, publicKey: VALID_CREDENTIAL_PUBLIC_KEY, counter: 0 }
      }
    });

    await expect(verifyPasskey({
      mode: "register",
      challengeToken,
      response: { id: credentialId }
    })).rejects.toThrow(/verification failed/i);

    const pendingUser = await getSyncPool().query("SELECT id FROM users WHERE id = $1", [pendingUserId]);
    const consumed = await getSyncPool().query(
      "SELECT challenge FROM consumed_challenges WHERE challenge = $1",
      [challengeValue]
    );
    expect(pendingUser.rowCount).toBe(0);
    expect(consumed.rowCount).toBe(0);
  });

  it("updates a credential once and rejects an authentication challenge replay", async () => {
    const config = getSyncPasskeyConfig();
    const userId = randomUUID();
    const credentialId = newCredentialId("authentication");
    const challengeValue = challenge("authenticate");
    testUserIds.add(userId);
    await getSyncPool().query("INSERT INTO users (id) VALUES ($1)", [userId]);
    await getSyncPool().query(
      `INSERT INTO passkey_credentials (id, user_id, public_key_base64url, counter)
       VALUES ($1, $2, $3, $4)`,
      [credentialId, userId, VALID_CREDENTIAL_PUBLIC_KEY_BASE64URL, 8]
    );
    const challengeToken = issueChallengeToken({
      mode: "authenticate",
      challenge: challengeValue,
      expiresAt: Date.now() + 60_000
    });
    mocks.verifyAuthenticationResponse.mockResolvedValue({
      verified: true,
      authenticationInfo: { newCounter: 9 }
    });
    const input = {
      mode: "authenticate",
      challengeToken,
      response: { id: credentialId }
    };

    const result = await verifyPasskey(input);
    expect(result).toMatchObject({ verified: true, userId });
    expect(readBearerToken(`Bearer ${result.sessionToken}`).userId).toBe(userId);
    await expect(verifyPasskey(input)).rejects.toThrow(/verification failed/i);

    expect(mocks.verifyAuthenticationResponse).toHaveBeenCalledWith(
      expect.objectContaining({
        expectedChallenge: challengeValue,
        expectedOrigin: config.expectedOrigin,
        expectedRPID: config.rpID,
        requireUserVerification: true
      })
    );

    const stored = await getSyncPool().query(
      "SELECT counter FROM passkey_credentials WHERE id = $1",
      [credentialId]
    );
    const consumed = await getSyncPool().query(
      "SELECT count(*)::int AS count FROM consumed_challenges WHERE challenge = $1",
      [challengeValue]
    );
    expect(Number(stored.rows[0]?.counter)).toBe(9);
    expect(consumed.rows[0]?.count).toBe(1);
  });

  it("allows exactly one concurrent consumer of a real registration challenge", async () => {
    const pendingUserId = randomUUID();
    const credentialId = newCredentialId("concurrent-registration");
    const challengeValue = challenge("concurrent-registration");
    testUserIds.add(pendingUserId);
    const challengeToken = issueChallengeToken({
      mode: "register",
      challenge: challengeValue,
      pendingUserId,
      expiresAt: Date.now() + 60_000
    });
    mocks.verifyRegistrationResponse.mockResolvedValue({
      verified: true,
      registrationInfo: {
        credential: { id: credentialId, publicKey: VALID_CREDENTIAL_PUBLIC_KEY, counter: 0 }
      }
    });
    const input = {
      mode: "register",
      challengeToken,
      response: { id: credentialId }
    };

    const results = await Promise.allSettled([verifyPasskey(input), verifyPasskey(input)]);
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(results.filter((result) => result.status === "rejected")).toHaveLength(1);
    const consumed = await getSyncPool().query(
      "SELECT count(*)::int AS count FROM consumed_challenges WHERE challenge = $1",
      [challengeValue]
    );
    const credentials = await getSyncPool().query(
      "SELECT count(*)::int AS count FROM passkey_credentials WHERE id = $1",
      [credentialId]
    );
    expect(consumed.rows[0]?.count).toBe(1);
    expect(credentials.rows[0]?.count).toBe(1);
  });

  it("serializes concurrent registrations at the real account-cap boundary", async () => {
    const base = await getSyncPool().query<{ count: string }>("SELECT count(*)::text AS count FROM users");
    process.env.SYNC_MAX_ACCOUNTS = String(Number(base.rows[0]?.count ?? 0) + 1);

    const attempts = [0, 1].map((index) => {
      const pendingUserId = randomUUID();
      const challengeValue = challenge(`account-cap-${index}`);
      const attemptCredentialId = newCredentialId(`account-cap-${index}`);
      testUserIds.add(pendingUserId);
      return {
        pendingUserId,
        challengeValue,
        credentialId: attemptCredentialId,
        input: {
          mode: "register",
          challengeToken: issueChallengeToken({
            mode: "register",
            challenge: challengeValue,
            pendingUserId,
            expiresAt: Date.now() + 60_000
          }),
          response: { id: attemptCredentialId }
        }
      };
    });
    mocks.verifyRegistrationResponse.mockImplementation(async ({ response }) => ({
      verified: true,
      registrationInfo: {
        credential: {
          id: response.id,
          publicKey: VALID_CREDENTIAL_PUBLIC_KEY,
          counter: 0
        }
      }
    }));

    const results = await Promise.allSettled(attempts.map(({ input }) => verifyPasskey(input)));
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(results.filter((result) => result.status === "rejected")).toHaveLength(1);
    const persisted = await getSyncPool().query(
      "SELECT count(*)::int AS count FROM users WHERE id = ANY($1::uuid[])",
      [attempts.map(({ pendingUserId }) => pendingUserId)]
    );
    expect(persisted.rows[0]?.count).toBe(1);
  });

  it("locks the real credential row across concurrent counter verifications", async () => {
    const userId = randomUUID();
    const credentialId = newCredentialId("counter-race");
    testUserIds.add(userId);
    await getSyncPool().query("INSERT INTO users (id) VALUES ($1)", [userId]);
    await getSyncPool().query(
      `INSERT INTO passkey_credentials (id, user_id, public_key_base64url, counter)
       VALUES ($1, $2, $3, 8)`,
      [credentialId, userId, VALID_CREDENTIAL_PUBLIC_KEY_BASE64URL]
    );
    const inputs = [0, 1].map((index) => ({
      mode: "authenticate",
      challengeToken: issueChallengeToken({
        mode: "authenticate",
        challenge: challenge(`counter-race-${index}`),
        expiresAt: Date.now() + 60_000
      }),
      response: { id: credentialId }
    }));
    mocks.verifyAuthenticationResponse.mockImplementation(async ({ credential }) => ({
      verified: true,
      authenticationInfo: { newCounter: credential.counter + 1 }
    }));

    const results = await Promise.all(inputs.map((input) => verifyPasskey(input)));
    expect(results).toHaveLength(2);
    expect(mocks.verifyAuthenticationResponse.mock.calls.map(([input]) => input.credential.counter).sort())
      .toEqual([8, 9]);
    const stored = await getSyncPool().query(
      "SELECT counter FROM passkey_credentials WHERE id = $1",
      [credentialId]
    );
    expect(Number(stored.rows[0]?.counter)).toBe(10);
  });

  it("keeps the global registration admission ceiling across a pool restart", async () => {
    const current = await getSyncPool().query<{ admission_count: number }>(
      `SELECT admission_count FROM registration_usage
       WHERE window_started_at = date_trunc('hour', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'`
    );
    const currentCount = Number(current.rows[0]?.admission_count ?? 0);
    process.env.SYNC_REGISTRATION_HOURLY_LIMIT = String(currentCount + 1);

    await expect(reserveRegistrationAdmission()).resolves.toBeUndefined();
    await closeSyncPoolForTests();
    await expect(reserveRegistrationAdmission()).rejects.toBeInstanceOf(RegistrationAdmissionQuotaError);
  });
});

function restoreEnv(name: string, value: string | undefined) {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}

async function currentRegistrationAdmissions() {
  const result = await getSyncPool().query<{ admission_count: number }>(
    `SELECT admission_count FROM registration_usage
     WHERE window_started_at = date_trunc('hour', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'`
  );
  return Number(result.rows[0]?.admission_count ?? 0);
}
