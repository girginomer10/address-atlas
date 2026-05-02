import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  createManualHolding,
  deleteManualHolding,
  listEnabledManualHoldings,
  listManualHoldings,
  manualHoldingToTrackedAsset,
  updateManualHolding
} from "./manual-exchanges";
import { latestScanResponse } from "./local-store";
import { clearTestDatabase } from "./test-db";

describe("manual exchange holdings", () => {
  beforeEach(async () => {
    await clearTestDatabase();
  });

  afterEach(async () => {
    await clearTestDatabase();
  });

  it("persists a binance entry derived from price and amount", async () => {
    const created = await createManualHolding({
      label: "Binance spot",
      provider: "binance",
      symbol: "btc",
      name: "Bitcoin",
      amount: "0.5",
      priceUsd: "60000"
    });

    expect(created).toMatchObject({
      label: "Binance spot",
      provider: "binance",
      providerLabel: "Binance",
      symbol: "BTC",
      amount: 0.5,
      priceUsd: 60000,
      valueUsd: 30000,
      enabled: true
    });

    const listed = await listManualHoldings();
    expect(listed).toHaveLength(1);
    expect(listed[0].id).toBe(created.id);
  });

  it("requires a custom venue when provider is custom and rejects secrets", async () => {
    await expect(
      createManualHolding({
        label: "OTC",
        provider: "custom",
        symbol: "USD",
        amount: "1",
        valueUsd: "1"
      })
    ).rejects.toThrow(/custom venue/i);

    await expect(
      createManualHolding({
        label: "Binance",
        provider: "binance",
        symbol: "BTC",
        amount: "1",
        valueUsd: "1",
        notes: "private key abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"
      })
    ).rejects.toThrow(/secrets/i);
  });

  it("requires a price or value", async () => {
    await expect(
      createManualHolding({
        label: "Kraken",
        provider: "kraken",
        symbol: "ETH",
        amount: "1"
      })
    ).rejects.toThrow(/price|value/i);
  });

  it("updates enabled state and recomputes value when amount and price change", async () => {
    const created = await createManualHolding({
      label: "Coinbase",
      provider: "coinbase",
      symbol: "ETH",
      amount: "2",
      priceUsd: "2000"
    });
    expect(created.valueUsd).toBe(4000);

    const disabled = await updateManualHolding(created.id, { enabled: false });
    expect(disabled.enabled).toBe(false);

    const enabledHoldings = await listEnabledManualHoldings();
    expect(enabledHoldings).toHaveLength(0);

    const updated = await updateManualHolding(created.id, {
      enabled: true,
      amount: "3",
      priceUsd: "2500"
    });
    expect(updated.amount).toBe(3);
    expect(updated.priceUsd).toBe(2500);
    expect(updated.valueUsd).toBe(7500);
  });

  it("deletes manual entries", async () => {
    const created = await createManualHolding({
      label: "Custom OTC",
      provider: "custom",
      customVenue: "Local OTC desk",
      symbol: "USDT",
      amount: "1000",
      valueUsd: "1000"
    });
    expect(created.providerLabel).toBe("Local OTC desk");

    await deleteManualHolding(created.id);
    expect(await listManualHoldings()).toHaveLength(0);
  });

  it("converts an enabled entry into an exchange-source TrackedAsset", async () => {
    const holding = await createManualHolding({
      label: "Binance offline ledger",
      provider: "binance",
      symbol: "SOL",
      name: "Solana",
      amount: "10",
      valueUsd: "1500"
    });

    const asset = manualHoldingToTrackedAsset(holding);
    expect(asset).toMatchObject({
      source: "exchange",
      family: "exchange",
      chainName: "Binance",
      chainId: "manual-binance",
      symbol: "SOL",
      name: "Solana",
      amount: 10,
      valueUsd: 1500,
      walletLabel: "Binance offline ledger",
      exchangeProvider: "binance"
    });
    expect(asset.priceUsd).toBeCloseTo(150);
  });

  it("merges enabled manual entries into the latest scan response even with no scan run", async () => {
    await createManualHolding({
      label: "Kraken main",
      provider: "kraken",
      symbol: "ADA",
      amount: "1000",
      priceUsd: "0.4"
    });

    const latest = await latestScanResponse();
    expect(latest).not.toBeNull();
    expect(latest?.assets).toHaveLength(1);
    expect(latest?.assets[0]).toMatchObject({
      source: "exchange",
      symbol: "ADA",
      valueUsd: 400
    });
    expect(latest?.summary.totalUsd).toBe(400);
    expect(latest?.sources?.[0].kind).toBe("exchange");
    expect(latest?.sources?.[0].id.startsWith("manual:")).toBe(true);
  });
});
