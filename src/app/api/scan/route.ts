import { NextRequest, NextResponse } from "next/server";
import { parseAddressInput, scanAddresses } from "@/lib/scanner";
import { assertSafePublicAddresses } from "@/lib/address-utils";
import { fetchExchangeSnapshot } from "@/lib/exchanges";
import {
  latestScanResponse,
  saveScanResponse,
  upsertWallets,
  walletAddressesByIds
} from "@/lib/local-store";
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

    if (addresses.length === 0 && !body.includeExchanges) {
      return NextResponse.json(
        { error: "At least one wallet address or exchange connection is required." },
        { status: 400 }
      );
    }

    if (addresses.length > 0) {
      await upsertWallets(addresses);
    }

    const onchain = addresses.length > 0 ? await scanAddresses(addresses) : emptyScan();
    const exchangeSnapshots = body.includeExchanges
      ? await scanExchangeConnections(body.vaultPassphrase)
      : [];
    const assets = [...onchain.assets, ...exchangeSnapshots.flatMap((snapshot) => snapshot.holdings)];
    const warnings = [
      ...onchain.warnings,
      ...exchangeSnapshots.flatMap((snapshot) => snapshot.error ? [`${snapshot.label}: ${snapshot.error}`] : [])
    ];
    const sources = buildSources(onchain, exchangeSnapshots);

    const result: ScanResponse = {
      ...onchain,
      generatedAt: new Date().toISOString(),
      inputCount: addresses.length,
      assets,
      summary: summarize(addresses.length, assets),
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
