import { createHmac, timingSafeEqual } from "node:crypto";
import { base64urlDecode, base64urlEncode } from "./base64url";

export interface ChallengeToken {
  mode: "register" | "authenticate";
  challenge: string;
  pendingUserId?: string;
  expiresAt: number;
}

export interface SessionToken {
  userId: string;
  expiresAt: number;
}

function secret() {
  const configured = process.env.SYNC_SESSION_SECRET?.trim();
  if (!configured) {
    throw new Error("SYNC_SESSION_SECRET is required.");
  }
  return configured;
}

export function signToken<T extends object>(payload: T) {
  const body = base64urlEncode(JSON.stringify(payload));
  const signature = createHmac("sha256", secret()).update(body).digest();
  return `${body}.${base64urlEncode(signature)}`;
}

export function verifyToken<T extends object>(token: string): T {
  const [body, signature] = token.split(".");
  if (!body || !signature) throw new Error("Invalid token.");
  const expected = createHmac("sha256", secret()).update(body).digest();
  const actual = base64urlDecode(signature);
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
    throw new Error("Invalid token signature.");
  }
  const parsed = JSON.parse(base64urlDecode(body).toString("utf8")) as T & { expiresAt?: number };
  if (typeof parsed.expiresAt !== "number") {
    throw new Error("Token is missing an expiry.");
  }
  if (Date.now() > parsed.expiresAt) {
    throw new Error("Token expired.");
  }
  return parsed as T;
}

export function issueSessionToken(userId: string) {
  return signToken<SessionToken>({
    userId,
    expiresAt: Date.now() + 1000 * 60 * 60 * 12
  });
}

export function readBearerToken(header: string | null) {
  const match = header?.match(/^Bearer\s+(.+)$/i);
  if (!match) throw new Error("Authorization bearer token is required.");
  return verifyToken<SessionToken>(match[1]);
}
