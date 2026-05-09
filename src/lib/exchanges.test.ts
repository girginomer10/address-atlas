import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("./prices", () => ({
  getPrices: vi.fn(async (ids: string[]) =>
    Object.fromEntries(ids.map((id) => [
      id,
      {
        usd: id === "zksync" ? 2 : id === "scroll" ? 3 : 1,
        usd_24h_change: 0
      }
    ]))
  )
}));

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

  it("prices newly supported exchange symbols", async () => {
    const holdings = await normalizeExchangeBalance({
      id: "cx1",
      provider: "coinbase",
      label: "Coinbase main",
      balance: {
        total: {
          ZK: 2,
          SCR: 3,
          UNKNOWN: 4
        }
      }
    });
    const bySymbol = Object.fromEntries(holdings.map((holding) => [holding.symbol, holding]));

    expect(bySymbol.ZK.valueUsd).toBe(4);
    expect(bySymbol.SCR.valueUsd).toBe(9);
    expect(bySymbol.UNKNOWN.valueUsd).toBe(0);
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
