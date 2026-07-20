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
    globalVaultStorageLimit: 10_000_000_000
  })
}));

vi.mock("./tokens", () => ({
  readChallengeToken: mocks.readChallengeToken,
  issueSessionToken: mocks.issueSessionToken,
  issueChallengeToken: mocks.issueChallengeToken
}));

import {
  createPasskeyOptions,
  parsePasskeyOptionsInput,
  resetPasskeyMaintenanceForTests,
  verifyPasskey
} from "./passkeys";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const CHALLENGE = "c".repeat(43);

describe("passkey account safety", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    resetPasskeyMaintenanceForTests();
    mocks.ensureSyncSchema.mockResolvedValue(undefined);
    mocks.poolQuery.mockResolvedValue({ rowCount: 0, rows: [] });
    mocks.connect.mockResolvedValue({ query: mocks.clientQuery, release: mocks.release });
    mocks.issueSessionToken.mockReturnValue("session-token");
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
        credential: { id: "duplicate-id", publicKey: new Uint8Array([1, 2, 3]), counter: 0 }
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
      response: { response: { transports: ["attacker-controlled".repeat(10_000)] } }
    })).rejects.toThrow(/verification failed/i);

    const credentialCall = mocks.clientQuery.mock.calls
      .find(([sql]) => String(sql).includes("INSERT INTO passkey_credentials"));
    const credentialSQL = String(credentialCall?.[0]);
    expect(credentialSQL).toContain("ON CONFLICT (id) DO NOTHING");
    expect(credentialSQL).not.toContain("DO UPDATE");
    expect(credentialSQL).not.toContain("transports");
    expect(credentialCall?.[1]).toHaveLength(4);
    expect(JSON.stringify(credentialCall?.[1])).not.toContain("attacker-controlled");
    expect(mocks.clientQuery).toHaveBeenCalledWith("ROLLBACK");
    expect(mocks.issueSessionToken).not.toHaveBeenCalled();
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
        credential: { id: "duplicate-id", publicKey: new Uint8Array([1, 2, 3]), counter: 0 }
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
        credential: { id: "credential-1", publicKey: new Uint8Array([1, 2, 3]), counter: 0 }
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
    expect(mocks.clientQuery).toHaveBeenCalledWith("ROLLBACK");
    expect(mocks.clientQuery.mock.calls.some(([sql]) => String(sql).includes("INSERT INTO users"))).toBe(false);
    expect(mocks.issueSessionToken).not.toHaveBeenCalled();
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
          rows: [{
            id: "credential-1",
            user_id: USER_ID,
            public_key_base64url: "AQIDBA",
            counter: "8",
            transports: []
          }]
        };
      }
      if (sql.includes("consumed_challenges")) return { rowCount: 1, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    await expect(verifyPasskey({
      mode: "authenticate",
      challengeToken: "token",
      response: { id: "credential-1" }
    })).resolves.toEqual({ verified: true, userId: USER_ID, sessionToken: "session-token" });

    const statements = mocks.clientQuery.mock.calls.map(([sql]) => String(sql));
    const selectIndex = statements.findIndex((sql) => sql.includes("FOR UPDATE"));
    const verifyUpdateIndex = statements.findIndex((sql) => sql.includes("GREATEST(counter, $2)"));
    const commitIndex = statements.findIndex((sql) => sql === "COMMIT");
    expect(selectIndex).toBeGreaterThan(-1);
    expect(verifyUpdateIndex).toBeGreaterThan(selectIndex);
    expect(commitIndex).toBeGreaterThan(verifyUpdateIndex);
    expect(mocks.clientQuery).toHaveBeenCalledWith(expect.stringContaining("GREATEST(counter, $2)"), ["credential-1", 9]);
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
          rows: [{
            id: "credential-1",
            user_id: USER_ID,
            public_key_base64url: "AQIDBA",
            counter: "8"
          }]
        };
      }
      if (sql.includes("consumed_challenges")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    await expect(verifyPasskey({
      mode: "authenticate",
      challengeToken: "token",
      response: { id: "credential-1" }
    })).rejects.toThrow(/verification failed/i);

    expect(mocks.verifyAuthenticationResponse).toHaveBeenCalledOnce();
    expect(mocks.clientQuery).toHaveBeenCalledWith("ROLLBACK");
    expect(mocks.clientQuery.mock.calls.some(([sql]) => String(sql).includes("UPDATE passkey_credentials"))).toBe(false);
    expect(mocks.issueSessionToken).not.toHaveBeenCalled();
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
          rows: [{
            id: "credential-1",
            user_id: USER_ID,
            public_key_base64url: "AQIDBA",
            counter: "8"
          }]
        };
      }
      if (sql.includes("consumed_challenges")) return { rowCount: 1, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    let finishPrune: (() => void) | undefined;
    mocks.poolQuery.mockReturnValue(new Promise<void>((resolve) => {
      finishPrune = resolve;
    }));
    const input = {
      mode: "authenticate" as const,
      challengeToken: "token",
      response: { id: "credential-1" }
    };

    await expect(Promise.all([verifyPasskey(input), verifyPasskey(input)])).resolves.toHaveLength(2);
    expect(mocks.poolQuery).toHaveBeenCalledTimes(1);
    expect(mocks.poolQuery).toHaveBeenCalledWith(
      "DELETE FROM consumed_challenges WHERE consumed_at < now() - interval '15 minutes'"
    );

    finishPrune?.();
    await Promise.resolve();
    await expect(verifyPasskey(input)).resolves.toMatchObject({ verified: true });
    expect(mocks.poolQuery).toHaveBeenCalledTimes(1);
  });
});
