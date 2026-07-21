import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  ensureSyncSchema: vi.fn(),
  poolQuery: vi.fn(),
  connect: vi.fn(),
  clientQuery: vi.fn(),
  release: vi.fn(),
  verifyRegistrationResponse: vi.fn(),
  verifyAuthenticationResponse: vi.fn(),
  readChallengeToken: vi.fn(),
  issueSessionToken: vi.fn(),
  createSessionGrant: vi.fn(),
  issueChallengeToken: vi.fn()
}));

vi.mock("@simplewebauthn/server", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@simplewebauthn/server")>()),
  verifyRegistrationResponse: mocks.verifyRegistrationResponse,
  verifyAuthenticationResponse: mocks.verifyAuthenticationResponse
}));

vi.mock("./postgres", () => ({
  ensureSyncSchema: mocks.ensureSyncSchema,
  getSyncPool: () => ({ query: mocks.poolQuery, connect: mocks.connect })
}));

vi.mock("./config", () => ({
  getSyncPasskeyConfig: () => ({
    rpID: "localhost",
    rpName: "Address Atlas",
    expectedOrigin: "http://localhost:3000"
  }),
  getSyncLimitConfig: () => ({
    maxAccounts: 100_000,
    dailyVaultWriteLimit: 100,
    dailyVaultByteLimit: 64_000_000,
    globalDailyVaultIngressByteLimit: 2_000_000_000,
    globalVaultStorageLimit: 10_000_000_000
  }),
  getSyncRegistrationConfig: () => ({ enabled: true, hourlyLimit: 100 })
}));

vi.mock("./sessions", () => ({
  createSessionGrant: mocks.createSessionGrant
}));

vi.mock("./tokens", () => ({
  readChallengeToken: mocks.readChallengeToken,
  issueSessionToken: mocks.issueSessionToken,
  issueChallengeToken: mocks.issueChallengeToken
}));

import {
  createPasskeyOptions,
  parsePasskeyOptionsInput,
  parsePasskeyVerifyInput,
  resetPasskeyMaintenanceForTests,
  verifyPasskey
} from "./passkeys";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const CHALLENGE = "c".repeat(43);
const CREDENTIAL_ID = Buffer.from("credential-1").toString("base64url");
const DUPLICATE_CREDENTIAL_ID = Buffer.from("duplicate-id").toString("base64url");
const VALID_CREDENTIAL_PUBLIC_KEY = Buffer.from(
  "a50102032620012158206b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2962258204fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
  "hex"
);
const VALID_CREDENTIAL_PUBLIC_KEY_BASE64URL = VALID_CREDENTIAL_PUBLIC_KEY.toString("base64url");

function storedCredentialRow(id = CREDENTIAL_ID) {
  return {
    id,
    user_id: USER_ID,
    public_key_base64url: VALID_CREDENTIAL_PUBLIC_KEY_BASE64URL,
    counter: "8",
    created_at: new Date("2026-07-13T12:00:00Z"),
    updated_at: new Date("2026-07-13T12:00:00Z"),
    stored_row_valid: true
  };
}

describe("passkey account safety", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    resetPasskeyMaintenanceForTests();
    mocks.ensureSyncSchema.mockResolvedValue(undefined);
    mocks.poolQuery.mockResolvedValue({ rowCount: 1, rows: [{ admission_count: 1 }] });
    mocks.connect.mockResolvedValue({ query: mocks.clientQuery, release: mocks.release });
    mocks.issueSessionToken.mockReturnValue("session-token");
    mocks.createSessionGrant.mockResolvedValue({ sessionToken: "session-token" });
    mocks.issueChallengeToken.mockReturnValue("challenge-token");
  });

  it("bounds account labels before generating registration options", () => {
    expect(parsePasskeyOptionsInput({ mode: "register", accountName: "  Mac  " })).toEqual({
      mode: "register",
      accountName: "Mac"
    });
    expect(() => parsePasskeyOptionsInput({ mode: "register", accountName: "x".repeat(81) })).toThrow(/80/);
    expect(() => parsePasskeyOptionsInput({ mode: "authenticate", accountName: "unexpected" })).toThrow(/only accepted/i);
  });

  it("bounds credential IDs before concurrency or database work", () => {
    expect(() => parsePasskeyVerifyInput({
      mode: "authenticate",
      challengeToken: "token",
      response: { id: "x".repeat(1_365) }
    })).toThrow(/credential ID/i);
    expect(() => parsePasskeyVerifyInput({
      mode: "authenticate",
      challengeToken: "token",
      response: { id: { nested: true } }
    })).toThrow(/credential ID/i);
  });

  it.each(["register", "authenticate"] as const)(
    "binds the %s token to the exact challenge returned to the browser",
    async (mode) => {
      const result = await createPasskeyOptions({ mode });
      const tokenPayload = mocks.issueChallengeToken.mock.calls[0]?.[0];

      expect(result?.challengeToken).toBe("challenge-token");
      expect(result?.publicKey.challenge).toHaveLength(43);
      expect(tokenPayload.challenge).toBe(result?.publicKey.challenge);
    }
  );

  it("issues registration options without consuming durable admission", async () => {
    const options = await createPasskeyOptions({ mode: "register" });
    expect(options).toMatchObject({
      mode: "register"
    });
    if (!("pubKeyCredParams" in options.publicKey)) {
      throw new Error("Expected registration options.");
    }
    expect(options.publicKey.pubKeyCredParams).toEqual([
      { alg: -7, type: "public-key" },
      { alg: -257, type: "public-key" }
    ]);

    expect(mocks.ensureSyncSchema).not.toHaveBeenCalled();
    expect(mocks.poolQuery.mock.calls.some(([sql]) => String(sql).includes("registration_usage")))
      .toBe(false);
  });

  it("rejects duplicate credential IDs and rolls back without mutating their owner", async () => {
    mocks.readChallengeToken.mockReturnValue({
      mode: "register",
      challenge: CHALLENGE,
      pendingUserId: USER_ID,
      expiresAt: Date.now() + 60_000
    });
    mocks.verifyRegistrationResponse.mockResolvedValue({
      verified: true,
      registrationInfo: {
        credential: {
          id: DUPLICATE_CREDENTIAL_ID,
          publicKey: VALID_CREDENTIAL_PUBLIC_KEY,
          counter: 0
        }
      }
    });
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (sql.includes("consumed_challenges")) return { rowCount: 1, rows: [] };
      if (sql.includes("count(*)")) return { rowCount: 1, rows: [{ count: "0" }] };
      if (sql.includes("INSERT INTO passkey_credentials")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    await expect(verifyPasskey({
      mode: "register",
      challengeToken: "token",
      response: {
        id: DUPLICATE_CREDENTIAL_ID,
        response: { transports: ["attacker-controlled".repeat(10_000)] }
      }
    })).rejects.toThrow(/verification failed/i);

    const credentialCall = mocks.clientQuery.mock.calls
      .find(([sql]) => String(sql).includes("INSERT INTO passkey_credentials"));
    const credentialSQL = String(credentialCall?.[0]);
    expect(credentialSQL).toContain("ON CONFLICT (id) DO NOTHING");
    expect(credentialSQL).not.toContain("DO UPDATE");
    expect(credentialSQL).not.toContain("transports");
    expect(credentialCall?.[1]).toHaveLength(4);
    expect(JSON.stringify(credentialCall?.[1])).not.toContain("attacker-controlled");
    const statements = mocks.clientQuery.mock.calls.map(([sql]) => String(sql));
    const verifiedAccountCap = statements.findIndex((sql) => sql.includes("count(*)"));
    const admission = statements.findIndex((sql) => sql.includes("INSERT INTO registration_usage"));
    const userInsert = statements.findIndex((sql) => sql.includes("INSERT INTO users"));
    const credentialInsert = statements.findIndex((sql) => sql.includes("INSERT INTO passkey_credentials"));
    expect(admission).toBeGreaterThan(verifiedAccountCap);
    expect(userInsert).toBeGreaterThan(admission);
    expect(credentialInsert).toBeGreaterThan(userInsert);
    expect(mocks.clientQuery).toHaveBeenCalledWith("ROLLBACK");
    expect(mocks.createSessionGrant).not.toHaveBeenCalled();
  });

  it("destroys a registration client when rollback also fails", async () => {
    mocks.readChallengeToken.mockReturnValue({
      mode: "register",
      challenge: CHALLENGE,
      pendingUserId: USER_ID,
      expiresAt: Date.now() + 60_000
    });
    mocks.verifyRegistrationResponse.mockResolvedValue({
      verified: true,
      registrationInfo: {
        credential: {
          id: DUPLICATE_CREDENTIAL_ID,
          publicKey: VALID_CREDENTIAL_PUBLIC_KEY,
          counter: 0
        }
      }
    });
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (sql === "ROLLBACK") throw new Error("rollback timed out");
      if (sql.includes("consumed_challenges")) return { rowCount: 1, rows: [] };
      if (sql.includes("count(*)")) return { rowCount: 1, rows: [{ count: "0" }] };
      if (sql.includes("INSERT INTO passkey_credentials")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    await expect(verifyPasskey({
      mode: "register",
      challengeToken: "token",
      response: { id: "duplicate-id" }
    })).rejects.toThrow(/verification failed/i);
    expect(mocks.release).toHaveBeenCalledWith(true);
  });

  it("rejects a replayed registration challenge before creating an account", async () => {
    mocks.readChallengeToken.mockReturnValue({
      mode: "register",
      challenge: CHALLENGE,
      pendingUserId: USER_ID,
      expiresAt: Date.now() + 60_000
    });
    mocks.verifyRegistrationResponse.mockResolvedValue({
      verified: true,
      registrationInfo: {
        credential: {
          id: CREDENTIAL_ID,
          publicKey: VALID_CREDENTIAL_PUBLIC_KEY,
          counter: 0
        }
      }
    });
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (sql.includes("consumed_challenges")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    await expect(verifyPasskey({
      mode: "register",
      challengeToken: "token",
      response: { id: "credential-1" }
    })).rejects.toThrow(/verification failed/i);

    expect(mocks.verifyRegistrationResponse).toHaveBeenCalledOnce();
    expect(mocks.verifyRegistrationResponse).toHaveBeenCalledWith(expect.objectContaining({
      supportedAlgorithmIDs: [-7, -257]
    }));
    expect(mocks.clientQuery).toHaveBeenCalledWith("ROLLBACK");
    expect(mocks.clientQuery.mock.calls.some(([sql]) => String(sql).includes("INSERT INTO users"))).toBe(false);
    expect(mocks.createSessionGrant).not.toHaveBeenCalled();
  });

  it("locks a credential through verification and updates its counter monotonically", async () => {
    mocks.readChallengeToken.mockReturnValue({
      mode: "authenticate",
      challenge: CHALLENGE,
      expiresAt: Date.now() + 60_000
    });
    mocks.verifyAuthenticationResponse.mockResolvedValue({
      verified: true,
      authenticationInfo: { newCounter: 9 }
    });
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (sql.includes("FROM passkey_credentials")) {
        return {
          rowCount: 1,
          rows: [storedCredentialRow()]
        };
      }
      if (sql.includes("consumed_challenges")) return { rowCount: 1, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    await expect(verifyPasskey({
      mode: "authenticate",
      challengeToken: "token",
      response: { id: CREDENTIAL_ID }
    })).resolves.toEqual({ verified: true, userId: USER_ID, sessionToken: "session-token" });

    const statements = mocks.clientQuery.mock.calls.map(([sql]) => String(sql));
    const selectIndex = statements.findIndex((sql) => sql.includes("FOR UPDATE"));
    const verifyUpdateIndex = statements.findIndex((sql) => sql.includes("GREATEST(counter, $2)"));
    const commitIndex = statements.findIndex((sql) => sql === "COMMIT");
    expect(selectIndex).toBeGreaterThan(-1);
    expect(verifyUpdateIndex).toBeGreaterThan(selectIndex);
    expect(commitIndex).toBeGreaterThan(verifyUpdateIndex);
    expect(mocks.clientQuery).toHaveBeenCalledWith(
      expect.stringContaining("GREATEST(counter, $2)"),
      [CREDENTIAL_ID, 9]
    );
    const verificationInput = mocks.verifyAuthenticationResponse.mock.calls[0]?.[0];
    expect(verificationInput.credential).not.toHaveProperty("transports");
    expect(mocks.release).toHaveBeenCalledOnce();
  });

  it("rejects a replayed authentication challenge before updating the credential", async () => {
    mocks.readChallengeToken.mockReturnValue({
      mode: "authenticate",
      challenge: CHALLENGE,
      expiresAt: Date.now() + 60_000
    });
    mocks.verifyAuthenticationResponse.mockResolvedValue({
      verified: true,
      authenticationInfo: { newCounter: 9 }
    });
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (sql.includes("FROM passkey_credentials")) {
        return {
          rowCount: 1,
          rows: [storedCredentialRow()]
        };
      }
      if (sql.includes("consumed_challenges")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    await expect(verifyPasskey({
      mode: "authenticate",
      challengeToken: "token",
      response: { id: CREDENTIAL_ID }
    })).rejects.toThrow(/verification failed/i);

    expect(mocks.verifyAuthenticationResponse).toHaveBeenCalledOnce();
    expect(mocks.clientQuery).toHaveBeenCalledWith("ROLLBACK");
    expect(mocks.clientQuery.mock.calls.some(([sql]) => String(sql).includes("UPDATE passkey_credentials"))).toBe(false);
    expect(mocks.createSessionGrant).not.toHaveBeenCalled();
  });

  it("rejects a stored credential sentinel without decoding unsafe fields", async () => {
    mocks.readChallengeToken.mockReturnValue({
      mode: "authenticate",
      challenge: CHALLENGE,
      expiresAt: Date.now() + 60_000
    });
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (sql.includes("FROM passkey_credentials")) {
        return {
          rowCount: 1,
          rows: [{
            id: null,
            user_id: USER_ID,
            public_key_base64url: null,
            counter: "8",
            created_at: null,
            updated_at: null,
            stored_row_valid: false
          }]
        };
      }
      return { rowCount: 1, rows: [] };
    });

    const failure = await verifyPasskey({
      mode: "authenticate",
      challengeToken: "token",
      response: { id: CREDENTIAL_ID }
    }).catch((error: unknown) => error);

    expect(failure).toMatchObject({ operationalCode: "passkey_credential_invalid" });
    expect(mocks.verifyAuthenticationResponse).not.toHaveBeenCalled();
    expect(mocks.clientQuery).toHaveBeenCalledWith("ROLLBACK");
  });

  it("keeps best-effort challenge pruning single-flight and rate limited", async () => {
    mocks.readChallengeToken.mockReturnValue({
      mode: "authenticate",
      challenge: CHALLENGE,
      expiresAt: Date.now() + 60_000
    });
    mocks.verifyAuthenticationResponse.mockResolvedValue({
      verified: true,
      authenticationInfo: { newCounter: 9 }
    });
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (sql.includes("FROM passkey_credentials")) {
        return {
          rowCount: 1,
          rows: [storedCredentialRow()]
        };
      }
      if (sql.includes("consumed_challenges")) return { rowCount: 1, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    let finishPrune: ((value: { rowCount: number; rows: never[] }) => void) | undefined;
    mocks.poolQuery.mockReturnValue(new Promise((resolve) => {
      finishPrune = resolve;
    }));
    const input = {
      mode: "authenticate" as const,
      challengeToken: "token",
      response: { id: CREDENTIAL_ID }
    };

    await expect(Promise.all([verifyPasskey(input), verifyPasskey(input)])).resolves.toHaveLength(2);
    expect(mocks.poolQuery).toHaveBeenCalledTimes(1);
    expect(mocks.poolQuery).toHaveBeenCalledWith(
      expect.stringContaining("FOR UPDATE SKIP LOCKED"),
      [10_000]
    );

    finishPrune?.({ rowCount: 0, rows: [] });
    await Promise.resolve();
    await expect(verifyPasskey(input)).resolves.toMatchObject({ verified: true });
    expect(mocks.poolQuery).toHaveBeenCalledTimes(1);
  });

  it("prunes expired consumed challenges in bounded batches", async () => {
    mocks.readChallengeToken.mockReturnValue({
      mode: "authenticate",
      challenge: CHALLENGE,
      expiresAt: Date.now() + 60_000
    });
    mocks.verifyAuthenticationResponse.mockResolvedValue({
      verified: true,
      authenticationInfo: { newCounter: 9 }
    });
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (sql.includes("FROM passkey_credentials")) {
        return {
          rowCount: 1,
          rows: [storedCredentialRow()]
        };
      }
      if (sql.includes("consumed_challenges")) return { rowCount: 1, rows: [] };
      return { rowCount: 1, rows: [] };
    });
    mocks.poolQuery
      .mockResolvedValueOnce({ rowCount: 10_000, rows: [] })
      .mockResolvedValueOnce({ rowCount: 17, rows: [] });

    await expect(verifyPasskey({
      mode: "authenticate",
      challengeToken: "token",
      response: { id: CREDENTIAL_ID }
    })).resolves.toMatchObject({ verified: true });

    await vi.waitFor(() => expect(mocks.poolQuery).toHaveBeenCalledTimes(2));
    expect(mocks.poolQuery).toHaveBeenNthCalledWith(
      1,
      expect.stringContaining("LIMIT $1"),
      [10_000]
    );
    expect(mocks.poolQuery).toHaveBeenNthCalledWith(
      2,
      expect.stringContaining("LIMIT $1"),
      [10_000]
    );
  });

  it("reports a privacy-safe maintenance signal without failing authentication", async () => {
    const errorLog = vi.spyOn(console, "error").mockImplementation(() => undefined);
    mocks.readChallengeToken.mockReturnValue({
      mode: "authenticate",
      challenge: CHALLENGE,
      expiresAt: Date.now() + 60_000
    });
    mocks.verifyAuthenticationResponse.mockResolvedValue({
      verified: true,
      authenticationInfo: { newCounter: 9 }
    });
    mocks.clientQuery.mockImplementation(async (sql: string) => {
      if (sql.includes("FROM passkey_credentials")) {
        return { rowCount: 1, rows: [storedCredentialRow()] };
      }
      if (sql.includes("consumed_challenges")) return { rowCount: 1, rows: [] };
      return { rowCount: 1, rows: [] };
    });
    mocks.poolQuery.mockRejectedValueOnce(
      Object.assign(new Error("postgres://admin:secret@private-db"), { code: "57014" })
    );

    await expect(verifyPasskey({
      mode: "authenticate",
      challengeToken: "token",
      response: { id: CREDENTIAL_ID }
    })).resolves.toMatchObject({ verified: true });

    await vi.waitFor(() => expect(errorLog).toHaveBeenCalledOnce());
    const serialized = String(errorLog.mock.calls[0]?.[0]);
    expect(JSON.parse(serialized)).toMatchObject({
      event: "auth.challenge_prune_failed",
      reason: "expired_challenge_prune_failed",
      errorCode: "database_query_failed"
    });
    expect(serialized).not.toContain("secret");
    expect(serialized).not.toContain("private-db");
    errorLog.mockRestore();
  });
});
