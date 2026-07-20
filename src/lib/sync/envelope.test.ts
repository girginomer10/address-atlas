import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { base64urlEncode } from "./base64url";
import {
  assertEnvelopeChecksum,
  assertNoPlaintextLeak,
  assertRemoteVaultSnapshot,
  canonicalEnvelopeBytes,
  computeSnapshotChecksum,
  type EncryptedVaultEnvelope,
  type RemoteVaultSnapshot
} from "./envelope";

function snapshot(schemaVersion: 1 | 2 = 2, version = 7): RemoteVaultSnapshot {
  const nonce = Buffer.alloc(12, 1);
  const ciphertext = Buffer.alloc(48, 2);
  const keyId = schemaVersion === 2 ? "sync-v2" : "sync-v1";
  const checksum = createHash("sha256")
    .update(Buffer.from(`schema:${schemaVersion}|crypto:${schemaVersion}|key:${keyId}|`))
    .update(nonce)
    .update(ciphertext)
    .digest("hex");
  const envelope: EncryptedVaultEnvelope = {
    schemaVersion,
    cryptoVersion: schemaVersion,
    keyId,
    nonce: base64urlEncode(nonce),
    ciphertext: base64urlEncode(ciphertext),
    checksum,
    createdAt: "2026-07-12T12:00:00Z"
  };
  const canonical = canonicalEnvelopeBytes(envelope);
  return {
    version,
    envelope,
    byteSize: canonical.byteLength,
    checksum: computeSnapshotChecksum(version, envelope, canonical)
  };
}

function snapshotAt(createdAt: string): RemoteVaultSnapshot {
  const value = snapshot(2);
  const envelope = { ...value.envelope, createdAt };
  const canonical = canonicalEnvelopeBytes(envelope);
  return {
    ...value,
    envelope,
    byteSize: canonical.byteLength,
    checksum: computeSnapshotChecksum(value.version, envelope, canonical)
  };
}

describe("encrypted sync envelope validation", () => {
  it.each([1, 2] as const)("accepts a canonical sync-v%s encrypted snapshot", (schemaVersion) => {
    const value = snapshot(schemaVersion);
    expect(() => assertRemoteVaultSnapshot(value)).not.toThrow();
    expect(() => assertEnvelopeChecksum(value.envelope)).not.toThrow();
    expect(() => assertNoPlaintextLeak(value)).not.toThrow();
  });

  it("binds sync-v2 top-level version and byte size into its checksum", () => {
    const value = snapshot(2);
    expect(() => assertRemoteVaultSnapshot({ ...value, version: value.version + 1 })).toThrow(/checksum/i);
    expect(() => assertRemoteVaultSnapshot({ ...value, byteSize: value.byteSize + 1 })).toThrow(/byteSize/i);
  });

  it("matches the cross-language Swift sync-v2 checksum fixture", () => {
    const value = snapshot(2, 7);
    expect(canonicalEnvelopeBytes(value.envelope).toString("utf8")).toBe(
      "{\"checksum\":\"60b1cfca31587a2af4be1c9070ccdfb9dfcd74edc6c3e43efbebe3a20df7fcda\",\"ciphertext\":\"AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC\",\"createdAt\":\"2026-07-12T12:00:00Z\",\"cryptoVersion\":2,\"keyId\":\"sync-v2\",\"nonce\":\"AQEBAQEBAQEBAQEB\",\"schemaVersion\":2}"
    );
    expect(value.byteSize).toBe(275);
    expect(value.checksum).toBe("cf86567cbc441cef3d7d7c5aa2fb5e80281905ce92c80bd50c63786577187c51");
  });

  it("requires an exact 12-byte canonical nonce and a ciphertext tag", () => {
    const value = snapshot(2);
    expect(() => assertRemoteVaultSnapshot({
      ...value,
      envelope: { ...value.envelope, nonce: base64urlEncode(Buffer.alloc(11)) }
    })).toThrow(/12 bytes/i);
    expect(() => assertRemoteVaultSnapshot({
      ...value,
      envelope: { ...value.envelope, ciphertext: base64urlEncode(Buffer.alloc(16)) }
    })).toThrow(/authentication tag/i);
  });

  it("rejects mismatched schema/crypto versions and smuggled fields", () => {
    const value = snapshot(2);
    expect(() => assertRemoteVaultSnapshot({
      ...value,
      envelope: { ...value.envelope, cryptoVersion: 1 }
    })).toThrow(/mismatched/i);
    expect(() => assertNoPlaintextLeak({ ...value, walletAddress: "0x123" } as RemoteVaultSnapshot)).toThrow(/unexpected field/i);
  });

  it("rejects noncanonical values that the Swift client cannot open", () => {
    const value = snapshot(2);
    expect(() => assertRemoteVaultSnapshot({
      ...value,
      checksum: value.checksum.toUpperCase()
    })).toThrow(/checksum/i);
    expect(() => assertRemoteVaultSnapshot({
      ...value,
      envelope: { ...value.envelope, keyId: "sync-v1" }
    })).toThrow(/keyId/i);
    const missingCreatedAt = {
      ...value,
      envelope: { ...value.envelope, createdAt: undefined }
    };
    expect(() => assertRemoteVaultSnapshot(missingCreatedAt)).toThrow(/createdAt/i);
    expect(() => assertRemoteVaultSnapshot({
      ...value,
      envelope: { ...value.envelope, createdAt: "2026-02-30T12:00:00Z" }
    })).toThrow(/createdAt/i);
    expect(() => assertRemoteVaultSnapshot({
      ...value,
      envelope: { ...value.envelope, createdAt: "2026-07-12T12:00:00.000Z" }
    })).toThrow(/whole-second/i);
  });

  it("matches Swift's canonical whole-second UTC timestamp edge contract", () => {
    // ISO8601DateFormatter and JSONEncoder.addressAtlas preserve year 0000 at
    // whole-second precision, so this unusual but canonical value is safe.
    expect(() => assertRemoteVaultSnapshot(snapshotAt("0000-01-01T00:00:00Z"))).not.toThrow();

    // Swift normalizes 24:00 to the next day, rejects leap seconds, and its
    // canonical encoder emits no fractional seconds. Accepting any of these
    // spellings would make decode/re-encode change the checksum preimage.
    for (const createdAt of [
      "2026-01-01T24:00:00Z",
      "2026-12-31T23:59:60Z",
      "2026-01-01T00:00:00.1234Z"
    ]) {
      expect(() => assertRemoteVaultSnapshot(snapshotAt(createdAt))).toThrow(/createdAt|whole-second/i);
    }
  });
});
