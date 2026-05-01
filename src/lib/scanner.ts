import {
  detectChainsForAddress,
  ERC20_TOKENS_BY_CHAIN,
  getAllCoinGeckoIds
} from "./chain-registry";
import { formatUnits, hexToBigInt } from "./format";
import { getPrices } from "./prices";
import {
  AddressScan,
  ChainConfig,
  PricePoint,
  ScanResponse,
  TokenConfig,
  TrackedAsset
} from "./types";

const REQUEST_TIMEOUT_MS = 9_000;
const MAX_ADDRESS_COUNT = 24;

export function parseAddressInput(input: string | string[]): string[] {
  const values = Array.isArray(input)
    ? input
    : input.split(/[\s,;]+/g);

  const seen = new Set<string>();
  return values
    .map((value) => value.trim())
    .filter(Boolean)
    .filter((value) => {
      const key = value.toLowerCase();
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .slice(0, MAX_ADDRESS_COUNT);
}

export async function scanAddresses(input: string | string[]): Promise<ScanResponse> {
  const addresses = parseAddressInput(input);
  const prices = await getPrices(getAllCoinGeckoIds());

  const scans = await Promise.all(
    addresses.map((address) => scanAddress(address, prices))
  );
  const assets = scans.flatMap((scan) => scan.assets);
  const chains = new Set(assets.map((asset) => asset.chainId));
  const warnings = scans.flatMap((scan) => scan.warnings);

  return {
    generatedAt: new Date().toISOString(),
    inputCount: addresses.length,
    addresses: scans,
    assets,
    summary: {
      totalUsd: assets.reduce((sum, asset) => sum + asset.valueUsd, 0),
      addressCount: addresses.length,
      chainCount: chains.size,
      assetCount: assets.length
    },
    warnings
  };
}

async function scanAddress(
  address: string,
  prices: Record<string, PricePoint>
): Promise<AddressScan> {
  const detectedChains = detectChainsForAddress(address);
  if (detectedChains.length === 0) {
    return {
      address,
      detectedChains: [],
      assets: [],
      warnings: [`No supported chain matched ${address}.`],
      errors: []
    };
  }

  const results = await Promise.allSettled(
    detectedChains.map((chain) => scanChain(address, chain, prices))
  );

  const assets: TrackedAsset[] = [];
  const warnings: string[] = [];
  const errors: string[] = [];

  results.forEach((result, index) => {
    const chain = detectedChains[index];
    if (result.status === "fulfilled") {
      assets.push(...result.value.assets);
      warnings.push(...result.value.warnings);
    } else {
      errors.push(`${chain.name}: ${readError(result.reason)}`);
    }
  });

  if (assets.length === 0 && errors.length === 0) {
    warnings.push(`No non-zero tracked balances found for ${address}.`);
  }

  return {
    address,
    detectedChains: detectedChains.map((chain) => chain.id),
    assets,
    warnings,
    errors
  };
}

async function scanChain(
  address: string,
  chain: ChainConfig,
  prices: Record<string, PricePoint>
): Promise<{ assets: TrackedAsset[]; warnings: string[] }> {
  if (chain.family === "bitcoin") {
    return scanBitcoin(address, chain, prices);
  }

  if (chain.family === "cosmos") {
    return scanCosmos(address, chain, prices);
  }

  return scanEvm(address, chain, prices);
}

async function scanBitcoin(
  address: string,
  chain: ChainConfig,
  prices: Record<string, PricePoint>
): Promise<{ assets: TrackedAsset[]; warnings: string[] }> {
  const data = await fetchJson<{
    chain_stats: { funded_txo_sum: number; spent_txo_sum: number };
    mempool_stats?: { funded_txo_sum: number; spent_txo_sum: number };
  }>(`https://blockstream.info/api/address/${address}`);

  const confirmed = data.chain_stats.funded_txo_sum - data.chain_stats.spent_txo_sum;
  const mempool = data.mempool_stats
    ? data.mempool_stats.funded_txo_sum - data.mempool_stats.spent_txo_sum
    : 0;
  const amount = (confirmed + mempool) / 100_000_000;
  if (amount <= 0) return { assets: [], warnings: [] };

  return {
    assets: [assetFromAmount(address, chain, chain.symbol, chain.name, amount, prices, "native")],
    warnings: []
  };
}

async function scanCosmos(
  address: string,
  chain: ChainConfig,
  prices: Record<string, PricePoint>
): Promise<{ assets: TrackedAsset[]; warnings: string[] }> {
  const endpoints = [chain.restUrl, ...(chain.fallbackRestUrls ?? [])].filter(Boolean) as string[];
  let lastError = "";

  for (const endpoint of endpoints) {
    try {
      const data = await fetchJson<{ balances?: { denom: string; amount: string }[] }>(
        `${endpoint.replace(/\/$/, "")}/cosmos/bank/v1beta1/balances/${address}`
      );
      const balance = data.balances?.find((item) => item.denom === chain.nativeDenom);
      const amount = balance ? Number(balance.amount) / Math.pow(10, chain.decimals) : 0;
      if (amount <= 0) return { assets: [], warnings: [] };

      return {
        assets: [assetFromAmount(address, chain, chain.symbol, chain.name, amount, prices, "native")],
        warnings: []
      };
    } catch (error) {
      lastError = readError(error);
    }
  }

  return {
    assets: [],
    warnings: [`${chain.name} balance fetch failed: ${lastError || "all REST endpoints failed"}.`]
  };
}

async function scanEvm(
  address: string,
  chain: ChainConfig,
  prices: Record<string, PricePoint>
): Promise<{ assets: TrackedAsset[]; warnings: string[] }> {
  if (!chain.rpcUrl) {
    return { assets: [], warnings: [`${chain.name} has no RPC endpoint configured.`] };
  }

  const warnings: string[] = [];
  const assets: TrackedAsset[] = [];

  try {
    const balanceHex = await rpcCall<string>(chain.rpcUrl, "eth_getBalance", [address, "latest"]);
    const amount = formatUnits(hexToBigInt(balanceHex), chain.decimals);
    if (amount > 0) {
      assets.push(assetFromAmount(address, chain, chain.symbol, chain.name, amount, prices, "native"));
    }
  } catch (error) {
    warnings.push(`${chain.name} native balance failed: ${readError(error)}.`);
  }

  const tokenResults = await Promise.allSettled(
    (ERC20_TOKENS_BY_CHAIN[chain.id] ?? []).map((token) =>
      scanErc20(address, chain, token, prices)
    )
  );

  tokenResults.forEach((result) => {
    if (result.status === "fulfilled" && result.value) {
      assets.push(result.value);
    }
  });

  return { assets, warnings };
}

async function scanErc20(
  address: string,
  chain: ChainConfig,
  token: TokenConfig,
  prices: Record<string, PricePoint>
): Promise<TrackedAsset | null> {
  if (!chain.rpcUrl) return null;

  const balanceHex = await rpcCall<string>(
    chain.rpcUrl,
    "eth_call",
    [
      {
        to: token.address,
        data: erc20BalanceOfData(address)
      },
      "latest"
    ]
  );
  const amount = formatUnits(hexToBigInt(balanceHex), token.decimals);
  if (amount <= 0) return null;

  const price = prices[token.coinGeckoId];
  return {
    id: `${address}-${chain.id}-${token.symbol}-${token.address}`,
    address,
    chainId: chain.id,
    chainName: chain.name,
    family: chain.family,
    symbol: token.symbol,
    name: token.name,
    amount,
    priceUsd: price?.usd ?? 0,
    valueUsd: amount * (price?.usd ?? 0),
    change24h: price?.usd_24h_change,
    explorerUrl: `${chain.explorerUrl}${address}`,
    source: "erc20",
    status: "ok"
  };
}

function assetFromAmount(
  address: string,
  chain: ChainConfig,
  symbol: string,
  name: string,
  amount: number,
  prices: Record<string, PricePoint>,
  source: "native" | "erc20"
): TrackedAsset {
  const price = prices[chain.coinGeckoId];
  return {
    id: `${address}-${chain.id}-${symbol}-${source}`,
    address,
    chainId: chain.id,
    chainName: chain.name,
    family: chain.family,
    symbol,
    name,
    amount,
    priceUsd: price?.usd ?? 0,
    valueUsd: amount * (price?.usd ?? 0),
    change24h: price?.usd_24h_change,
    explorerUrl: `${chain.explorerUrl}${address}`,
    source,
    status: "ok"
  };
}

function erc20BalanceOfData(address: string): `0x${string}` {
  const normalized = address.replace(/^0x/, "").toLowerCase().padStart(64, "0");
  return `0x70a08231${normalized}`;
}

async function rpcCall<T>(rpcUrl: string, method: string, params: unknown[]): Promise<T> {
  const result = await fetchJson<{ result?: T; error?: { message?: string } }>(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method,
      params
    })
  });

  if (result.error) {
    throw new Error(result.error.message || "RPC error");
  }

  return result.result as T;
}

async function fetchJson<T>(url: string, init?: RequestInit): Promise<T> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

  try {
    const response = await fetch(url, {
      ...init,
      signal: controller.signal,
      headers: {
        accept: "application/json",
        ...(init?.headers ?? {})
      },
      next: {
        revalidate: 20
      }
    });

    if (!response.ok) {
      throw new Error(`${response.status} ${response.statusText}`);
    }

    return (await response.json()) as T;
  } finally {
    clearTimeout(timeout);
  }
}

function readError(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}
