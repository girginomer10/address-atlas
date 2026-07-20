import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { validateSessionSecret } from "./config";
import {
  issueChallengeToken,
  issueSessionToken,
  readBearerToken,
  readChallengeToken
} from "./tokens";

const SECRET = "f4L7p9Q2v6N8x1R3m5K0s2T4u7W9y1Z3b6D8g0H2";
const USER_ID = "11111111-1111-4111-8111-111111111111";

describe("sync tokens", () => {
  beforeEach(() => {
    vi.stubEnv("SYNC_SESSION_SECRET", SECRET);
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.useRealTimers();
  });

  it("requires a long random non-placeholder secret", () => {
    expect(() => validateSessionSecret("short")).toThrow(/32 bytes/i);
    expect(() => validateSessionSecret("replace-with-at-least-32-random-bytes")).toThrow(/random/i);
    expect(() => validateSessionSecret("a".repeat(64))).toThrow(/random/i);
    expect(validateSessionSecret(SECRET)).toBe(SECRET);
  });

  it("domain-separates challenge and session tokens", () => {
    const challenge = issueChallengeToken({
      mode: "authenticate",
      challenge: "x".repeat(43),
      expiresAt: Date.now() + 60_000
    });
    const session = issueSessionToken(USER_ID);

    expect(readChallengeToken(challenge).mode).toBe("authenticate");
    expect(readBearerToken(`Bearer ${session}`).userId).toBe(USER_ID);
    expect(() => readBearerToken(`Bearer ${challenge}`)).toThrow(/invalid|expired/i);
    expect(() => readChallengeToken(session)).toThrow(/invalid|expired/i);
  });

  it("rejects a non-UUID account identifier before issuing a session", () => {
    expect(() => issueSessionToken("legacy-account-name")).toThrow(/invalid session user id/i);
  });

  it("rejects expired, malformed, and tampered tokens", () => {
    vi.setSystemTime(new Date("2026-07-12T12:00:00Z"));
    const expired = issueChallengeToken({
      mode: "authenticate",
      challenge: "x".repeat(43),
      expiresAt: Date.now() - 1
    });
    expect(() => readChallengeToken(expired)).toThrow(/expired/i);

    const token = issueSessionToken(USER_ID);
    const parts = token.split(".");
    parts[2] = `${parts[2][0] === "A" ? "B" : "A"}${parts[2].slice(1)}`;
    expect(() => readBearerToken(`Bearer ${parts.join(".")}`)).toThrow(/invalid|expired/i);
    expect(() => readBearerToken("Basic anything")).toThrow(/invalid|expired/i);
  });
});
