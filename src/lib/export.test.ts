import { describe, expect, it } from "vitest";
import { assetsToCsv } from "./export";
import { TrackedAsset } from "./types";

describe("portfolio export", () => {
  it("quotes CSV cells that contain commas", () => {
    const asset: TrackedAsset = {
      id: "a1",
      address: "0xabc",
      chainId: "ethereum",
      chainName: "Ethereum",
      family: "evm",
      symbol: "USDC",
      name: "USD Coin, bridged",
      amount: 12,
      priceUsd: 1,
      valueUsd: 12,
      change24h: 0,
      explorerUrl: "https://example.com",
      source: "erc20",
      status: "ok",
      walletLabel: "Main"
    };

    expect(assetsToCsv([asset])).toContain('"USD Coin, bridged"');
  });
});
