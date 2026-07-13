import { randomUUID } from "node:crypto";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  verifyRegistrationResponse: vi.fn(),
  verifyAuthenticationResponse: vi.fn(),
  readChallengeToken: vi.fn(),
  issueSessionToken: vi.fn(),
  issueChallengeToken: vi.fn()
}));

vi.mock("@simplewebauthn/server", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@simplewebauthn/server")>()),
  verifyRegistrationResponse: mocks.verifyRegistrationResponse,
  verifyAuthenticationResponse: mocks.verifyAuthenticationResponse
}));

vi.mock("./tokens", () => ({
  readChallengeToken: mocks.readChallengeToken,
  issueSessionToken: mocks.issueSessionToken,
  issueChallengeToken: mocks.issueChallengeToken
}));

import { verifyPasskey } from "./passkeys";
import { closeSyncPoolForTests, ensureSyncSchema, getSyncPool } from "./postgres";

const maybeDescribe = process.env.TEST_SYNC_DATABASE_URL ? describe : describe.skip;

maybeDescribe("passkey invariants against real Postgres", () => {
  const testUserIds = new Set<string>();
  const testChallenges = new Set<string>();
  let previousDatabaseURL: string | undefined;
  let previousMaxAccounts: string | undefined;

  beforeAll(async () => {
    previousDatabaseURL = process.env.SYNC_DATABASE_URL;
    previousMaxAccounts = process.env.SYNC_MAX_ACCOUNTS;
    process.env.SYNC_DATABASE_URL = process.env.TEST_SYNC_DATABASE_URL;
    await ensureSyncSchema();
  });

  beforeEach(() => {
    vi.clearAllMocks();
    mocks.issueSessionToken.mockReturnValue("session-token");
  });

  afterEach(async () => {
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
    restoreEnv("SYNC_MAX_ACCOUNTS", previousMaxAccounts);
  });

  function challenge(prefix: string) {
    const value = `${prefix}-${randomUUID()}`;
    testChallenges.add(value);
    return value;
  }

  it("consumes a registration challenge once and rejects its replay", async () => {
    const pendingUserId = randomUUID();
    const credentialId = `registration-${randomUUID()}`;
    const challengeValue = challenge("register");
    testUserIds.add(pendingUserId);
    mocks.readChallengeToken.mockReturnValue({
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
      challengeToken: "challenge-token",
      response: { id: credentialId }
    };

    await expect(verifyPasskey(input)).resolves.toMatchObject({
      verified: true,
      userId: pendingUserId,
      sessionToken: "session-token"
    });
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
    expect(mocks.issueSessionToken).toHaveBeenCalledOnce();
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
    mocks.readChallengeToken.mockReturnValue({
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
      challengeToken: "challenge-token",
      response: { id: credentialId }
    })).rejects.toThrow(/verification failed/i);

    const pendingUser = await getSyncPool().query("SELECT id FROM users WHERE id = $1", [pendingUserId]);
    const consumed = await getSyncPool().query(
      "SELECT challenge FROM consumed_challenges WHERE challenge = $1",
      [challengeValue]
    );
    expect(pendingUser.rowCount).toBe(0);
    expect(consumed.rowCount).toBe(0);
    expect(mocks.issueSessionToken).not.toHaveBeenCalled();
  });

  it("updates a credential once and rejects an authentication challenge replay", async () => {
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
    mocks.readChallengeToken.mockReturnValue({
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
      challengeToken: "challenge-token",
      response: { id: credentialId }
    };

    await expect(verifyPasskey(input)).resolves.toMatchObject({
      verified: true,
      userId,
      sessionToken: "session-token"
    });
    await expect(verifyPasskey(input)).rejects.toThrow(/verification failed/i);

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
    expect(mocks.issueSessionToken).toHaveBeenCalledOnce();
  });
});

function restoreEnv(name: string, value: string | undefined) {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}
