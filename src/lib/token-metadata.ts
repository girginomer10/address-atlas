import {
  ERC20_TOKENS_BY_CHAIN,
  EVM_CHAINS,
  SOLANA_CHAIN,
  SPL_TOKENS_BY_CHAIN
} from "./chain-registry";

const REQUEST_TIMEOUT_MS = 8_000;

export interface TokenMetadataLookupInput {
  chainKind?: string;
  chainId?: string;
  address?: string;
}

export interface TokenMetadataResult {
  chainKind: "evm" | "solana";
  chainId: string;
  address: string;
  symbol: string;
  name: string;
  decimals: number;
  priceUsd?: number | null;
  coinGeckoSuggestions: CoinGeckoSuggestion[];
  source: "registry" | "rpc" | "jupiter" | "mixed";
}

export interface CoinGeckoSuggestion {
  id: string;
  name: string;
  symbol: string;
  marketCapRank: number | null;
}

export async function lookupTokenMetadata(input: TokenMetadataLookupInput): Promise<TokenMetadataResult> {
  const chainKind = (input.chainKind ?? "evm").trim().toLowerCase();
  const chainId = (input.chainId ?? "").trim().toLowerCase();
  const address = (input.address ?? "").trim();

  if (chainKind === "evm") return lookupEvmTokenMetadata(chainId, address);
  if (chainKind === "solana") return lookupSolanaTokenMetadata(chainId, address);

  throw new Error("Unsupported token chain.");
}

async function lookupEvmTokenMetadata(chainId: string, address: string): Promise<TokenMetadataResult> {
  const chain = EVM_CHAINS.find((item) => item.id === chainId);
  if (!chain?.rpcUrl) throw new Error("Unknown EVM chain.");
  if (!/^0x[a-fA-F0-9]{40}$/.test(address)) {
    throw new Error("Enter a valid EVM contract address.");
  }

  const normalizedAddress = address.toLowerCase();
  const builtin = (ERC20_TOKENS_BY_CHAIN[chain.id] ?? []).find(
    (token) => token.address.toLowerCase() === normalizedAddress
  );
  if (builtin) {
    return {
      chainKind: "evm",
      chainId: chain.id,
      address: normalizedAddress,
      symbol: builtin.symbol,
      name: builtin.name,
      decimals: builtin.decimals,
      priceUsd: builtin.priceUsd ?? null,
      coinGeckoSuggestions: await searchCoinGecko(builtin.symbol || builtin.name),
      source: "registry"
    };
  }

  const [symbol, name, decimals] = await Promise.all([
    readErc20String(chain.rpcUrl, normalizedAddress, "0x95d89b41"),
    readErc20String(chain.rpcUrl, normalizedAddress, "0x06fdde03"),
    readErc20Decimals(chain.rpcUrl, normalizedAddress)
  ]);
  const suggestions = await searchCoinGecko(symbol || name);

  return {
    chainKind: "evm",
    chainId: chain.id,
    address: normalizedAddress,
    symbol: symbol || "",
    name: name || symbol || "",
    decimals,
    priceUsd: null,
    coinGeckoSuggestions: suggestions,
    source: "rpc"
  };
}

async function lookupSolanaTokenMetadata(chainId: string, mint: string): Promise<TokenMetadataResult> {
  if (chainId !== SOLANA_CHAIN.id || !SOLANA_CHAIN.rpcUrl) throw new Error("Unknown Solana chain.");
  if (!/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(mint)) {
    throw new Error("Enter a valid Solana mint address.");
  }

  const builtin = (SPL_TOKENS_BY_CHAIN[SOLANA_CHAIN.id] ?? []).find((token) => token.mint === mint);
  if (builtin) {
    return {
      chainKind: "solana",
      chainId: SOLANA_CHAIN.id,
      address: mint,
      symbol: builtin.symbol,
      name: builtin.name,
      decimals: builtin.decimals,
      priceUsd: builtin.priceUsd ?? null,
      coinGeckoSuggestions: await searchCoinGecko(builtin.symbol || builtin.name),
      source: "registry"
    };
  }

  const jupiter = await lookupJupiterToken(mint);
  const result = await rpcCall<{
    value?: {
      data?: {
        parsed?: {
          info?: {
            decimals?: unknown;
          };
        };
      };
    };
  }>(SOLANA_CHAIN.rpcUrl, "getAccountInfo", [
    mint,
    { encoding: "jsonParsed", commitment: "confirmed" }
  ]);

  const decimals = result?.value?.data?.parsed?.info?.decimals;
  if (typeof decimals !== "number" || !Number.isInteger(decimals)) {
    throw new Error("Solana mint metadata did not include decimals.");
  }
  const symbol = jupiter?.symbol ?? "";
  const name = jupiter?.name ?? "";
  const suggestions = await searchCoinGecko(symbol || name);

  return {
    chainKind: "solana",
    chainId: SOLANA_CHAIN.id,
    address: mint,
    symbol,
    name,
    decimals: typeof jupiter?.decimals === "number" ? jupiter.decimals : decimals,
    priceUsd: jupiter?.usdPrice ?? null,
    coinGeckoSuggestions: suggestions,
    source: jupiter ? "mixed" : "rpc"
  };
}

interface JupiterToken {
  id?: unknown;
  name?: unknown;
  symbol?: unknown;
  decimals?: unknown;
  usdPrice?: unknown;
}

async function lookupJupiterToken(mint: string) {
  const apiKey = process.env.JUPITER_API_KEY?.trim();
  if (!apiKey) return null;

  try {
    const url = new URL("https://api.jup.ag/tokens/v2/search");
    url.searchParams.set("query", mint);
    const tokens = await fetchJson<JupiterToken[]>(url.toString(), {
      headers: {
        "x-api-key": apiKey
      }
    });
    const match = tokens.find((token) => token.id === mint) ?? tokens[0];
    if (!match) return null;
    const symbol = typeof match.symbol === "string" ? match.symbol : "";
    const name = typeof match.name === "string" ? match.name : "";
    const decimals = typeof match.decimals === "number" && Number.isInteger(match.decimals)
      ? match.decimals
      : undefined;
    const usdPrice = typeof match.usdPrice === "number" && Number.isFinite(match.usdPrice)
      ? match.usdPrice
      : null;
    return { symbol, name, decimals, usdPrice };
  } catch {
    return null;
  }
}

interface CoinGeckoSearchResponse {
  coins?: {
    id?: unknown;
    name?: unknown;
    symbol?: unknown;
    market_cap_rank?: unknown;
  }[];
}

async function searchCoinGecko(query: string) {
  const trimmed = query.trim();
  if (!trimmed) return [];

  try {
    const url = new URL("https://api.coingecko.com/api/v3/search");
    url.searchParams.set("query", trimmed);
    const body = await fetchJson<CoinGeckoSearchResponse>(url.toString());
    return (body.coins ?? [])
      .map((coin) => ({
        id: typeof coin.id === "string" ? coin.id : "",
        name: typeof coin.name === "string" ? coin.name : "",
        symbol: typeof coin.symbol === "string" ? coin.symbol.toUpperCase() : "",
        marketCapRank: typeof coin.market_cap_rank === "number" ? coin.market_cap_rank : null
      }))
      .filter((coin) => coin.id && coin.name && coin.symbol)
      .sort((left, right) => suggestionScore(left, trimmed) - suggestionScore(right, trimmed))
      .slice(0, 5);
  } catch {
    return [];
  }
}

function suggestionScore(suggestion: CoinGeckoSuggestion, query: string) {
  const normalized = query.trim().toLowerCase();
  const exactSymbol = suggestion.symbol.toLowerCase() === normalized ? 0 : 10;
  const exactName = suggestion.name.toLowerCase() === normalized ? 0 : 5;
  const rank = suggestion.marketCapRank ?? 100_000;
  return exactSymbol + exactName + rank / 100_000;
}

async function readErc20String(rpcUrl: string, address: string, selector: `0x${string}`) {
  try {
    const result = await ethCall(rpcUrl, address, selector);
    return decodeAbiString(result);
  } catch {
    return "";
  }
}

async function readErc20Decimals(rpcUrl: string, address: string) {
  const result = await ethCall(rpcUrl, address, "0x313ce567");
  const value = Number(BigInt(result));
  if (!Number.isInteger(value) || value < 0 || value > 36) {
    throw new Error("Token decimals are outside the supported range.");
  }
  return value;
}

async function ethCall(rpcUrl: string, to: string, data: `0x${string}`) {
  return rpcCall<string>(rpcUrl, "eth_call", [{ to, data }, "latest"]);
}

async function rpcCall<T>(rpcUrl: string, method: string, params: unknown[]): Promise<T> {
  const body = await fetchJson<{ result?: T; error?: { message?: string } }>(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method,
      params
    })
  });

  if (body.error) throw new Error(body.error.message || "RPC error");
  if (body.result === undefined || body.result === null) throw new Error("Empty RPC response");
  return body.result;
}

async function fetchJson<T>(url: string, init: RequestInit = {}): Promise<T> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

  try {
    const response = await fetch(url, {
      ...init,
      signal: controller.signal,
      headers: {
        accept: "application/json",
        ...(init.headers ?? {})
      }
    });
    if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
    return (await response.json()) as T;
  } finally {
    clearTimeout(timeout);
  }
}

function decodeAbiString(hex: string) {
  const clean = hex.replace(/^0x/, "");
  if (!clean || /^0+$/.test(clean)) return "";

  const dynamic = decodeDynamicAbiString(clean);
  if (dynamic) return dynamic;

  return decodeBytes(clean.slice(0, 64));
}

function decodeDynamicAbiString(clean: string) {
  if (clean.length < 128) return "";
  const length = Number(BigInt(`0x${clean.slice(64, 128)}`));
  if (!Number.isFinite(length) || length <= 0 || length > 256) return "";
  return decodeBytes(clean.slice(128, 128 + length * 2));
}

function decodeBytes(clean: string) {
  const bytes = clean
    .match(/.{1,2}/g)
    ?.map((part) => Number.parseInt(part, 16))
    .filter((value) => value > 0) ?? [];
  return new TextDecoder().decode(new Uint8Array(bytes)).trim();
}
