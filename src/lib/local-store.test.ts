import { NextRequest } from "next/server";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { POST as scanPost } from "@/app/api/scan/route";
import { prisma } from "./db";
import { latestScanResponse, saveScanResponse, upsertWallets } from "./local-store";
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

function scanWithAssets(assets: TrackedAsset[]): ScanResponse {
  return {
    generatedAt: new Date().toISOString(),
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

function trackedAsset(address: string): TrackedAsset {
  return {
    id: `${address}-ethereum-ETH-native`,
    address,
    chainId: "ethereum",
    chainName: "Ethereum",
    family: "evm",
    symbol: "ETH",
    name: "Ethereum",
    amount: 1,
    priceUsd: 1000,
    valueUsd: 1000,
    explorerUrl: `https://etherscan.io/address/${address}`,
    source: "native",
    status: "ok"
  };
}
