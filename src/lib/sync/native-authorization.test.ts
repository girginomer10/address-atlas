import { createHash } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  ensureSyncSchema: vi.fn(),
  connect: vi.fn(),
  query: vi.fn(),
  release: vi.fn()
}));

vi.mock("./postgres", () => ({
  ensureSyncSchema: mocks.ensureSyncSchema,
  getSyncPool: () => ({ connect: mocks.connect })
}));

import {
  exchangeNativeAuthorization,
  NativeAuthorizationExchangeError,
  nativeAuthorizationConsumptionKey,
  parseNativeAuthorizationExchangeInput
} from "./native-authorization";
import {
  issueNativeAuthorizationCode,
  issueSessionToken,
  readSessionToken
} from "./tokens";

const SECRET = "f4L7p9Q2v6N8x1R3m5K0s2T4u7W9y1Z3b6D8g0H2";
const USER_ID = "11111111-1111-4111-8111-111111111111";
const SESSION_ID = "22222222-2222-4222-8222-222222222222";
const VERIFIER = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
const CHALLENGE = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";

describe("native authorization exchange", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-21T12:00:00Z"));
    vi.stubEnv("SYNC_SESSION_SECRET", SECRET);
    vi.clearAllMocks();
    mocks.ensureSyncSchema.mockResolvedValue(undefined);
    mocks.connect.mockResolvedValue({ query: mocks.query, release: mocks.release });
    installLiveGrant();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllEnvs();
  });

  it("matches the RFC 7636 S256 vector and deterministically reissues the same session token", async () => {
    expect(createHash("sha256").update(VERIFIER, "ascii").digest("base64url"))
      .toBe(CHALLENGE);
    const { sessionToken, authorizationCode } = issueCode();

    await expect(exchangeNativeAuthorization({ authorizationCode, codeVerifier: VERIFIER }))
      .resolves.toEqual({ userId: USER_ID, sessionToken });

    const insert = mocks.query.mock.calls.find(([sql]) => String(sql).includes("INSERT INTO consumed_challenges"));
    expect(insert?.[1]).toEqual([nativeAuthorizationConsumptionKey(authorizationCode)]);
    expect(String(insert?.[1]?.[0])).not.toContain(authorizationCode);
    const statements = mocks.query.mock.calls.map(([sql]) => String(sql));
    const accountLock = statements.findIndex((sql) => sql.includes("FOR KEY SHARE OF account"));
    const grantLock = statements.findIndex((sql) => sql.includes("FOR SHARE OF grant_row"));
    expect(accountLock).toBeGreaterThan(-1);
    expect(grantLock).toBeGreaterThan(accountLock);
    expect(statements[grantLock]).not.toContain("JOIN users");
    expect(mocks.query).toHaveBeenCalledWith("COMMIT");
    expect(mocks.query).not.toHaveBeenCalledWith("ROLLBACK");
  });

  it("rejects a wrong verifier without consuming the legitimate code", async () => {
    const { authorizationCode } = issueCode();

    await expect(exchangeNativeAuthorization({
      authorizationCode,
      codeVerifier: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    })).rejects.toBeInstanceOf(NativeAuthorizationExchangeError);

    expect(mocks.ensureSyncSchema).not.toHaveBeenCalled();
    expect(mocks.connect).not.toHaveBeenCalled();
  });

  it("rejects forged and expired codes before touching durable state", async () => {
    const { authorizationCode } = issueCode();
    const forged = `${authorizationCode.slice(0, -1)}${authorizationCode.endsWith("A") ? "B" : "A"}`;

    await expect(exchangeNativeAuthorization({ authorizationCode: forged, codeVerifier: VERIFIER }))
      .rejects.toBeInstanceOf(NativeAuthorizationExchangeError);
    vi.advanceTimersByTime(2 * 60_000 + 1);
    await expect(exchangeNativeAuthorization({ authorizationCode, codeVerifier: VERIFIER }))
      .rejects.toBeInstanceOf(NativeAuthorizationExchangeError);

    expect(mocks.connect).not.toHaveBeenCalled();
  });

  it("fails a replay atomically and leaves the live grant undisclosed", async () => {
    const { authorizationCode } = issueCode();
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("INSERT INTO consumed_challenges")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    await expect(exchangeNativeAuthorization({ authorizationCode, codeVerifier: VERIFIER }))
      .rejects.toBeInstanceOf(NativeAuthorizationExchangeError);

    expect(mocks.query).toHaveBeenCalledWith("ROLLBACK");
    expect(mocks.query.mock.calls.some(([sql]) => String(sql).includes("FROM session_grants")))
      .toBe(false);
  });

  it("rolls back consumption when the underlying session grant is no longer active", async () => {
    const { authorizationCode } = issueCode();
    installLiveGrant(false);

    await expect(exchangeNativeAuthorization({ authorizationCode, codeVerifier: VERIFIER }))
      .rejects.toBeInstanceOf(NativeAuthorizationExchangeError);

    expect(mocks.query).toHaveBeenCalledWith("ROLLBACK");
  });

  it("stops before locking the grant when the parent account is gone", async () => {
    const { authorizationCode } = issueCode();
    mocks.query.mockImplementation(async (sql: string) => {
      if (sql.includes("INSERT INTO consumed_challenges")) {
        return { rowCount: 1, rows: [{ challenge: "digest" }] };
      }
      if (sql.includes("FROM users AS account")) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [] };
    });

    await expect(exchangeNativeAuthorization({ authorizationCode, codeVerifier: VERIFIER }))
      .rejects.toBeInstanceOf(NativeAuthorizationExchangeError);

    expect(mocks.query.mock.calls.some(([sql]) => String(sql).includes("FROM session_grants")))
      .toBe(false);
    expect(mocks.query).toHaveBeenCalledWith("ROLLBACK");
  });

  it("requires the exact public request field names and canonical 32-byte verifier", () => {
    const { authorizationCode } = issueCode();
    expect(parseNativeAuthorizationExchangeInput({ authorizationCode, codeVerifier: VERIFIER }))
      .toEqual({ authorizationCode, codeVerifier: VERIFIER });
    expect(() => parseNativeAuthorizationExchangeInput({
      code: authorizationCode,
      codeVerifier: VERIFIER
    })).toThrow(NativeAuthorizationExchangeError);
    expect(() => parseNativeAuthorizationExchangeInput({
      authorizationCode,
      codeVerifier: `${VERIFIER}=`
    })).toThrow(NativeAuthorizationExchangeError);
    expect(() => parseNativeAuthorizationExchangeInput({
      authorizationCode,
      codeVerifier: VERIFIER,
      sessionToken: "bearer-confusion"
    })).toThrow(NativeAuthorizationExchangeError);
    expect(() => parseNativeAuthorizationExchangeInput({
      authorizationCode,
      codeVerifier: VERIFIER,
      userId: USER_ID
    })).toThrow(NativeAuthorizationExchangeError);
  });
});

function issueCode() {
  const sessionToken = issueSessionToken(USER_ID, SESSION_ID);
  const authorizationCode = issueNativeAuthorizationCode(
    readSessionToken(sessionToken),
    CHALLENGE
  );
  return { authorizationCode, sessionToken };
}

function installLiveGrant(active = true) {
  mocks.query.mockImplementation(async (sql: string) => {
    if (sql.includes("INSERT INTO consumed_challenges")) {
      return { rowCount: 1, rows: [{ challenge: "digest" }] };
    }
    if (sql.includes("FROM session_grants")) {
      return { rowCount: active ? 1 : 0, rows: active ? [{ id: SESSION_ID }] : [] };
    }
    return { rowCount: 1, rows: [] };
  });
}
