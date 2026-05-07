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

export function assertRemoteVaultSnapshot(input: unknown): asserts input is RemoteVaultSnapshot {
  if (!input || typeof input !== "object") throw new Error("Snapshot body is required.");
  const snapshot = input as Partial<RemoteVaultSnapshot>;
  if (!Number.isInteger(snapshot.version) || (snapshot.version as number) < 1) {
    throw new Error("Snapshot version must be a positive integer.");
  }
  if (!Number.isInteger(snapshot.byteSize) || (snapshot.byteSize as number) < 1) {
    throw new Error("Snapshot byteSize must be a positive integer.");
  }
  if (typeof snapshot.checksum !== "string" || !HEX_RE.test(snapshot.checksum)) {
    throw new Error("Snapshot checksum must be a SHA-256 hex digest.");
  }
  assertEnvelope(snapshot.envelope);
}

function assertEnvelope(envelope: unknown): asserts envelope is EncryptedVaultEnvelope {
  if (!envelope || typeof envelope !== "object") throw new Error("Encrypted envelope is required.");
  const value = envelope as Partial<EncryptedVaultEnvelope>;
  if (value.schemaVersion !== 1) throw new Error("Unsupported schemaVersion.");
  if (value.cryptoVersion !== 1) throw new Error("Unsupported cryptoVersion.");
  if (typeof value.keyId !== "string" || value.keyId.length < 3 || value.keyId.length > 80) {
    throw new Error("Invalid keyId.");
  }
  if (typeof value.nonce !== "string" || !BASE64URL_RE.test(value.nonce)) {
    throw new Error("Invalid nonce.");
  }
  if (typeof value.ciphertext !== "string" || !BASE64URL_RE.test(value.ciphertext)) {
    throw new Error("Invalid ciphertext.");
  }
  if (typeof value.checksum !== "string" || !HEX_RE.test(value.checksum)) {
    throw new Error("Invalid envelope checksum.");
  }
}

export function assertNoPlaintextLeak(snapshot: RemoteVaultSnapshot) {
  const serialized = JSON.stringify(snapshot).toLowerCase();
  const forbidden = [
    "walletaddress",
    "encryptedcredentials",
    "private key",
    "mnemonic",
    "seed phrase",
    "api_key",
    "secret"
  ];
  if (forbidden.some((needle) => serialized.includes(needle))) {
    throw new Error("Snapshot metadata must not contain plaintext vault fields.");
  }
}
