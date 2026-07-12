import { createHash } from "node:crypto";
import { base64urlDecode } from "./base64url";

export interface EncryptedVaultEnvelope {
  schemaVersion: number;
  cryptoVersion: number;
  keyId: string;
  nonce: string;
  ciphertext: string;
  checksum: string;
  createdAt?: string;
}

export interface RemoteVaultSnapshot {
  version: number;
  envelope: EncryptedVaultEnvelope;
  byteSize: number;
  checksum: string;
  updatedAt?: string;
}

const BASE64URL_RE = /^[A-Za-z0-9_-]+$/;
const HEX_RE = /^[a-f0-9]{64}$/i;
const KEY_ID_RE = /^[A-Za-z0-9._:-]+$/;

// Hard ceiling on a single encrypted snapshot. A vault holds wallet metadata,
// not blobs, so even a large portfolio is well under this. Bounds memory/storage
// per request (paired with the proxy's request_body max_size).
export const MAX_ENVELOPE_BYTES = 8_000_000;
export const MAX_SNAPSHOT_REQUEST_BYTES = MAX_ENVELOPE_BYTES + 100_000;
// Postgres `version` column is a 32-bit signed integer; stay clear of its max so
// an oversized version is a clean 400 rather than a raw "integer out of range".
const MAX_VERSION = 2_000_000_000;

export function assertRemoteVaultSnapshot(input: unknown): asserts input is RemoteVaultSnapshot {
  if (!input || typeof input !== "object") throw new Error("Snapshot body is required.");
  const snapshot = input as Partial<RemoteVaultSnapshot>;
  if (!Number.isInteger(snapshot.version) || (snapshot.version as number) < 1 || (snapshot.version as number) > MAX_VERSION) {
    throw new Error("Snapshot version is out of range.");
  }
  if (!Number.isInteger(snapshot.byteSize) || (snapshot.byteSize as number) < 1 || (snapshot.byteSize as number) > MAX_ENVELOPE_BYTES) {
    throw new Error("Snapshot byteSize is out of range.");
  }
  if (typeof snapshot.checksum !== "string" || !HEX_RE.test(snapshot.checksum)) {
    throw new Error("Snapshot checksum must be a SHA-256 hex digest.");
  }
  assertEnvelope(snapshot.envelope);
  const canonical = canonicalEnvelopeBytes(snapshot.envelope);
  if (canonical.byteLength !== snapshot.byteSize) {
    throw new Error("Snapshot byteSize does not match the encrypted envelope.");
  }
  const expectedSnapshotChecksum = computeSnapshotChecksum(snapshot.version as number, snapshot.envelope, canonical);
  if (expectedSnapshotChecksum !== snapshot.checksum.toLowerCase()) {
    throw new Error("Snapshot checksum does not match the encrypted envelope.");
  }
  if (snapshot.updatedAt !== undefined && !isISODate(snapshot.updatedAt)) {
    throw new Error("Invalid snapshot updatedAt.");
  }
}

function assertEnvelope(envelope: unknown): asserts envelope is EncryptedVaultEnvelope {
  if (!envelope || typeof envelope !== "object") throw new Error("Encrypted envelope is required.");
  const value = envelope as Partial<EncryptedVaultEnvelope>;
  const isSupportedVersion = (value.schemaVersion === 1 && value.cryptoVersion === 1)
    || (value.schemaVersion === 2 && value.cryptoVersion === 2);
  if (!isSupportedVersion) throw new Error("Unsupported or mismatched envelope version.");
  if (
    typeof value.keyId !== "string"
    || value.keyId.length < 3
    || value.keyId.length > 80
    || !KEY_ID_RE.test(value.keyId)
  ) {
    throw new Error("Invalid keyId.");
  }
  if (typeof value.nonce !== "string" || !BASE64URL_RE.test(value.nonce)) {
    throw new Error("Invalid nonce.");
  }
  if (typeof value.ciphertext !== "string" || !BASE64URL_RE.test(value.ciphertext) || value.ciphertext.length > MAX_ENVELOPE_BYTES) {
    throw new Error("Invalid ciphertext.");
  }
  if (typeof value.checksum !== "string" || !HEX_RE.test(value.checksum)) {
    throw new Error("Invalid envelope checksum.");
  }
  if (value.createdAt !== undefined && !isISODate(value.createdAt)) {
    throw new Error("Invalid envelope createdAt.");
  }
  let nonce: Buffer;
  let ciphertext: Buffer;
  try {
    nonce = base64urlDecode(value.nonce);
    ciphertext = base64urlDecode(value.ciphertext);
  } catch {
    throw new Error("Envelope contains invalid base64url data.");
  }
  if (nonce.byteLength !== 12) throw new Error("Envelope nonce must be exactly 12 bytes.");
  if (ciphertext.byteLength <= 16) throw new Error("Envelope ciphertext must contain data and an authentication tag.");
}

export function assertEnvelopeChecksum(envelope: EncryptedVaultEnvelope) {
  const preimage = Buffer.concat([
    Buffer.from(`schema:${envelope.schemaVersion}|crypto:${envelope.cryptoVersion}|key:${envelope.keyId}|`, "utf8"),
    base64urlDecode(envelope.nonce),
    base64urlDecode(envelope.ciphertext)
  ]);
  const expected = createHash("sha256").update(preimage).digest("hex");
  if (expected !== envelope.checksum) {
    throw new Error("Envelope checksum does not match ciphertext.");
  }
}

/** Match Swift JSONEncoder.addressAtlas (`sortedKeys`) for outer integrity. */
export function canonicalEnvelopeBytes(envelope: EncryptedVaultEnvelope) {
  const sortedEnvelope: Record<string, string | number> = {
    checksum: envelope.checksum.toLowerCase(),
    ciphertext: envelope.ciphertext
  };
  if (envelope.createdAt !== undefined) sortedEnvelope.createdAt = envelope.createdAt;
  sortedEnvelope.cryptoVersion = envelope.cryptoVersion;
  sortedEnvelope.keyId = envelope.keyId;
  sortedEnvelope.nonce = envelope.nonce;
  sortedEnvelope.schemaVersion = envelope.schemaVersion;
  return Buffer.from(JSON.stringify(sortedEnvelope), "utf8");
}

export function computeSnapshotChecksum(
  version: number,
  envelope: EncryptedVaultEnvelope,
  canonical = canonicalEnvelopeBytes(envelope)
) {
  if (envelope.schemaVersion === 1) {
    return createHash("sha256").update(canonical).digest("hex");
  }
  const versionBytes = Buffer.alloc(8);
  const byteSizeBytes = Buffer.alloc(8);
  versionBytes.writeBigUInt64BE(BigInt(version));
  byteSizeBytes.writeBigUInt64BE(BigInt(canonical.byteLength));
  return createHash("sha256")
    .update(Buffer.from("address-atlas:sync-snapshot:v2", "utf8"))
    .update(versionBytes)
    .update(byteSizeBytes)
    .update(canonical)
    .digest("hex");
}

function isISODate(value: unknown): value is string {
  return typeof value === "string"
    && value.length >= 20
    && value.length <= 40
    && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/.test(value)
    && Number.isFinite(Date.parse(value));
}

const ALLOWED_SNAPSHOT_KEYS = new Set(["version", "envelope", "byteSize", "checksum", "updatedAt"]);
const ALLOWED_ENVELOPE_KEYS = new Set([
  "schemaVersion",
  "cryptoVersion",
  "keyId",
  "nonce",
  "ciphertext",
  "checksum",
  "createdAt"
]);

// The previous implementation scanned the serialized body for substrings like
// "secret"/"api_key". That was security theater against an opaque AES-GCM
// ciphertext and produced false-positive 400s whose odds grew with vault size
// (base64url can randomly contain those letters). Instead, enforce that the
// snapshot and envelope carry ONLY their known keys — any unexpected field
// (where a plaintext leak would actually live) is rejected, with no false
// positives on the opaque ciphertext.
export function assertNoPlaintextLeak(snapshot: RemoteVaultSnapshot) {
  for (const key of Object.keys(snapshot)) {
    if (!ALLOWED_SNAPSHOT_KEYS.has(key)) {
      throw new Error(`Snapshot contains an unexpected field: ${key}`);
    }
  }
  for (const key of Object.keys(snapshot.envelope)) {
    if (!ALLOWED_ENVELOPE_KEYS.has(key)) {
      throw new Error(`Envelope contains an unexpected field: ${key}`);
    }
  }
}
