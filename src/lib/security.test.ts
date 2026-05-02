import { afterEach, describe, expect, it } from "vitest";
import { containsSensitiveSecret, decryptFromVault, encryptForVault } from "./security";
import { clearTestDatabase } from "./test-db";

describe("vault security", () => {
  afterEach(async () => {
    await clearTestDatabase();
  });

  it("encrypts credentials and rejects the wrong passphrase", async () => {
    const encrypted = await encryptForVault({ apiKey: "key", secret: "secret" }, "local-passphrase");
    await expect(decryptFromVault(encrypted, "wrong-passphrase")).rejects.toThrow("incorrect");
    await expect(decryptFromVault(encrypted, "local-passphrase")).resolves.toEqual({
      apiKey: "key",
      secret: "secret"
    });
  });

  it("flags mnemonic-looking input", () => {
    expect(containsSensitiveSecret("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")).toBe(true);
  });
});
