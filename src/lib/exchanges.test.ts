import { describe, expect, it } from "vitest";
import { normalizeExchangeBalance } from "./exchanges";

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
