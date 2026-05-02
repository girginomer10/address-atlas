import { NextRequest, NextResponse } from "next/server";
import { parseAddressInput, scanAddresses } from "@/lib/scanner";
import { assertSafePublicAddresses, supportedPublicAddresses, unsupportedPublicAddresses } from "@/lib/address-utils";
import { fetchExchangeSnapshot } from "@/lib/exchanges";
import {
  latestScanResponse,
  saveScanResponse,
  upsertWallets,
  walletAddressesByIds
} from "@/lib/local-store";
import {
  listEnabledManualHoldings,
  manualHoldingToTrackedAsset,
  ManualHoldingRecord
} from "@/lib/manual-exchanges";
import { prisma } from "@/lib/db";
import { ExchangeSnapshot, ScanResponse, ScanSource, TrackedAsset } from "@/lib/types";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET() {
  try {
    return NextResponse.json(await latestScanResponse());
  } catch (error) {
    return NextResponse.json(
      {
        error: "Latest scan could not be read.",
        details: error instanceof Error ? error.message : "Unknown error"
      },
      { status: 500 }
    );
  }
}

export async function POST(request: NextRequest) {
  try {
    const body = (await request.json()) as {
      addresses?: string | string[];
      walletIds?: string[];
      includeExchanges?: boolean;
      vaultPassphrase?: string;
    };
    const pastedAddresses = parseAddressInput(body.addresses ?? "");
    const walletIds = Array.isArray(body.walletIds) ? body.walletIds : [];
    const storedWallets = await walletAddressesByIds(walletIds);
    const addresses = parseAddressInput([
      ...pastedAddresses,
      ...storedWallets.map((wallet) => wallet.address)
    ]);

    assertSafePublicAddresses(addresses);
    const supportedAddresses = supportedPublicAddresses(addresses);
    const skippedAddresses = unsupportedPublicAddresses(addresses);
    const skippedWarnings = skippedAddresses.map((address) => `Unsupported address skipped: ${address}.`);

    const manualHoldings = await listEnabledManualHoldings();

    if (supportedAddresses.length === 0 && !body.includeExchanges && manualHoldings.length === 0) {
      return NextResponse.json(
        {
          error: "At least one supported wallet address, exchange connection, or manual entry is required.",
          warnings: skippedWarnings
        },
        { status: 400 }
      );
    }

    if (supportedAddresses.length > 0) {
      await upsertWallets(supportedAddresses);
    }

    const onchain = supportedAddresses.length > 0 ? await scanAddresses(supportedAddresses) : emptyScan();
    const exchangeSnapshots = body.includeExchanges
      ? await scanExchangeConnections(body.vaultPassphrase)
      : [];

    if (supportedAddresses.length === 0 && exchangeSnapshots.length === 0 && manualHoldings.length === 0) {
      return NextResponse.json(
        {
          error: "At least one supported wallet address, exchange connection, or manual entry is required.",
          warnings: skippedWarnings
        },
        { status: 400 }
      );
    }

    const manualAssets = manualHoldings.map(manualHoldingToTrackedAsset);
    const assets = [
      ...onchain.assets,
      ...exchangeSnapshots.flatMap((snapshot) => snapshot.holdings),
      ...manualAssets
    ];
    const warnings = [
      ...skippedWarnings,
      ...onchain.warnings,
      ...exchangeSnapshots.flatMap((snapshot) => snapshot.error ? [`${snapshot.label}: ${snapshot.error}`] : [])
    ];
    const sources = [
      ...buildSources(onchain, exchangeSnapshots),
      ...buildManualSources(manualHoldings)
    ];

    const result: ScanResponse = {
      ...onchain,
      generatedAt: new Date().toISOString(),
      inputCount: supportedAddresses.length,
      assets,
      summary: summarize(supportedAddresses.length, assets),
      warnings,
      sources,
      exchangeSnapshots
    };
    result.scanRunId = await saveScanResponse(result);

    return NextResponse.json(result);
  } catch (error) {
    return NextResponse.json(
      {
        error: "Scan failed.",
        details: error instanceof Error ? error.message : "Unknown error"
      },
      { status: 500 }
    );
  }
}

async function scanExchangeConnections(vaultPassphrase?: string) {
  const connections = await prisma.exchangeConnection.findMany({
    orderBy: {
      createdAt: "asc"
    }
  });

  if (connections.length === 0) return [];

  if (!vaultPassphrase) {
    return connections.map((connection) => ({
      connectionId: connection.id,
      provider: connection.provider as ExchangeSnapshot["provider"],
      label: connection.label,
      generatedAt: new Date().toISOString(),
      totalUsd: 0,
      status: "failed",
      holdings: [],
      error: "Vault passphrase is required to read encrypted exchange keys."
    } satisfies ExchangeSnapshot));
  }

  const snapshots: ExchangeSnapshot[] = [];

  for (const connection of connections) {
    const snapshot = await fetchExchangeSnapshot(connection, vaultPassphrase);
    snapshots.push(snapshot);
    await prisma.exchangeConnection.update({
      where: {
        id: connection.id
      },
      data: {
        status: snapshot.status,
        lastSyncAt: new Date(),
        lastError: snapshot.error ?? null
      }
    });
  }

  return snapshots;
}

function emptyScan(): ScanResponse {
  return {
    generatedAt: new Date().toISOString(),
    inputCount: 0,
    addresses: [],
    assets: [],
    summary: {
      totalUsd: 0,
      addressCount: 0,
      chainCount: 0,
      assetCount: 0
    },
    warnings: []
  };
}

function summarize(addressCount: number, assets: TrackedAsset[]) {
  return {
    totalUsd: assets.reduce((sum, asset) => sum + asset.valueUsd, 0),
    addressCount,
    chainCount: new Set(assets.map((asset) => asset.chainId)).size,
    assetCount: assets.length
  };
}

function buildSources(scan: ScanResponse, exchangeSnapshots: ExchangeSnapshot[]) {
  const onchainSources: ScanSource[] = scan.addresses.map((address) => ({
    id: address.address,
    label: address.address,
    kind: "onchain",
    status: address.errors.length > 0 ? "failed" : "ok",
    message: address.warnings[0] ?? address.errors[0]
  }));
  const exchangeSources: ScanSource[] = exchangeSnapshots.map((snapshot) => ({
    id: snapshot.connectionId,
    label: snapshot.label,
    kind: "exchange",
    status: snapshot.status,
    message: snapshot.error
  }));

  return [...onchainSources, ...exchangeSources];
}

function buildManualSources(holdings: ManualHoldingRecord[]): ScanSource[] {
  return holdings.map((holding) => ({
    id: `manual:${holding.id}`,
    label: `${holding.label} (manual)`,
    kind: "exchange",
    status: "ok"
  }));
}
