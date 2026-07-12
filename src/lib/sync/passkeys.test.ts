import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  ensureSyncSchema: vi.fn(),
  poolQuery: vi.fn(),
  connect: vi.fn(),
  clientQuery: vi.fn(),
  release: vi.fn(),
  verifyRegistrationResponse: vi.fn(),
  verifyAuthenticationResponse: vi.fn(),
  generateRegistrationOptions: vi.fn(),
  generateAuthenticationOptions: vi.fn(),
  readChallengeToken: vi.fn(),
  issueSessionToken: vi.fn(),
  issueChallengeToken: vi.fn()
}));

vi.mock("@simplewebauthn/server", () => ({
  verifyRegistrationResponse: mocks.verifyRegistrationResponse,
  verifyAuthenticationResponse: mocks.verifyAuthenticationResponse,
  generateRegistrationOptions: mocks.generateRegistrationOptions,
  generateAuthenticationOptions: mocks.generateAuthenticationOptions
}));

vi.mock("./postgres", () => ({
  ensureSyncSchema: mocks.ensureSyncSchema,
  getSyncPool: () => ({ query: mocks.poolQuery, connect: mocks.connect })
}));

vi.mock("./tokens", () => ({
  readChallengeToken: mocks.readChallengeToken,
  issueSessionToken: mocks.issueSessionToken,
  issueChallengeToken: mocks.issueChallengeToken
}));

import { parsePasskeyOptionsInput, verifyPasskey } from "./passkeys";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const CHALLENGE = "c".repeat(43);

describe("passkey account safety", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.ensureSyncSchema.mockResolvedValue(undefined);
    mocks.poolQuery.mockResolvedValue({ rowCount: 0, rows: [] });
    mocks.connect.mockResolvedValue({ query: mocks.clientQuery, release: mocks.release });
    mocks.issueSessionToken.mockReturnValue("session-token");
  });

  it("bounds account labels before generating registration options", () => {
    expect(parsePasskeyOptionsInput({ mode: "register", accountName: "  Mac  " })).toEqual({
      mode: "register",
      accountName: "Mac"
    });
    expect(() => parsePasskeyOptionsInput({ mode: "register", accountName: "x".repeat(81) })).toThrow(/80/);
    expect(() => parsePasskeyOptionsInput({ mode: "authenticate", accountName: "unexpected" })).toThrow(/only accepted/i);
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
      response: { response: { transports: [] } }
    })).rejects.toThrow(/verification failed/i);

    const credentialSQL = mocks.clientQuery.mock.calls
      .map(([sql]) => String(sql))
      .find((sql) => sql.includes("INSERT INTO passkey_credentials"));
    expect(credentialSQL).toContain("ON CONFLICT (id) DO NOTHING");
    expect(credentialSQL).not.toContain("DO UPDATE");
    expect(mocks.clientQuery).toHaveBeenCalledWith("ROLLBACK");
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
    expect(mocks.release).toHaveBeenCalledOnce();
  });
});
