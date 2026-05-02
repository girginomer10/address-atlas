import { prisma } from "./db";
import { defaultWalletLabel, detectAddressKind } from "./address-utils";
import {
  AddressScan,
  ExchangeSnapshot,
  ScanResponse,
  ScanSource,
  ScanSummary,
  TrackedAsset
} from "./types";

export interface WalletRecord {
  id: string;
  label: string;
  address: string;
  chainKind: string;
  createdAt: string;
  updatedAt: string;
}

export interface PreferenceRecord {
  darkMode: boolean;
  density: "compact" | "comfy";
  mono: boolean;
  hideDust: boolean;
  dustThreshold: number;
  autoRefresh: boolean;
  currency: string;
}

export const DEFAULT_PREFERENCES: PreferenceRecord = {
  darkMode: false,
  density: "comfy",
  mono: false,
  hideDust: false,
  dustThreshold: 5,
  autoRefresh: true,
  currency: "USD"
};

export async function listWallets() {
  const wallets = await prisma.walletAddress.findMany({
    orderBy: {
      createdAt: "asc"
    }
  });
  return wallets.map(serializeWallet);
}

export async function upsertWallets(addresses: string[]) {
  const wallets: WalletRecord[] = [];

  for (const address of addresses) {
    const wallet = await prisma.walletAddress.upsert({
      where: { address },
      create: {
        address,
        label: defaultWalletLabel(address),
        chainKind: detectAddressKind(address)
      },
      update: {
        chainKind: detectAddressKind(address)
      }
    });
    wallets.push(serializeWallet(wallet));
  }

  return wallets;
}

export async function walletAddressesByIds(ids: string[]) {
  if (ids.length === 0) return [];
  return prisma.walletAddress.findMany({
    where: {
      id: {
        in: ids
      }
    }
  });
}

export async function getPreferences() {
  const rows = await prisma.preference.findMany();
  const values = new Map(rows.map((row) => [row.key, row.value]));

  return {
    darkMode: values.get("darkMode") === "true" || DEFAULT_PREFERENCES.darkMode,
    density: values.get("density") === "compact" ? "compact" : DEFAULT_PREFERENCES.density,
    mono: values.get("mono") === "true" || DEFAULT_PREFERENCES.mono,
    hideDust: values.get("hideDust") === "true" || DEFAULT_PREFERENCES.hideDust,
    dustThreshold: Number(values.get("dustThreshold") ?? DEFAULT_PREFERENCES.dustThreshold),
    autoRefresh: values.get("autoRefresh") !== "false",
    currency: values.get("currency") || DEFAULT_PREFERENCES.currency
  } satisfies PreferenceRecord;
}

export async function updatePreferences(input: Partial<PreferenceRecord>) {
  const next = {
    ...(await getPreferences()),
    ...input
  };

  await Promise.all(
    Object.entries(next).map(([key, value]) =>
      prisma.preference.upsert({
        where: { key },
        create: {
          key,
          value: String(value)
        },
        update: {
          value: String(value)
        }
      })
    )
  );

  return next;
}

export async function saveScanResponse(scan: ScanResponse) {
  const summaryJson = JSON.stringify(scan.summary);
  const warningsJson = JSON.stringify(scan.warnings);
  const sourcesJson = JSON.stringify(scan.sources ?? []);

  const run = await prisma.scanRun.create({
    data: {
      generatedAt: new Date(scan.generatedAt),
      totalUsd: scan.summary.totalUsd,
      inputCount: scan.inputCount,
      summaryJson,
      warningsJson,
      sourcesJson
    }
  });

  const wallets = await prisma.walletAddress.findMany();
  const walletByAddress = new Map(wallets.map((wallet) => [wallet.address.toLowerCase(), wallet.id]));

  for (const asset of scan.assets.filter((item) => item.source !== "exchange")) {
    await prisma.holding.create({
      data: holdingData(asset, run.id, walletByAddress.get(asset.address.toLowerCase()))
    });
  }

  for (const snapshot of scan.exchangeSnapshots ?? []) {
    const storedSnapshot = await prisma.exchangeSnapshot.create({
      data: {
        connectionId: snapshot.connectionId,
        scanRunId: run.id,
        provider: snapshot.provider,
        label: snapshot.label,
        generatedAt: new Date(snapshot.generatedAt),
        totalUsd: snapshot.totalUsd,
        status: snapshot.status,
        rawSummaryJson: JSON.stringify({
          error: snapshot.error,
          holdingCount: snapshot.holdings.length
        })
      }
    });

    for (const holding of snapshot.holdings) {
      await prisma.holding.create({
        data: holdingData(holding, run.id, undefined, storedSnapshot.id)
      });
    }
  }

  return run.id;
}

export async function latestScanResponse(): Promise<ScanResponse | null> {
  const run = await prisma.scanRun.findFirst({
    orderBy: {
      generatedAt: "desc"
    },
    include: {
      holdings: true,
      exchangeSnapshots: {
        include: {
          holdings: true
        }
      }
    }
  });

  if (!run) return null;

  const wallets = await prisma.walletAddress.findMany();
  const walletById = new Map(wallets.map((wallet) => [wallet.id, wallet]));
  const assets = run.holdings.map((holding) => holdingToAsset(holding, walletById.get(holding.walletId ?? "")));
  const exchangeSnapshots: ExchangeSnapshot[] = run.exchangeSnapshots.map((snapshot) => ({
    id: snapshot.id,
    connectionId: snapshot.connectionId,
    provider: snapshot.provider as ExchangeSnapshot["provider"],
    label: snapshot.label,
    generatedAt: snapshot.generatedAt.toISOString(),
    totalUsd: snapshot.totalUsd,
    status: snapshot.status as ExchangeSnapshot["status"],
    holdings: snapshot.holdings.map((holding) => holdingToAsset(holding, undefined))
  }));

  return {
    generatedAt: run.generatedAt.toISOString(),
    scanRunId: run.id,
    inputCount: run.inputCount,
    addresses: wallets.map((wallet) => ({
      address: wallet.address,
      detectedChains: [wallet.chainKind],
      assets: assets.filter((asset) => asset.address.toLowerCase() === wallet.address.toLowerCase()),
      warnings: [],
      errors: []
    } satisfies AddressScan)),
    assets,
    summary: JSON.parse(run.summaryJson) as ScanSummary,
    warnings: JSON.parse(run.warningsJson) as string[],
    sources: JSON.parse(run.sourcesJson) as ScanSource[],
    exchangeSnapshots
  };
}

function serializeWallet(wallet: {
  id: string;
  label: string;
  address: string;
  chainKind: string;
  createdAt: Date;
  updatedAt: Date;
}) {
  return {
    id: wallet.id,
    label: wallet.label,
    address: wallet.address,
    chainKind: wallet.chainKind,
    createdAt: wallet.createdAt.toISOString(),
    updatedAt: wallet.updatedAt.toISOString()
  } satisfies WalletRecord;
}

function holdingData(
  asset: TrackedAsset,
  scanRunId: string,
  walletId?: string,
  exchangeSnapshotId?: string
) {
  return {
    scanRunId,
    walletId,
    exchangeSnapshotId,
    address: asset.address,
    chainId: asset.chainId,
    chainName: asset.chainName,
    family: asset.family,
    symbol: asset.symbol,
    name: asset.name,
    amount: asset.amount,
    priceUsd: asset.priceUsd,
    valueUsd: asset.valueUsd,
    change24h: asset.change24h,
    explorerUrl: asset.explorerUrl,
    source: asset.source,
    status: asset.status
  };
}

function holdingToAsset(
  holding: {
    id: string;
    address: string | null;
    chainId: string | null;
    chainName: string;
    family: string | null;
    symbol: string;
    name: string;
    amount: number;
    priceUsd: number;
    valueUsd: number;
    change24h: number | null;
    explorerUrl: string | null;
    source: string;
    status: string;
  },
  wallet?: { label: string }
) {
  return {
    id: holding.id,
    address: holding.address ?? "",
    chainId: holding.chainId ?? "",
    chainName: holding.chainName,
    family: (holding.family ?? "exchange") as TrackedAsset["family"],
    symbol: holding.symbol,
    name: holding.name,
    amount: holding.amount,
    priceUsd: holding.priceUsd,
    valueUsd: holding.valueUsd,
    change24h: holding.change24h ?? undefined,
    explorerUrl: holding.explorerUrl ?? "",
    source: holding.source as TrackedAsset["source"],
    status: holding.status as TrackedAsset["status"],
    walletLabel: wallet?.label
  } satisfies TrackedAsset;
}
