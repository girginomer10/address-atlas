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
import { base64urlDecode } from "./base64url";
import { getSyncPasskeyConfig } from "./config";
import { verifyPasskey } from "./passkeys";
import { closeSyncPoolForTests, ensureSyncSchema, getSyncPool } from "./postgres";
import { resetRateLimitsForTests } from "./rate-limit";
import { issueChallengeToken, readBearerToken, readChallengeToken } from "./tokens";

const maybeDescribe = process.env.TEST_SYNC_DATABASE_URL ? describe : describe.skip;

maybeDescribe("passkey invariants against real Postgres", () => {
  const testUserIds = new Set<string>();
  const testChallenges = new Set<string>();
  let previousDatabaseURL: string | undefined;
  let previousSessionSecret: string | undefined;
  let previousMaxAccounts: string | undefined;

  beforeAll(async () => {
    previousDatabaseURL = process.env.SYNC_DATABASE_URL;
    previousSessionSecret = process.env.SYNC_SESSION_SECRET;
    previousMaxAccounts = process.env.SYNC_MAX_ACCOUNTS;
    process.env.SYNC_DATABASE_URL = process.env.TEST_SYNC_DATABASE_URL;
    process.env.SYNC_SESSION_SECRET = "ci-only-public-session-secret-for-integration-tests";
    await ensureSyncSchema();
  });

  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(async () => {
    resetRateLimitsForTests();
    restoreEnv("SYNC_MAX_ACCOUNTS", previousMaxAccounts);
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
    // 32 bytes of raw entropy encode to 43 base64url characters.
    expect(body.publicKey.challenge).toMatch(/^[A-Za-z0-9_-]{43}$/);

    const issued = readChallengeToken(body.challengeToken);
    testChallenges.add(issued.challenge);
    expect(issued.mode).toBe("register");
    expect(issued.challenge).toBe(body.publicKey.challenge);
    expect(base64urlDecode(body.publicKey.user.id).toString("utf8")).toBe(issued.pendingUserId);
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
    const optionsResponse = await postPasskeyOptions(optionsRequest({ mode: "register" }));
    expect(optionsResponse.status).toBe(200);
    const options = await optionsResponse.json();
    const issued = readChallengeToken(options.challengeToken);
    testChallenges.add(issued.challenge);
    testUserIds.add(issued.pendingUserId!);

    const credentialId = `route-registration-${randomUUID()}`;
    mocks.verifyRegistrationResponse.mockResolvedValue({
      verified: true,
      registrationInfo: {
        credential: { id: credentialId, publicKey: new Uint8Array([1, 2, 3, 4]), counter: 0 }
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
      requireUserVerification: true
    });

    const credentials = await getSyncPool().query(
      "SELECT count(*)::int AS count FROM passkey_credentials WHERE id = $1 AND user_id = $2",
      [credentialId, issued.pendingUserId]
    );
    expect(credentials.rows[0]?.count).toBe(1);
  });

  it("consumes a registration challenge once and rejects its replay", async () => {
    const pendingUserId = randomUUID();
    const credentialId = `registration-${randomUUID()}`;
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
        credential: { id: credentialId, publicKey: new Uint8Array([1, 2, 3, 4]), counter: 0 }
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
    const credentialId = `ceiling-${randomUUID()}`;
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
        credential: { id: credentialId, publicKey: new Uint8Array([1, 2, 3, 4]), counter: 0 }
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
    const credentialId = `authentication-${randomUUID()}`;
    const challengeValue = challenge("authenticate");
    testUserIds.add(userId);
    await getSyncPool().query("INSERT INTO users (id) VALUES ($1)", [userId]);
    await getSyncPool().query(
      `INSERT INTO passkey_credentials (id, user_id, public_key_base64url, counter)
       VALUES ($1, $2, $3, $4)`,
      [credentialId, userId, "AQIDBA", 8]
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
});

function restoreEnv(name: string, value: string | undefined) {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}
