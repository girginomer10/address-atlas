import { NextRequest } from "next/server";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { POST as scanPost } from "@/app/api/scan/route";
import { prisma } from "./db";
import {
  clampHistoryLimit,
  latestScanResponse,
  listScanRunHistory,
  saveScanResponse,
  SCAN_HISTORY_DEFAULT_LIMIT,
  SCAN_HISTORY_MAX_LIMIT,
  upsertWallets
} from "./local-store";
import { clearTestDatabase } from "./test-db";
import { ScanResponse, TrackedAsset } from "./types";

const EVM_ADDRESS = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";

describe("local scan persistence", () => {
  beforeEach(async () => {
    await clearTestDatabase();
  });

  afterEach(async () => {
    await clearTestDatabase();
  });

  it("does not keep deleted wallet holdings in the latest response", async () => {
    const [wallet] = await upsertWallets([EVM_ADDRESS]);
    await saveScanResponse(scanWithAssets([trackedAsset(EVM_ADDRESS)]));

    await prisma.walletAddress.delete({ where: { id: wallet.id } });

    const latest = await latestScanResponse();
    expect(latest?.assets).toHaveLength(0);
    expect(latest?.summary.assetCount).toBe(0);
    expect(latest?.sources).toHaveLength(0);
  });

  it("rolls back the scan run when snapshot persistence fails", async () => {
    await expect(
      saveScanResponse({
        ...scanWithAssets([]),
        exchangeSnapshots: [
          {
            connectionId: "missing-connection",
            provider: "binance",
            label: "Missing exchange",
            generatedAt: new Date().toISOString(),
            totalUsd: 0,
            status: "ok",
            holdings: []
          }
        ]
      })
    ).rejects.toThrow();

    expect(await prisma.scanRun.count()).toBe(0);
  });

  it("rejects unsupported scan input without saving it as a wallet", async () => {
    const response = await scanPost(
      new NextRequest("http://localhost/api/scan", {
        method: "POST",
        headers: {
          "content-type": "application/json"
        },
        body: JSON.stringify({ addresses: "not-a-wallet" })
      })
    );
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.warnings).toEqual(["Unsupported address skipped: not-a-wallet."]);
    expect(await prisma.walletAddress.count()).toBe(0);
  });
});

describe("scan run history", () => {
  beforeEach(async () => {
    await clearTestDatabase();
  });

  afterEach(async () => {
    await clearTestDatabase();
  });

  it("returns recent runs newest-first with the asked limit", async () => {
    await upsertWallets([EVM_ADDRESS]);
    const baseline = new Date("2026-04-30T10:00:00.000Z").getTime();
    for (let index = 0; index < 4; index += 1) {
      await saveScanResponse(
        scanWithAssets(
          [trackedAsset(EVM_ADDRESS, { valueUsd: 1000 + index })],
          new Date(baseline + index * 60_000).toISOString()
        )
      );
    }

    const history = await listScanRunHistory(2);

    expect(history).toHaveLength(2);
    expect(history[0].generatedAt > history[1].generatedAt).toBe(true);
    expect(history[0].totalUsd).toBe(1003);
    expect(history[1].totalUsd).toBe(1002);
  });

  it("preserves snapshot-time totals after wallets are deleted", async () => {
    const [wallet] = await upsertWallets([EVM_ADDRESS]);
    await saveScanResponse(
      scanWithAssets([trackedAsset(EVM_ADDRESS, { valueUsd: 1500 })])
    );
    await prisma.walletAddress.delete({ where: { id: wallet.id } });

    const history = await listScanRunHistory();

    expect(history).toHaveLength(1);
    expect(history[0].totalUsd).toBe(1500);
    expect(history[0].assetCount).toBe(1);
    expect(history[0].chainCount).toBe(1);
    expect(history[0].topChains).toEqual([{ name: "Ethereum", valueUsd: 1500 }]);
  });

  it("aggregates top chains across multiple holdings", async () => {
    await upsertWallets([EVM_ADDRESS]);
    await saveScanResponse(
      scanWithAssets([
        trackedAsset(EVM_ADDRESS, { symbol: "ETH", chainName: "Ethereum", chainId: "ethereum", valueUsd: 800 }),
        trackedAsset(EVM_ADDRESS, { symbol: "USDC", chainName: "Ethereum", chainId: "ethereum", valueUsd: 200 }),
        trackedAsset(EVM_ADDRESS, { symbol: "MATIC", chainName: "Polygon", chainId: "polygon", valueUsd: 150 }),
        trackedAsset(EVM_ADDRESS, { symbol: "OP", chainName: "Optimism", chainId: "optimism", valueUsd: 50 }),
        trackedAsset(EVM_ADDRESS, { symbol: "ARB", chainName: "Arbitrum", chainId: "arbitrum", valueUsd: 25 })
      ])
    );

    const [entry] = await listScanRunHistory();

    expect(entry.topChains.map((chain) => chain.name)).toEqual(["Ethereum", "Polygon", "Optimism"]);
    expect(entry.topChains[0].valueUsd).toBe(1000);
    expect(entry.assetCount).toBe(5);
    expect(entry.chainCount).toBe(4);
  });

  it("derives warning and source counts from the stored JSON blobs", async () => {
    await upsertWallets([EVM_ADDRESS]);
    const scan = scanWithAssets([trackedAsset(EVM_ADDRESS)]);
    scan.warnings = ["Skipped one address.", "RPC slow."];
    scan.sources = [
      { id: EVM_ADDRESS, label: EVM_ADDRESS, kind: "onchain", status: "ok" },
      { id: "binance-1", label: "Binance main", kind: "exchange", status: "ok" }
    ];
    await saveScanResponse(scan);

    const [entry] = await listScanRunHistory();

    expect(entry.warningCount).toBe(2);
    expect(entry.sourceCount).toBe(2);
    expect(entry.inputCount).toBe(scan.inputCount);
  });

  it("returns an empty list when no scans have been run", async () => {
    expect(await listScanRunHistory()).toEqual([]);
  });

  it("clamps history limits within the supported range", () => {
    expect(clampHistoryLimit(0)).toBe(SCAN_HISTORY_DEFAULT_LIMIT);
    expect(clampHistoryLimit(-5)).toBe(SCAN_HISTORY_DEFAULT_LIMIT);
    expect(clampHistoryLimit(Number.NaN)).toBe(SCAN_HISTORY_DEFAULT_LIMIT);
    expect(clampHistoryLimit(7)).toBe(7);
    expect(clampHistoryLimit(999)).toBe(SCAN_HISTORY_MAX_LIMIT);
  });
});

function scanWithAssets(assets: TrackedAsset[], generatedAt = new Date().toISOString()): ScanResponse {
  return {
    generatedAt,
    inputCount: assets.length > 0 ? 1 : 0,
    addresses: assets.length > 0
      ? [
          {
            address: EVM_ADDRESS,
            detectedChains: ["ethereum"],
            assets,
            warnings: [],
            errors: []
          }
        ]
      : [],
    assets,
    summary: {
      totalUsd: assets.reduce((sum, asset) => sum + asset.valueUsd, 0),
      addressCount: assets.length > 0 ? 1 : 0,
      chainCount: new Set(assets.map((asset) => asset.chainId)).size,
      assetCount: assets.length
    },
    warnings: [],
    sources: assets.length > 0
      ? [
          {
            id: EVM_ADDRESS,
            label: EVM_ADDRESS,
            kind: "onchain",
            status: "ok"
          }
        ]
      : []
  };
}

function trackedAsset(address: string, overrides: Partial<TrackedAsset> = {}): TrackedAsset {
  const symbol = overrides.symbol ?? "ETH";
  const chainId = overrides.chainId ?? "ethereum";
  return {
    id: `${address}-${chainId}-${symbol}-native`,
    address,
    chainId,
    chainName: "Ethereum",
    family: "evm",
    symbol,
    name: "Ethereum",
    amount: 1,
    priceUsd: 1000,
    valueUsd: 1000,
    explorerUrl: `https://etherscan.io/address/${address}`,
    source: "native",
    status: "ok",
    ...overrides
  };
}
