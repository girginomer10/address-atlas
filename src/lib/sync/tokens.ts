import { createHmac, timingSafeEqual } from "node:crypto";
import { base64urlDecode, base64urlEncode } from "./base64url";
import { getSyncSessionSecret } from "./config";

export { SyncConfigurationError as TokenConfigurationError, validateSessionSecret } from "./config";

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

type TokenPurpose = "challenge" | "session";

export class TokenValidationError extends Error {
  constructor(message = "Invalid or expired token.") {
    super(message);
    this.name = "TokenValidationError";
  }
}

const TOKEN_VERSION = "v1";
const TOKEN_CONTEXT = "address-atlas-sync";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function secret() {
  return getSyncSessionSecret();
}

function signToken<T extends object>(purpose: TokenPurpose, payload: T) {
  const body = base64urlEncode(JSON.stringify(payload));
  const signature = createHmac("sha256", secret())
    .update(tokenPreimage(purpose, body))
    .digest();
  return `${TOKEN_VERSION}.${purpose}.${body}.${base64urlEncode(signature)}`;
}

function verifyToken<T extends object>(purpose: TokenPurpose, token: string): T {
  const parts = token.split(".");
  if (parts.length !== 4) throw new TokenValidationError();
  const [version, encodedPurpose, body, signature] = parts;
  if (version !== TOKEN_VERSION || encodedPurpose !== purpose || !body || !signature) {
    throw new TokenValidationError();
  }
  const expected = createHmac("sha256", secret())
    .update(tokenPreimage(purpose, body))
    .digest();
  let actual: Buffer;
  try {
    actual = base64urlDecode(signature);
  } catch {
    throw new TokenValidationError();
  }
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
    throw new TokenValidationError();
  }
  let parsed: T & { expiresAt?: number };
  try {
    parsed = JSON.parse(base64urlDecode(body).toString("utf8")) as T & { expiresAt?: number };
  } catch {
    throw new TokenValidationError();
  }
  if (typeof parsed.expiresAt !== "number") {
    throw new TokenValidationError();
  }
  if (Date.now() > parsed.expiresAt) {
    throw new TokenValidationError();
  }
  return parsed as T;
}

function tokenPreimage(purpose: TokenPurpose, body: string) {
  return `${TOKEN_CONTEXT}:${TOKEN_VERSION}:${purpose}:${body}`;
}

export function issueChallengeToken(payload: ChallengeToken) {
  return signToken("challenge", payload);
}

export function readChallengeToken(token: string) {
  const parsed = verifyToken<ChallengeToken>("challenge", token);
  if (
    (parsed.mode !== "register" && parsed.mode !== "authenticate")
    || typeof parsed.challenge !== "string"
    || parsed.challenge.length < 32
    || (parsed.mode === "register" && (!parsed.pendingUserId || !UUID_RE.test(parsed.pendingUserId)))
    || (parsed.mode === "authenticate" && parsed.pendingUserId !== undefined)
  ) {
    throw new TokenValidationError();
  }
  return parsed;
}

export function issueSessionToken(userId: string) {
  if (!UUID_RE.test(userId)) throw new Error("Invalid session user id.");
  // Deliberately short-lived and stateless: the single-instance sync service
  // has no long-lived refresh tokens or server-side login sessions. Account
  // deletion removes all vault data, and rotating SYNC_SESSION_SECRET remains
  // the emergency mechanism for invalidating every outstanding bearer.
  return signToken<SessionToken>("session", {
    userId,
    expiresAt: Date.now() + 1000 * 60 * 60 * 12
  });
}

export function readBearerToken(header: string | null) {
  const match = header?.match(/^Bearer\s+(.+)$/i);
  if (!match || match[1].length > 4_096) throw new TokenValidationError();
  const parsed = verifyToken<SessionToken>("session", match[1]);
  if (!UUID_RE.test(parsed.userId)) throw new TokenValidationError();
  return parsed;
}
