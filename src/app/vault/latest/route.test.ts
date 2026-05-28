import { NextRequest } from "next/server";
import { beforeEach, describe, expect, it, vi } from "vitest";

const { query } = vi.hoisted(() => ({
  query: vi.fn()
}));

vi.mock("@/lib/sync/postgres", () => ({
  ensureSyncSchema: vi.fn(async () => undefined),
  getSyncPool: () => ({ query })
}));

vi.mock("@/lib/sync/tokens", () => ({
  readBearerToken: vi.fn(() => ({ userId: "user-1", expiresAt: Date.now() + 60_000 }))
}));

import { PUT } from "./route";

const SNAPSHOT = {
  version: 1,
  byteSize: 128,
  checksum: "a".repeat(64),
  envelope: {
    schemaVersion: 1,
    cryptoVersion: 1,
    keyId: "sync-v1",
    nonce: "abc123_-",
    ciphertext: "opaqueCiphertext_-",
    // sha256 of the envelope preimage; must satisfy assertEnvelopeChecksum
    checksum: "56aaa5ed2a412cb17c3cc2843ce853ccab8259dbc2a43e4d2c63e7195ad821ab"
  }
};

describe("vault latest route", () => {
  beforeEach(() => {
    query.mockReset();
  });

  it("returns 409 when a stale vault snapshot loses the version race", async () => {
    query.mockResolvedValueOnce({ rowCount: 0 });

    const response = await PUT(
      new NextRequest("http://localhost/vault/latest", {
        method: "PUT",
        headers: {
          authorization: "Bearer token",
          "content-type": "application/json"
        },
        body: JSON.stringify(SNAPSHOT)
      })
    );
    const body = await response.json();

    expect(response.status).toBe(409);
    expect(body.error).toMatch(/newer/i);
    expect(query).toHaveBeenCalledWith(
      expect.stringContaining("vault_snapshots.version < excluded.version"),
      expect.any(Array)
    );
  });
});
