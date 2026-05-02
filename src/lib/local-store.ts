import { prisma } from "./db";
import { defaultWalletLabel, detectAddressKind, isSupportedPublicAddress } from "./address-utils";
import { EVM_CHAINS } from "./chain-registry";
import {
  listEnabledManualHoldings,
  manualHoldingToTrackedAsset
} from "./manual-exchanges";
import {
  AddressScan,
  ExchangeSnapshot,
  ScanResponse,
  ScanSource,
  ScanSummary,
  TrackedAsset
} from "./types";

export interface ScanHistoryTopChain {
  name: string;
  valueUsd: number;
}

export interface ScanHistoryEntry {
  id: string;
  generatedAt: string;
  totalUsd: number;
  inputCount: number;
  assetCount: number;
  chainCount: number;
  warningCount: number;
  sourceCount: number;
  topChains: ScanHistoryTopChain[];
}

export const SCAN_HISTORY_DEFAULT_LIMIT = 12;
export const SCAN_HISTORY_MAX_LIMIT = 60;

export interface WalletRecord {
  id: string;
  label: string;
  address: string;
  chainKind: string;
  createdAt: string;
  updatedAt: string;
}

export interface CustomTokenRecord {
  id: string;
  chainKind: string;
  chainId: string;
  address: string;
  symbol: string;
  name: string;
  decimals: number;
  coinGeckoId: string;
  enabled: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface CustomTokenInput {
  chainKind?: string;
  chainId?: string;
  address?: string;
  symbol?: string;
  name?: string;
  decimals?: number | string;
  coinGeckoId?: string;
  enabled?: boolean;
}

export interface CustomTokenUpdate {
  symbol?: string;
  name?: string;
  decimals?: number | string;
  coinGeckoId?: string;
  enabled?: boolean;
}

export class CustomTokenValidationError extends Error {
  field: string;
  constructor(field: string, message: string) {
    super(message);
    this.field = field;
    this.name = "CustomTokenValidationError";
  }
}

const SUPPORTED_TOKEN_CHAIN_KINDS = new Set(["evm"]);
const EVM_CHAIN_IDS = new Set(EVM_CHAINS.map((chain) => chain.id));

interface NormalizedToken {
  chainKind: string;
  chainId: string;
  address: string;
  symbol: string;
  name: string;
  decimals: number;
  coinGeckoId: string;
  enabled: boolean;
}

export function normalizeCustomTokenInput(input: CustomTokenInput): NormalizedToken {
  const chainKind = (input.chainKind ?? "evm").trim().toLowerCase();
  if (!SUPPORTED_TOKEN_CHAIN_KINDS.has(chainKind)) {
    throw new CustomTokenValidationError(
      "chainKind",
      `Unsupported chainKind "${chainKind}". Only "evm" is supported.`
    );
  }

  const chainId = (input.chainId ?? "").trim().toLowerCase();
  if (!chainId) {
    throw new CustomTokenValidationError("chainId", "chainId is required.");
  }
  if (chainKind === "evm" && !EVM_CHAIN_IDS.has(chainId)) {
    throw new CustomTokenValidationError(
      "chainId",
      `Unknown EVM chainId "${chainId}". Use one of: ${[...EVM_CHAIN_IDS].join(", ")}.`
    );
  }

  const rawAddress = (input.address ?? "").trim();
  if (chainKind === "evm" && !/^0x[a-fA-F0-9]{40}$/.test(rawAddress)) {
    throw new CustomTokenValidationError(
      "address",
      "address must be a 0x-prefixed 40-character hex string."
    );
  }
  const address = chainKind === "evm" ? rawAddress.toLowerCase() : rawAddress;

  const symbol = (input.symbol ?? "").trim();
  if (!symbol) {
    throw new CustomTokenValidationError("symbol", "symbol is required.");
  }
  if (symbol.length > 24) {
    throw new CustomTokenValidationError("symbol", "symbol must be 24 characters or fewer.");
  }

  const name = (input.name ?? "").trim();
  if (!name) {
    throw new CustomTokenValidationError("name", "name is required.");
  }
  if (name.length > 80) {
    throw new CustomTokenValidationError("name", "name must be 80 characters or fewer.");
  }

  const decimalsValue =
    typeof input.decimals === "string" ? Number(input.decimals.trim()) : input.decimals;
  if (
    decimalsValue === undefined ||
    !Number.isInteger(decimalsValue) ||
    decimalsValue < 0 ||
    decimalsValue > 36
  ) {
    throw new CustomTokenValidationError(
      "decimals",
      "decimals must be an integer between 0 and 36."
    );
  }

  const coinGeckoId = (input.coinGeckoId ?? "").trim().toLowerCase();
  if (!coinGeckoId) {
    throw new CustomTokenValidationError("coinGeckoId", "coinGeckoId is required.");
  }
  if (!/^[a-z0-9-]{1,64}$/.test(coinGeckoId)) {
    throw new CustomTokenValidationError(
      "coinGeckoId",
      "coinGeckoId must contain only lowercase letters, digits, or hyphens (max 64 chars)."
    );
  }

  return {
    chainKind,
    chainId,
    address,
    symbol,
    name,
    decimals: decimalsValue,
    coinGeckoId,
    enabled: input.enabled === undefined ? true : Boolean(input.enabled)
  };
}

export async function listCustomTokens() {
  const tokens = await prisma.customToken.findMany({
    orderBy: [{ chainId: "asc" }, { symbol: "asc" }, { createdAt: "asc" }]
  });
  return tokens.map(serializeCustomToken);
}

export async function listEnabledCustomTokens() {
  const tokens = await prisma.customToken.findMany({
    where: { enabled: true },
    orderBy: [{ chainId: "asc" }, { symbol: "asc" }, { createdAt: "asc" }]
  });
  return tokens.map(serializeCustomToken);
}

export async function createCustomToken(input: CustomTokenInput) {
  const normalized = normalizeCustomTokenInput(input);
  const existing = await prisma.customToken.findUnique({
    where: {
      chainKind_chainId_address: {
        chainKind: normalized.chainKind,
        chainId: normalized.chainId,
        address: normalized.address
      }
    }
  });
  if (existing) {
    throw new CustomTokenValidationError(
      "address",
      "A token with this address is already in the allowlist for this chain."
    );
  }

  const created = await prisma.customToken.create({ data: normalized });
  return serializeCustomToken(created);
}

export async function updateCustomToken(id: string, update: CustomTokenUpdate) {
  if (!id) {
    throw new CustomTokenValidationError("id", "Token id is required.");
  }
  const existing = await prisma.customToken.findUnique({ where: { id } });
  if (!existing) {
    throw new CustomTokenValidationError("id", "Token not found.");
  }

  const merged: CustomTokenInput = {
    chainKind: existing.chainKind,
    chainId: existing.chainId,
    address: existing.address,
    symbol: update.symbol ?? existing.symbol,
    name: update.name ?? existing.name,
    decimals: update.decimals ?? existing.decimals,
    coinGeckoId: update.coinGeckoId ?? existing.coinGeckoId,
    enabled: update.enabled === undefined ? existing.enabled : update.enabled
  };
  const normalized = normalizeCustomTokenInput(merged);
  const updated = await prisma.customToken.update({
    where: { id },
    data: {
      symbol: normalized.symbol,
      name: normalized.name,
      decimals: normalized.decimals,
      coinGeckoId: normalized.coinGeckoId,
      enabled: normalized.enabled
    }
  });
  return serializeCustomToken(updated);
}

export async function deleteCustomToken(id: string) {
  if (!id) {
    throw new CustomTokenValidationError("id", "Token id is required.");
  }
  await prisma.customToken.delete({ where: { id } });
}

function serializeCustomToken(token: {
  id: string;
  chainKind: string;
  chainId: string;
  address: string;
  symbol: string;
  name: string;
  decimals: number;
  coinGeckoId: string;
  enabled: boolean;
  createdAt: Date;
  updatedAt: Date;
}): CustomTokenRecord {
  return {
    id: token.id,
    chainKind: token.chainKind,
    chainId: token.chainId,
    address: token.address,
    symbol: token.symbol,
    name: token.name,
    decimals: token.decimals,
    coinGeckoId: token.coinGeckoId,
    enabled: token.enabled,
    createdAt: token.createdAt.toISOString(),
    updatedAt: token.updatedAt.toISOString()
  };
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

  for (const address of addresses.filter(isSupportedPublicAddress)) {
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

  return prisma.$transaction(async (tx) => {
    const run = await tx.scanRun.create({
      data: {
        generatedAt: new Date(scan.generatedAt),
        totalUsd: scan.summary.totalUsd,
        inputCount: scan.inputCount,
        summaryJson,
        warningsJson,
        sourcesJson
      }
    });

    const wallets = await tx.walletAddress.findMany();
    const walletByAddress = new Map(wallets.map((wallet) => [wallet.address.toLowerCase(), wallet.id]));

    for (const asset of scan.assets.filter((item) => item.source !== "exchange")) {
      await tx.holding.create({
        data: holdingData(asset, run.id, walletByAddress.get(asset.address.toLowerCase()))
      });
    }

    // Manual exchange entries are intentionally not snapshotted into the
    // Holding/ExchangeSnapshot tables — they are merged live from the
    // ManualExchangeHolding table whenever a scan response is read.

    for (const snapshot of scan.exchangeSnapshots ?? []) {
      const storedSnapshot = await tx.exchangeSnapshot.create({
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
        await tx.holding.create({
          data: holdingData(holding, run.id, undefined, storedSnapshot.id)
        });
      }
    }

    return run.id;
  });
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

  const manualHoldings = await listEnabledManualHoldings();
  const manualAssets = manualHoldings.map(manualHoldingToTrackedAsset);
  const manualSources: ScanSource[] = manualHoldings.map((holding) => ({
    id: `manual:${holding.id}`,
    label: `${holding.label} (manual)`,
    kind: "exchange",
    status: "ok"
  }));

  if (!run) {
    if (manualAssets.length === 0) return null;
    return {
      generatedAt: latestManualGeneratedAt(manualHoldings) ?? new Date().toISOString(),
      inputCount: 0,
      addresses: [],
      assets: manualAssets,
      summary: summarizeAssets(0, manualAssets),
      warnings: [],
      sources: manualSources,
      exchangeSnapshots: []
    };
  }

  const wallets = await prisma.walletAddress.findMany();
  const walletById = new Map(wallets.map((wallet) => [wallet.id, wallet]));
  const activeWalletAddresses = new Set(wallets.map((wallet) => wallet.address.toLowerCase()));
  const connections = await prisma.exchangeConnection.findMany({ select: { id: true } });
  const activeConnectionIds = new Set(connections.map((connection) => connection.id));
  const snapshotById = new Map(run.exchangeSnapshots.map((snapshot) => [snapshot.id, snapshot]));
  const visibleHoldings = run.holdings.filter((holding) => {
    if (holding.source === "exchange") {
      const snapshot = snapshotById.get(holding.exchangeSnapshotId ?? "");
      return Boolean(snapshot && activeConnectionIds.has(snapshot.connectionId));
    }

    return Boolean(holding.walletId && walletById.has(holding.walletId));
  });
  const onchainAndCcxtAssets = visibleHoldings.map((holding) =>
    holdingToAsset(holding, walletById.get(holding.walletId ?? ""))
  );
  const assets = [...onchainAndCcxtAssets, ...manualAssets];
  const exchangeSnapshots: ExchangeSnapshot[] = run.exchangeSnapshots
    .filter((snapshot) => activeConnectionIds.has(snapshot.connectionId))
    .map((snapshot) => ({
    id: snapshot.id,
    connectionId: snapshot.connectionId,
    provider: snapshot.provider as ExchangeSnapshot["provider"],
    label: snapshot.label,
    generatedAt: snapshot.generatedAt.toISOString(),
    totalUsd: snapshot.totalUsd,
    status: snapshot.status as ExchangeSnapshot["status"],
    holdings: snapshot.holdings.map((holding) => holdingToAsset(holding, undefined))
  }));
  const persistedSources = (JSON.parse(run.sourcesJson) as ScanSource[]).filter((source) => {
    if (source.id.startsWith("manual:")) return false;
    if (source.kind === "exchange") return activeConnectionIds.has(source.id);
    return activeWalletAddresses.has(source.id.toLowerCase());
  });
  const sources = [...persistedSources, ...manualSources];

  return {
    generatedAt: run.generatedAt.toISOString(),
    scanRunId: run.id,
    inputCount: run.inputCount,
    addresses: wallets.map((wallet) => ({
      address: wallet.address,
      detectedChains: [wallet.chainKind],
      assets: onchainAndCcxtAssets.filter((asset) => asset.address.toLowerCase() === wallet.address.toLowerCase()),
      warnings: [],
      errors: []
    } satisfies AddressScan)),
    assets,
    summary: summarizeAssets(wallets.length, assets),
    warnings: JSON.parse(run.warningsJson) as string[],
    sources,
    exchangeSnapshots
  };
}

function latestManualGeneratedAt(holdings: { generatedAt: string }[]) {
  if (holdings.length === 0) return null;
  return holdings
    .map((holding) => holding.generatedAt)
    .sort()
    .at(-1) ?? null;
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

function summarizeAssets(addressCount: number, assets: TrackedAsset[]) {
  return {
    totalUsd: assets.reduce((sum, asset) => sum + asset.valueUsd, 0),
    addressCount,
    chainCount: new Set(assets.map((asset) => asset.chainId)).size,
    assetCount: assets.length
  } satisfies ScanSummary;
}

export async function listScanRunHistory(limit = SCAN_HISTORY_DEFAULT_LIMIT): Promise<ScanHistoryEntry[]> {
  const safeLimit = clampHistoryLimit(limit);
  const runs = await prisma.scanRun.findMany({
    orderBy: {
      generatedAt: "desc"
    },
    take: safeLimit,
    include: {
      holdings: {
        select: {
          chainName: true,
          valueUsd: true
        }
      }
    }
  });

  return runs.map((run) => {
    const summary = parseSummary(run.summaryJson);
    const warnings = parseStringArray(run.warningsJson);
    const sources = parseSources(run.sourcesJson);

    return {
      id: run.id,
      generatedAt: run.generatedAt.toISOString(),
      totalUsd: run.totalUsd,
      inputCount: run.inputCount,
      assetCount: summary?.assetCount ?? run.holdings.length,
      chainCount: summary?.chainCount ?? new Set(run.holdings.map((holding) => holding.chainName)).size,
      warningCount: warnings.length,
      sourceCount: sources.length,
      topChains: aggregateTopChains(run.holdings, 3)
    } satisfies ScanHistoryEntry;
  });
}

export function clampHistoryLimit(value: number) {
  if (!Number.isFinite(value)) return SCAN_HISTORY_DEFAULT_LIMIT;
  const rounded = Math.floor(value);
  if (rounded <= 0) return SCAN_HISTORY_DEFAULT_LIMIT;
  return Math.min(rounded, SCAN_HISTORY_MAX_LIMIT);
}

function parseSummary(json: string): ScanSummary | undefined {
  try {
    const parsed = JSON.parse(json) as Partial<ScanSummary>;
    if (!parsed || typeof parsed !== "object") return undefined;
    return {
      totalUsd: Number(parsed.totalUsd ?? 0),
      addressCount: Number(parsed.addressCount ?? 0),
      chainCount: Number(parsed.chainCount ?? 0),
      assetCount: Number(parsed.assetCount ?? 0)
    } satisfies ScanSummary;
  } catch {
    return undefined;
  }
}

function parseStringArray(json: string): string[] {
  try {
    const parsed = JSON.parse(json);
    return Array.isArray(parsed) ? parsed.filter((item): item is string => typeof item === "string") : [];
  } catch {
    return [];
  }
}

function parseSources(json: string): ScanSource[] {
  try {
    const parsed = JSON.parse(json);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function aggregateTopChains(
  holdings: { chainName: string; valueUsd: number }[],
  limit: number
): ScanHistoryTopChain[] {
  if (holdings.length === 0) return [];
  const totals = new Map<string, number>();
  for (const holding of holdings) {
    totals.set(holding.chainName, (totals.get(holding.chainName) ?? 0) + holding.valueUsd);
  }
  return Array.from(totals.entries())
    .map(([name, valueUsd]) => ({ name, valueUsd }))
    .sort((a, b) => b.valueUsd - a.valueUsd)
    .slice(0, limit);
}
