import { describe, expect, it } from "vitest";
import { assertNoPlaintextLeak, assertRemoteVaultSnapshot, RemoteVaultSnapshot } from "./envelope";

const SNAPSHOT: RemoteVaultSnapshot = {
  version: 1,
  byteSize: 128,
  checksum: "a".repeat(64),
  envelope: {
    schemaVersion: 1,
    cryptoVersion: 1,
    keyId: "sync-v1",
    nonce: "abc123_-",
    ciphertext: "deadbeef_-",
    checksum: "b".repeat(64)
  }
};

describe("encrypted sync envelope validation", () => {
  it("accepts opaque encrypted vault snapshots", () => {
    expect(() => assertRemoteVaultSnapshot(SNAPSHOT)).not.toThrow();
    expect(() => assertNoPlaintextLeak(SNAPSHOT)).not.toThrow();
  });

  it("rejects snapshots that smuggle extra (potentially plaintext) fields", () => {
    const leaked = {
      ...SNAPSHOT,
      walletAddress: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
    };

    expect(() => assertNoPlaintextLeak(leaked as unknown as RemoteVaultSnapshot)).toThrow(/unexpected field/i);
  });

  it("rejects malformed metadata", () => {
    expect(() => assertRemoteVaultSnapshot({ ...SNAPSHOT, checksum: "not-a-checksum" })).toThrow(/checksum/i);
  });
});
