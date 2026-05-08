import { describe, expect, it } from "vitest";
import { isSyncOnlyPathAllowed } from "./sync-only";

describe("sync-only route allowlist", () => {
  it("allows only native auth, passkey, vault, health, and Next assets", () => {
    expect(isSyncOnlyPathAllowed("/auth/native")).toBe(true);
    expect(isSyncOnlyPathAllowed("/auth/passkey/options")).toBe(true);
    expect(isSyncOnlyPathAllowed("/auth/passkey/verify")).toBe(true);
    expect(isSyncOnlyPathAllowed("/config/native")).toBe(true);
    expect(isSyncOnlyPathAllowed("/vault/latest")).toBe(true);
    expect(isSyncOnlyPathAllowed("/healthz")).toBe(true);
    expect(isSyncOnlyPathAllowed("/_next/static/chunk.js")).toBe(true);

    expect(isSyncOnlyPathAllowed("/")).toBe(false);
    expect(isSyncOnlyPathAllowed("/api/wallets")).toBe(false);
    expect(isSyncOnlyPathAllowed("/settings")).toBe(false);
    expect(isSyncOnlyPathAllowed("/api/scan")).toBe(false);
  });
});
