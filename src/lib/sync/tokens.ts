import { createHmac, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { base64urlDecode, base64urlEncode } from "./base64url";
import { getSyncSessionSecret } from "./config";

export interface ChallengeToken {
  mode: "register" | "authenticate";
  challenge: string;
  pendingUserId?: string;
  expiresAt: number;
}

export interface SessionToken {
  userId: string;
  sessionId: string;
  issuedAt: number;
  expiresAt: number;
}

export interface NativeAuthorizationCode {
  userId: string;
  sessionId: string;
  issuedAt: number;
  codeChallenge: string;
  nonce: string;
  expiresAt: number;
}

type TokenPurpose = "challenge" | "session" | "native-authorization";

export class TokenValidationError extends Error {
  constructor(message = "Invalid or expired token.") {
    super(message);
    this.name = "TokenValidationError";
  }
}

const TOKEN_VERSION = "v1";
const TOKEN_CONTEXT = "address-atlas-sync";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export const SESSION_TTL_MS = 1000 * 60 * 60 * 12;
export const NATIVE_AUTHORIZATION_CODE_TTL_MS = 2 * 60_000;
const CANONICAL_32_BYTE_BASE64URL_RE = /^[A-Za-z0-9_-]{43}$/;

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

export function issueSessionToken(userId: string, sessionId: string = randomUUID(), issuedAt = Date.now()) {
  if (!UUID_RE.test(userId)) throw new Error("Invalid session user id.");
  if (!UUID_RE.test(sessionId)) throw new Error("Invalid session id.");
  if (!Number.isSafeInteger(issuedAt) || issuedAt < 0) throw new Error("Invalid session issue time.");
  return signToken<SessionToken>("session", {
    userId,
    sessionId,
    issuedAt,
    expiresAt: issuedAt + SESSION_TTL_MS
  });
}

export function readSessionToken(token: string) {
  if (!token || token.length > 4_096) throw new TokenValidationError();
  const parsed = verifyToken<SessionToken>("session", token);
  if (
    !UUID_RE.test(parsed.userId)
    || !UUID_RE.test(parsed.sessionId)
    || !Number.isSafeInteger(parsed.issuedAt)
    || !Number.isSafeInteger(parsed.expiresAt)
    || parsed.issuedAt > Date.now() + 30_000
    || parsed.expiresAt <= parsed.issuedAt
    || parsed.expiresAt - parsed.issuedAt > SESSION_TTL_MS
  ) {
    throw new TokenValidationError();
  }
  return parsed;
}

export function readBearerToken(header: string | null) {
  const match = header?.match(/^Bearer\s+(.+)$/i);
  if (!match) throw new TokenValidationError();
  return readSessionToken(match[1]);
}

export function issueNativeAuthorizationCode(
  session: SessionToken,
  codeChallenge: string,
  issuedAt = Date.now()
) {
  if (!isCanonical32ByteBase64url(codeChallenge)) {
    throw new Error("Invalid native authorization code challenge.");
  }
  if (!Number.isSafeInteger(issuedAt) || issuedAt < 0) {
    throw new Error("Invalid native authorization issue time.");
  }
  if (session.expiresAt <= issuedAt) {
    throw new Error("Cannot authorize an expired session grant.");
  }
  return signToken<NativeAuthorizationCode>("native-authorization", {
    userId: session.userId,
    sessionId: session.sessionId,
    issuedAt: session.issuedAt,
    codeChallenge,
    nonce: base64urlEncode(randomBytes(32)),
    expiresAt: Math.min(issuedAt + NATIVE_AUTHORIZATION_CODE_TTL_MS, session.expiresAt)
  });
}

export function readNativeAuthorizationCode(code: string) {
  if (!code || code.length > 4_096) throw new TokenValidationError();
  const parsed = verifyToken<NativeAuthorizationCode>("native-authorization", code);
  if (
    !UUID_RE.test(parsed.userId)
    || !UUID_RE.test(parsed.sessionId)
    || !Number.isSafeInteger(parsed.issuedAt)
    || !Number.isSafeInteger(parsed.expiresAt)
    || parsed.issuedAt < 0
    || parsed.issuedAt > Date.now() + 30_000
    || !isCanonical32ByteBase64url(parsed.codeChallenge)
    || !isCanonical32ByteBase64url(parsed.nonce)
    || parsed.expiresAt <= parsed.issuedAt
    || parsed.expiresAt > parsed.issuedAt + SESSION_TTL_MS
    || parsed.expiresAt - Date.now() > NATIVE_AUTHORIZATION_CODE_TTL_MS + 30_000
  ) {
    throw new TokenValidationError();
  }
  return parsed;
}

export function isCanonical32ByteBase64url(value: unknown): value is string {
  if (typeof value !== "string" || !CANONICAL_32_BYTE_BASE64URL_RE.test(value)) return false;
  try {
    const decoded = base64urlDecode(value);
    return decoded.byteLength === 32 && base64urlEncode(decoded) === value;
  } catch {
    return false;
  }
}
