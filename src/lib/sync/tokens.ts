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

type TokenPurpose = "challenge" | "session";

export class TokenValidationError extends Error {
  constructor(message = "Invalid or expired token.") {
    super(message);
    this.name = "TokenValidationError";
  }
}

export class TokenConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "TokenConfigurationError";
  }
}

const TOKEN_VERSION = "v1";
const TOKEN_CONTEXT = "address-atlas-sync";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const PLACEHOLDER_RE = /(replace[-_ ]?with|change[-_ ]?me|example|your[-_ ]?secret|password)/i;

export function validateSessionSecret(value: string | undefined) {
  const configured = value?.trim();
  if (!configured) {
    throw new TokenConfigurationError("SYNC_SESSION_SECRET is required.");
  }
  if (Buffer.byteLength(configured, "utf8") < 32) {
    throw new TokenConfigurationError("SYNC_SESSION_SECRET must contain at least 32 bytes.");
  }
  if (PLACEHOLDER_RE.test(configured) || /^(.)(\1)+$/.test(configured)) {
    throw new TokenConfigurationError("SYNC_SESSION_SECRET must be a random, non-placeholder value.");
  }
  return configured;
}

function secret() {
  const configured = process.env.SYNC_SESSION_SECRET?.trim();
  return validateSessionSecret(configured);
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
