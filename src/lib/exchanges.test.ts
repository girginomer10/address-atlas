import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { fetchExchangeSnapshot, normalizeExchangeBalance } from "./exchanges";
import { encryptForVault } from "./security";
import { clearTestDatabase } from "./test-db";

describe("exchange balance normalization", () => {
  it("converts stablecoin balances into exchange holdings without network pricing", async () => {
    const holdings = await normalizeExchangeBalance({
      id: "cx1",
      provider: "binance",
      label: "Binance main",
      balance: {
        total: {
          USDC: 42,
          EMPTY: 0
        }
      }
    });

    expect(holdings).toHaveLength(1);
    expect(holdings[0]).toMatchObject({
      symbol: "USDC",
      source: "exchange",
      valueUsd: 42
    });
  });
});

describe("exchange snapshot fetching", () => {
  beforeEach(async () => {
    await clearTestDatabase();
  });

  afterEach(async () => {
    await clearTestDatabase();
  });

  it("returns a failed snapshot when credentials cannot be decrypted", async () => {
    const encryptedCredentials = await encryptForVault(
      { apiKey: "key", secret: "secret" },
      "correct-passphrase"
    );

    const snapshot = await fetchExchangeSnapshot(
      {
        id: "cx1",
        provider: "binance",
        label: "Binance main",
        encryptedCredentials
      },
      "wrong-passphrase"
    );

    expect(snapshot).toMatchObject({
      connectionId: "cx1",
      provider: "binance",
      status: "failed",
      holdings: []
    });
    expect(snapshot.error).toMatch(/passphrase/i);
  });
});
