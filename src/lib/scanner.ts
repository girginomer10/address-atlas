import {
  detectChainsForAddress,
  ERC20_TOKENS_BY_CHAIN,
  getAllCoinGeckoIds,
  SOLANA_TOKEN_2022_PROGRAM_ID,
  SOLANA_TOKEN_PROGRAM_ID,
  SPL_TOKENS_BY_CHAIN,
  TRC20_TOKENS_BY_CHAIN
} from "./chain-registry";
import { formatUnits, hexToBigInt } from "./format";
import { listEnabledCustomTokens } from "./local-store";
import { getPrices } from "./prices";
import {
  AddressScan,
  AssetSource,
  ChainConfig,
  PricePoint,
  ScanResponse,
  SplTokenConfig,
  TokenConfig,
  TrackedAsset,
  Trc20TokenConfig
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
  const customTokens = await loadCustomTokens();
  const tokensByChain = mergeTokensByChain(customTokens.evm);
  const splTokensByChain = mergeSplTokensByChain(customTokens.solana);
  const prices = await getPrices(allCoinGeckoIds(tokensByChain, splTokensByChain));

  const scans = await Promise.all(
    addresses.map((address) => scanAddress(address, prices, tokensByChain, splTokensByChain))
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
  prices: Record<string, PricePoint>,
  tokensByChain: Record<string, TokenConfig[]>,
  splTokensByChain: Record<string, SplTokenConfig[]>
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
    detectedChains.map((chain) => scanChain(address, chain, prices, tokensByChain, splTokensByChain))
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
  prices: Record<string, PricePoint>,
  tokensByChain: Record<string, TokenConfig[]>,
  splTokensByChain: Record<string, SplTokenConfig[]>
): Promise<{ assets: TrackedAsset[]; warnings: string[] }> {
  if (chain.family === "bitcoin") {
    return scanBitcoin(address, chain, prices);
  }

  if (chain.family === "cosmos") {
    return scanCosmos(address, chain, prices);
  }

  if (chain.family === "solana") {
    return scanSolana(address, chain, prices, splTokensByChain[chain.id] ?? []);
  }

  if (chain.family === "tron") {
    return scanTron(address, chain, prices);
  }

  if (chain.family === "xrp") {
    return scanXrp(address, chain, prices);
  }

  return scanEvm(address, chain, prices, tokensByChain[chain.id] ?? []);
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

interface CosmosBankResponse {
  balances?: { denom: string; amount: string }[];
}

interface CosmosDelegationResponse {
  delegation_responses?: {
    balance?: { denom: string; amount: string };
  }[];
}

interface CosmosRewardsResponse {
  total?: { denom: string; amount: string }[];
}

export function parseCosmosLiquid(
  data: CosmosBankResponse,
  denom: string,
  decimals: number
): number {
  const balance = data.balances?.find((item) => item.denom === denom);
  return balance ? amountToNumber(balance.amount, decimals) : 0;
}

export function parseCosmosDelegations(
  data: CosmosDelegationResponse,
  denom: string,
  decimals: number
): number {
  const responses = data.delegation_responses ?? [];
  const totalMicro = responses.reduce((sum, item) => {
    if (!item.balance || item.balance.denom !== denom) return sum;
    return sum + parseDecimalString(item.balance.amount);
  }, 0);
  return totalMicro / Math.pow(10, decimals);
}

export function parseCosmosRewards(
  data: CosmosRewardsResponse,
  denom: string,
  decimals: number
): number {
  const entry = (data.total ?? []).find((item) => item.denom === denom);
  return entry ? amountToNumber(entry.amount, decimals) : 0;
}

function amountToNumber(value: string, decimals: number): number {
  return parseDecimalString(value) / Math.pow(10, decimals);
}

function parseDecimalString(value: string): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

async function scanCosmos(
  address: string,
  chain: ChainConfig,
  prices: Record<string, PricePoint>
): Promise<{ assets: TrackedAsset[]; warnings: string[] }> {
  const endpoints = [chain.restUrl, ...(chain.fallbackRestUrls ?? [])].filter(Boolean) as string[];
  const denom = chain.nativeDenom ?? "";
  let liquidAmount = 0;
  let activeEndpoint: string | null = null;
  let liquidError = "";

  for (const endpoint of endpoints) {
    try {
      const data = await fetchJson<CosmosBankResponse>(
        `${endpoint.replace(/\/$/, "")}/cosmos/bank/v1beta1/balances/${address}`
      );
      liquidAmount = parseCosmosLiquid(data, denom, chain.decimals);
      activeEndpoint = endpoint.replace(/\/$/, "");
      liquidError = "";
      break;
    } catch (error) {
      liquidError = readError(error);
    }
  }

  if (!activeEndpoint) {
    return {
      assets: [],
      warnings: [`${chain.name} balance fetch failed: ${liquidError || "all REST endpoints failed"}.`]
    };
  }

  const assets: TrackedAsset[] = [];
  const warnings: string[] = [];

  if (liquidAmount > 0) {
    assets.push(assetFromAmount(address, chain, chain.symbol, chain.name, liquidAmount, prices, "native"));
  }

  const [stakedResult, rewardsResult] = await Promise.allSettled([
    fetchJson<CosmosDelegationResponse>(
      `${activeEndpoint}/cosmos/staking/v1beta1/delegations/${address}?pagination.limit=500`
    ),
    fetchJson<CosmosRewardsResponse>(
      `${activeEndpoint}/cosmos/distribution/v1beta1/delegators/${address}/rewards`
    )
  ]);

  if (stakedResult.status === "fulfilled") {
    const stakedAmount = parseCosmosDelegations(stakedResult.value, denom, chain.decimals);
    if (stakedAmount > 0) {
      assets.push(
        assetFromAmount(
          address,
          chain,
          chain.symbol,
          `${chain.name} (Staked)`,
          stakedAmount,
          prices,
          "staked"
        )
      );
    }
  } else {
    warnings.push(`${chain.name} delegations fetch failed: ${readError(stakedResult.reason)}.`);
  }

  if (rewardsResult.status === "fulfilled") {
    const rewardsAmount = parseCosmosRewards(rewardsResult.value, denom, chain.decimals);
    if (rewardsAmount > 0) {
      assets.push(
        assetFromAmount(
          address,
          chain,
          chain.symbol,
          `${chain.name} (Rewards)`,
          rewardsAmount,
          prices,
          "rewards"
        )
      );
    }
  } else {
    warnings.push(`${chain.name} rewards fetch failed: ${readError(rewardsResult.reason)}.`);
  }

  return { assets, warnings };
}

async function scanSolana(
  address: string,
  chain: ChainConfig,
  prices: Record<string, PricePoint>,
  tokens: SplTokenConfig[]
): Promise<{ assets: TrackedAsset[]; warnings: string[] }> {
  if (!chain.rpcUrl) {
    return { assets: [], warnings: [`${chain.name} has no RPC endpoint configured.`] };
  }

  const assets: TrackedAsset[] = [];
  const warnings: string[] = [];

  try {
    const result = await rpcCall<{ value: number }>(chain.rpcUrl, "getBalance", [
      address,
      { commitment: "confirmed" }
    ]);
    const amount = result.value / Math.pow(10, chain.decimals);
    if (amount > 0) {
      assets.push(
        assetFromAmount(address, chain, chain.symbol, chain.name, amount, prices, "native")
      );
    }
  } catch (error) {
    warnings.push(`${chain.name} native balance failed: ${readError(error)}.`);
  }

  if (tokens.length > 0) {
    try {
      const { balances, warnings: tokenWarnings } = await fetchSolanaSplBalances(chain.rpcUrl, address, tokens);
      warnings.push(...tokenWarnings.map((warning) => `${chain.name} ${warning}`));
      balances.forEach(({ token, amount }) => {
        if (amount <= 0) return;
        assets.push(splAssetFromAmount(address, chain, token, amount, prices));
      });
    } catch (error) {
      warnings.push(`${chain.name} SPL token balances failed: ${readError(error)}.`);
    }
  }

  return { assets, warnings };
}

interface TronAccountResponse {
  data?: {
    balance?: number;
    trc20?: Record<string, string>[];
  }[];
}

async function scanTron(
  address: string,
  chain: ChainConfig,
  prices: Record<string, PricePoint>
): Promise<{ assets: TrackedAsset[]; warnings: string[] }> {
  if (!chain.restUrl) {
    return { assets: [], warnings: [`${chain.name} has no API endpoint configured.`] };
  }

  const assets: TrackedAsset[] = [];
  const warnings: string[] = [];

  try {
    const data = await fetchJson<TronAccountResponse>(
      `${chain.restUrl.replace(/\/$/, "")}/v1/accounts/${address}`
    );
    const account = data.data?.[0];
    if (!account) return { assets, warnings };

    const trxAmount = (account.balance ?? 0) / Math.pow(10, chain.decimals);
    if (trxAmount > 0) {
      assets.push(assetFromAmount(address, chain, chain.symbol, chain.name, trxAmount, prices, "native"));
    }

    const tokens = TRC20_TOKENS_BY_CHAIN[chain.id] ?? [];
    const trc20Balances = account.trc20 ?? [];
    for (const token of tokens) {
      const raw = trc20Balances.reduce((sum, item) => {
        const value = item[token.address];
        return sum + (value && /^\d+$/.test(value) ? BigInt(value) : 0n);
      }, 0n);
      if (raw <= 0n) continue;
      assets.push(trc20AssetFromAmount(address, chain, token, formatUnits(raw, token.decimals), prices));
    }
  } catch (error) {
    warnings.push(`${chain.name} scan failed: ${readError(error)}.`);
  }

  return { assets, warnings };
}

interface XrpAccountInfoResponse {
  result?: {
    status?: string;
    error?: string;
    error_message?: string;
    account_data?: {
      Balance?: string;
    };
  };
}

interface XrpAccountLinesResponse {
  result?: {
    status?: string;
    error?: string;
    error_message?: string;
    lines?: {
      account?: string;
      balance?: string;
      currency?: string;
    }[];
  };
}

async function scanXrp(
  address: string,
  chain: ChainConfig,
  prices: Record<string, PricePoint>
): Promise<{ assets: TrackedAsset[]; warnings: string[] }> {
  if (!chain.rpcUrl) {
    return { assets: [], warnings: [`${chain.name} has no RPC endpoint configured.`] };
  }

  const body = await xrpRpc<XrpAccountInfoResponse>(chain.rpcUrl, "account_info", {
    account: address,
    ledger_index: "validated"
  });
  const result = body.result;
  if (!result || result.status === "error") {
    if (result?.error === "actNotFound") return { assets: [], warnings: [] };
    throw new Error(result?.error_message || result?.error || "XRP account lookup failed");
  }

  const assets: TrackedAsset[] = [];
  const warnings: string[] = [];
  const drops = safeBigInt(result.account_data?.Balance ?? "0");
  const amount = formatUnits(drops, chain.decimals);
  if (amount > 0) {
    assets.push(assetFromAmount(address, chain, chain.symbol, chain.name, amount, prices, "native"));
  }

  try {
    const linesBody = await xrpRpc<XrpAccountLinesResponse>(chain.rpcUrl, "account_lines", {
      account: address,
      ledger_index: "validated",
      limit: 200
    });
    const linesResult = linesBody.result;
    if (!linesResult || linesResult.status === "error") {
      throw new Error(linesResult?.error_message || linesResult?.error || "XRP trust lines lookup failed");
    }
    for (const line of linesResult.lines ?? []) {
      const lineAmount = Number(line.balance ?? "0");
      if (!Number.isFinite(lineAmount) || lineAmount <= 0) continue;
      const currency = decodeXrplCurrency(line.currency ?? "");
      const issuer = line.account ?? "";
      assets.push(xrpIssuedAssetFromAmount(address, chain, currency, issuer, lineAmount));
    }
  } catch (error) {
    warnings.push(`${chain.name} trust lines fetch failed: ${readError(error)}.`);
  }

  return { assets, warnings };
}

async function xrpRpc<T>(rpcUrl: string, method: string, params: Record<string, unknown>): Promise<T> {
  return fetchJson<T>(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      method,
      params: [params]
    })
  });
}

interface ParsedSplAccount {
  mint: string;
  rawAmount: string;
  decimals: number;
}

async function fetchSolanaSplBalances(
  rpcUrl: string,
  owner: string,
  registry: SplTokenConfig[]
): Promise<{ balances: { token: SplTokenConfig; amount: number }[]; warnings: string[] }> {
  const programs = [
    { id: SOLANA_TOKEN_PROGRAM_ID, label: "classic SPL token accounts" },
    { id: SOLANA_TOKEN_2022_PROGRAM_ID, label: "Token-2022 token accounts" }
  ];
  const tokenAccounts = await Promise.allSettled(
    programs.map((program) =>
      rpcCall<{
        value?: {
          account?: {
            data?: {
              parsed?: {
                info?: {
                  mint?: unknown;
                  tokenAmount?: { amount?: unknown; decimals?: unknown };
                };
              };
            };
          };
        }[];
      }>(rpcUrl, "getTokenAccountsByOwner", [
        owner,
        { programId: program.id },
        { encoding: "jsonParsed", commitment: "confirmed" }
      ])
    )
  );
  const warnings: string[] = [];
  const parsed = tokenAccounts.flatMap((result, index) => {
    if (result.status === "fulfilled") return parseSplTokenAccounts(result.value?.value ?? []);
    warnings.push(`${programs[index].label} failed: ${readError(result.reason)}.`);
    return [];
  });
  if (parsed.length === 0 && tokenAccounts.every((result) => result.status === "rejected")) {
    throw new Error(warnings.join(" "));
  }

  const byMint = new Map<string, SplTokenConfig>();
  registry.forEach((token) => byMint.set(token.mint, token));

  const totals = new Map<string, { raw: bigint; decimals: number }>();
  for (const account of parsed) {
    const token = byMint.get(account.mint);
    if (!token) continue;
    if (account.decimals !== token.decimals) {
      warnings.push(
        `${token.symbol} on-chain decimals (${account.decimals}) differ from registry (${token.decimals}); using on-chain value.`
      );
    }
    const previous = totals.get(account.mint);
    totals.set(account.mint, {
      raw: (previous?.raw ?? 0n) + safeBigInt(account.rawAmount),
      decimals: account.decimals
    });
  }

  return {
    balances: Array.from(totals.entries()).map(([mint, { raw, decimals }]) => {
      const token = byMint.get(mint) as SplTokenConfig;
      return { token, amount: formatUnits(raw, decimals) };
    }),
    warnings
  };
}

export function parseSplTokenAccounts(value: unknown): ParsedSplAccount[] {
  if (!Array.isArray(value)) return [];

  const accounts: ParsedSplAccount[] = [];
  for (const entry of value) {
    const info = (entry as { account?: { data?: { parsed?: { info?: unknown } } } })?.account?.data?.parsed?.info;
    if (!info || typeof info !== "object") continue;

    const record = info as {
      mint?: unknown;
      tokenAmount?: { amount?: unknown; decimals?: unknown };
    };
    const mint = typeof record.mint === "string" ? record.mint : null;
    const rawAmount = typeof record.tokenAmount?.amount === "string" ? record.tokenAmount.amount : null;
    const decimals = typeof record.tokenAmount?.decimals === "number" ? record.tokenAmount.decimals : null;
    if (!mint || rawAmount === null || decimals === null) continue;

    accounts.push({ mint, rawAmount, decimals });
  }
  return accounts;
}

function safeBigInt(value: string): bigint {
  if (!/^\d+$/.test(value)) return 0n;
  try {
    return BigInt(value);
  } catch {
    return 0n;
  }
}

function splAssetFromAmount(
  address: string,
  chain: ChainConfig,
  token: SplTokenConfig,
  amount: number,
  prices: Record<string, PricePoint>
): TrackedAsset {
  const price = token.coinGeckoId ? prices[token.coinGeckoId] : undefined;
  const priceUsd = token.coinGeckoId ? price?.usd ?? token.priceUsd ?? 0 : token.priceUsd ?? 0;
  return {
    id: `${address}-${chain.id}-${token.symbol}-${token.mint}`,
    address,
    chainId: chain.id,
    chainName: chain.name,
    family: chain.family,
    symbol: token.symbol,
    name: token.name,
    amount,
    priceUsd,
    valueUsd: amount * priceUsd,
    change24h: token.coinGeckoId ? price?.usd_24h_change : undefined,
    explorerUrl: `${chain.explorerUrl}${address}`,
    source: "spl",
    status: "ok"
  };
}

function trc20AssetFromAmount(
  address: string,
  chain: ChainConfig,
  token: Trc20TokenConfig,
  amount: number,
  prices: Record<string, PricePoint>
): TrackedAsset {
  const price = token.coinGeckoId ? prices[token.coinGeckoId] : undefined;
  const priceUsd = token.coinGeckoId ? price?.usd ?? token.priceUsd ?? 0 : token.priceUsd ?? 0;
  return {
    id: `${address}-${chain.id}-${token.symbol}-${token.address}`,
    address,
    chainId: chain.id,
    chainName: chain.name,
    family: chain.family,
    symbol: token.symbol,
    name: token.name,
    amount,
    priceUsd,
    valueUsd: amount * priceUsd,
    change24h: token.coinGeckoId ? price?.usd_24h_change : undefined,
    explorerUrl: `${chain.explorerUrl}${address}`,
    source: "trc20",
    status: "ok"
  };
}

function xrpIssuedAssetFromAmount(
  address: string,
  chain: ChainConfig,
  currency: string,
  issuer: string,
  amount: number
): TrackedAsset {
  const symbol = currency || "XRPL-IOU";
  return {
    id: `${address}-${chain.id}-${symbol}-${issuer}`,
    address,
    chainId: chain.id,
    chainName: chain.name,
    family: chain.family,
    symbol,
    name: issuer ? `${symbol} (${issuer.slice(0, 6)}...${issuer.slice(-6)})` : symbol,
    amount,
    priceUsd: 0,
    valueUsd: 0,
    explorerUrl: `${chain.explorerUrl}${address}`,
    source: "issued",
    status: "ok"
  };
}

export function decodeXrplCurrency(value: string): string {
  const trimmed = value.trim();
  if (!/^[a-fA-F0-9]{40}$/.test(trimmed)) return trimmed;

  const bytes = trimmed
    .match(/.{1,2}/g)
    ?.map((part) => Number.parseInt(part, 16))
    .filter((byte) => byte >= 32 && byte <= 126) ?? [];
  const decoded = new TextDecoder().decode(new Uint8Array(bytes)).trim();
  return decoded || `${trimmed.slice(0, 8)}...`;
}

async function scanEvm(
  address: string,
  chain: ChainConfig,
  prices: Record<string, PricePoint>,
  tokens: TokenConfig[]
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

  const tokenScan = await scanErc20Balances(address, chain, tokens, prices);
  assets.push(...tokenScan.assets);
  warnings.push(...tokenScan.warnings);

  return { assets, warnings };
}

async function scanErc20Balances(
  address: string,
  chain: ChainConfig,
  tokens: TokenConfig[],
  prices: Record<string, PricePoint>
): Promise<{ assets: TrackedAsset[]; warnings: string[] }> {
  if (!chain.rpcUrl || tokens.length === 0) return { assets: [], warnings: [] };

  try {
    const results = await rpcBatchCall<string>(
      chain.rpcUrl,
      tokens.map((token) => ({
        method: "eth_call",
        params: [
          {
            to: token.address,
            data: erc20BalanceOfData(address)
          },
          "latest"
        ]
      }))
    );
    return buildErc20TokenScan(address, chain, tokens, results, prices);
  } catch {
    const tokenResults = await Promise.allSettled(
      tokens.map((token) => scanErc20(address, chain, token, prices))
    );
    const results = tokenResults.map((result) =>
      result.status === "fulfilled" ? result.value : new Error(readError(result.reason))
    );
    return buildErc20TokenScan(address, chain, tokens, results, prices);
  }
}

function buildErc20TokenScan(
  address: string,
  chain: ChainConfig,
  tokens: TokenConfig[],
  results: (TrackedAsset | string | Error | null)[],
  prices: Record<string, PricePoint>
): { assets: TrackedAsset[]; warnings: string[] } {
  const assets: TrackedAsset[] = [];
  const failedTokens: string[] = [];

  results.forEach((result, index) => {
    const token = tokens[index];
    if (!token) return;
    if (result instanceof Error) {
      failedTokens.push(token.symbol);
      return;
    }
    if (result === null) return;
    if (typeof result !== "string") {
      assets.push(result);
      return;
    }

    const amount = formatUnits(hexToBigInt(result), token.decimals);
    if (amount > 0) {
      assets.push(erc20AssetFromAmount(address, chain, token, amount, prices));
    }
  });

  return {
    assets,
    warnings: failedTokens.length > 0
      ? [`${chain.name} ERC-20 token balance checks failed for ${formatSymbols(failedTokens)}; token balances may be incomplete.`]
      : []
  };
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

  return erc20AssetFromAmount(address, chain, token, amount, prices);
}

function erc20AssetFromAmount(
  address: string,
  chain: ChainConfig,
  token: TokenConfig,
  amount: number,
  prices: Record<string, PricePoint>
): TrackedAsset {
  const price = token.coinGeckoId ? prices[token.coinGeckoId] : undefined;
  const priceUsd = token.coinGeckoId ? price?.usd ?? token.priceUsd ?? 0 : token.priceUsd ?? 0;
  return {
    id: `${address}-${chain.id}-${token.symbol}-${token.address}`,
    address,
    chainId: chain.id,
    chainName: chain.name,
    family: chain.family,
    symbol: token.symbol,
    name: token.name,
    amount,
    priceUsd,
    valueUsd: amount * priceUsd,
    change24h: token.coinGeckoId ? price?.usd_24h_change : undefined,
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
  source: AssetSource
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

async function rpcBatchCall<T>(
  rpcUrl: string,
  calls: { method: string; params: unknown[] }[]
): Promise<(T | Error)[]> {
  if (calls.length === 0) return [];

  const payload = calls.map((call, index) => ({
    jsonrpc: "2.0",
    id: index + 1,
    method: call.method,
    params: call.params
  }));
  const result = await fetchJson<Array<{ id?: number; result?: T; error?: { message?: string } }>>(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload)
  });
  if (!Array.isArray(result)) {
    throw new Error("RPC batch response was not an array.");
  }

  const byId = new Map(result.map((item) => [item.id, item]));
  return payload.map((request) => {
    const item = byId.get(request.id);
    if (!item) return new Error("RPC batch response was missing a token result.");
    if (item.error) return new Error(item.error.message || "RPC error");
    if (item.result === undefined) return new Error("RPC batch response returned an empty token result.");
    return item.result;
  });
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

function formatSymbols(symbols: string[]): string {
  const unique = Array.from(new Set(symbols)).sort();
  if (unique.length <= 5) return unique.join(", ");
  return `${unique.slice(0, 5).join(", ")} and ${unique.length - 5} more`;
}

async function loadCustomTokens(): Promise<{
  evm: { chainId: string; token: TokenConfig }[];
  solana: { chainId: string; token: SplTokenConfig }[];
}> {
  try {
    const tokens = await listEnabledCustomTokens();
    const evm = tokens
      .filter((token) => token.chainKind === "evm")
      .map((token) => ({
        chainId: token.chainId,
        token: {
          symbol: token.symbol,
          name: token.name,
          address: token.address as `0x${string}`,
          decimals: token.decimals,
          coinGeckoId: token.coinGeckoId,
          priceUsd: token.priceUsd
        } satisfies TokenConfig
      }));
    const solana = tokens
      .filter((token) => token.chainKind === "solana")
      .map((token) => ({
        chainId: token.chainId,
        token: {
          symbol: token.symbol,
          name: token.name,
          mint: token.address,
          decimals: token.decimals,
          coinGeckoId: token.coinGeckoId,
          priceUsd: token.priceUsd
        } satisfies SplTokenConfig
      }));
    return { evm, solana };
  } catch {
    return { evm: [], solana: [] };
  }
}

export function mergeTokensByChain(
  customTokens: { chainId: string; token: TokenConfig }[]
): Record<string, TokenConfig[]> {
  const merged: Record<string, TokenConfig[]> = {};

  for (const [chainId, tokens] of Object.entries(ERC20_TOKENS_BY_CHAIN)) {
    merged[chainId] = tokens.slice();
  }

  for (const { chainId, token } of customTokens) {
    const list = merged[chainId] ?? (merged[chainId] = []);
    const isDuplicate = list.some(
      (existing) => existing.address.toLowerCase() === token.address.toLowerCase()
    );
    if (!isDuplicate) list.push(token);
  }

  return merged;
}

export function mergeSplTokensByChain(
  customTokens: { chainId: string; token: SplTokenConfig }[]
): Record<string, SplTokenConfig[]> {
  const merged: Record<string, SplTokenConfig[]> = {};

  for (const [chainId, tokens] of Object.entries(SPL_TOKENS_BY_CHAIN)) {
    merged[chainId] = tokens.slice();
  }

  for (const { chainId, token } of customTokens) {
    const list = merged[chainId] ?? (merged[chainId] = []);
    const isDuplicate = list.some((existing) => existing.mint === token.mint);
    if (!isDuplicate) list.push(token);
  }

  return merged;
}

function allCoinGeckoIds(
  tokensByChain: Record<string, TokenConfig[]>,
  splTokensByChain: Record<string, SplTokenConfig[]>
): string[] {
  const ids = new Set<string>(getAllCoinGeckoIds());
  Object.values(tokensByChain).forEach((tokens) =>
    tokens.forEach((token) => {
      if (token.coinGeckoId) ids.add(token.coinGeckoId);
    })
  );
  Object.values(splTokensByChain).forEach((tokens) =>
    tokens.forEach((token) => {
      if (token.coinGeckoId) ids.add(token.coinGeckoId);
    })
  );
  Object.values(TRC20_TOKENS_BY_CHAIN).forEach((tokens) =>
    tokens.forEach((token) => {
      if (token.coinGeckoId) ids.add(token.coinGeckoId);
    })
  );
  return Array.from(ids);
}
