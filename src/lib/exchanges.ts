import { decryptFromVault } from "./security";
import { getPrices } from "./prices";
import {
  ExchangeCredentialInput,
  ExchangeProvider,
  ExchangeSnapshot,
  PricePoint,
  TrackedAsset
} from "./types";

type ExchangeBalance = {
  total?: Record<string, number | string | undefined>;
  free?: Record<string, number | string | undefined>;
  used?: Record<string, number | string | undefined>;
};

type StoredExchangeConnection = {
  id: string;
  provider: string;
  label: string;
  encryptedCredentials: string;
};

type StoredCredentials = {
  apiKey: string;
  secret: string;
  passphrase?: string;
};

const PROVIDER_LABELS: Record<ExchangeProvider, string> = {
  binance: "Binance",
  coinbase: "Coinbase",
  kraken: "Kraken"
};

const EXCHANGE_ASSET_COIN_IDS: Record<string, string> = {
  AAVE: "aave",
  ADA: "cardano",
  ATOM: "cosmos",
  AVAX: "avalanche-2",
  BCH: "bitcoin-cash",
  BNB: "binancecoin",
  BTC: "bitcoin",
  DAI: "dai",
  DOGE: "dogecoin",
  DOT: "polkadot",
  ETH: "ethereum",
  EURC: "euro-coin",
  JUP: "jupiter-exchange-solana",
  LINK: "chainlink",
  LTC: "litecoin",
  MATIC: "matic-network",
  OP: "optimism",
  OSMO: "osmosis",
  POL: "polygon-ecosystem-token",
  SOL: "solana",
  STRD: "stride",
  TIA: "celestia",
  UNI: "uniswap",
  USDC: "usd-coin",
  USDT: "tether",
  XLM: "stellar",
  XRP: "ripple"
};

const USD_STABLES = new Set(["USD", "USDC", "USDT", "BUSD", "FDUSD", "TUSD", "USDP", "DAI"]);

export const EXCHANGE_PROVIDERS = Object.entries(PROVIDER_LABELS).map(([id, label]) => ({
  id: id as ExchangeProvider,
  label
}));

export function exchangeProviderLabel(provider: ExchangeProvider | string) {
  return PROVIDER_LABELS[provider as ExchangeProvider] ?? provider;
}

export function assertExchangeProvider(provider: string): asserts provider is ExchangeProvider {
  if (!["binance", "coinbase", "kraken"].includes(provider)) {
    throw new Error("Unsupported exchange provider.");
  }
}

export async function testExchangeCredentials(input: ExchangeCredentialInput) {
  assertExchangeProvider(input.provider);
  const credentials = credentialsFromInput(input);
  const balance = await fetchCcxtBalance(input.provider, credentials);
  const holdings = await normalizeExchangeBalance({
    id: "test",
    provider: input.provider,
    label: input.label || exchangeProviderLabel(input.provider),
    balance
  });

  return {
    provider: input.provider,
    label: input.label || exchangeProviderLabel(input.provider),
    holdingCount: holdings.length,
    totalUsd: holdings.reduce((sum, holding) => sum + holding.valueUsd, 0)
  };
}

export async function fetchExchangeSnapshot(
  connection: StoredExchangeConnection,
  vaultPassphrase: string
): Promise<ExchangeSnapshot> {
  assertExchangeProvider(connection.provider);

  try {
    const credentials = await decryptFromVault<StoredCredentials>(
      connection.encryptedCredentials,
      vaultPassphrase
    );
    const balance = await fetchCcxtBalance(connection.provider, credentials);
    const holdings = await normalizeExchangeBalance({
      id: connection.id,
      provider: connection.provider,
      label: connection.label,
      balance
    });

    return {
      connectionId: connection.id,
      provider: connection.provider,
      label: connection.label,
      generatedAt: new Date().toISOString(),
      totalUsd: holdings.reduce((sum, holding) => sum + holding.valueUsd, 0),
      status: "ok",
      holdings
    };
  } catch (error) {
    return {
      connectionId: connection.id,
      provider: connection.provider,
      label: connection.label,
      generatedAt: new Date().toISOString(),
      totalUsd: 0,
      status: "failed",
      holdings: [],
      error: error instanceof Error ? error.message : "Exchange balance fetch failed."
    };
  }
}

export function credentialsFromInput(input: ExchangeCredentialInput): StoredCredentials {
  if (!input.apiKey.trim() || !input.secret.trim()) {
    throw new Error("API key and secret are required.");
  }

  return {
    apiKey: input.apiKey.trim(),
    secret: input.secret.trim(),
    passphrase: input.passphrase?.trim() || undefined
  };
}

async function fetchCcxtBalance(provider: ExchangeProvider, credentials: StoredCredentials) {
  const ccxt = await import("ccxt");
  const moduleValue = ccxt.default ?? ccxt;
  const ExchangeClass = (moduleValue as unknown as Record<string, new (config: unknown) => unknown>)[provider];

  if (!ExchangeClass) {
    throw new Error(`${exchangeProviderLabel(provider)} is not available in ccxt.`);
  }

  const exchange = new ExchangeClass({
    apiKey: credentials.apiKey,
    secret: credentials.secret,
    password: credentials.passphrase,
    enableRateLimit: true,
    options: {
      defaultType: "spot"
    }
  }) as {
    has?: Record<string, boolean>;
    loadMarkets?: () => Promise<void>;
    fetchBalance: () => Promise<ExchangeBalance>;
  };

  if (exchange.has && exchange.has.fetchBalance === false) {
    throw new Error(`${exchangeProviderLabel(provider)} does not expose fetchBalance through ccxt.`);
  }

  if (exchange.loadMarkets) {
    await exchange.loadMarkets();
  }

  return exchange.fetchBalance();
}

export async function normalizeExchangeBalance({
  id,
  provider,
  label,
  balance
}: {
  id: string;
  provider: ExchangeProvider;
  label: string;
  balance: ExchangeBalance;
}) {
  const entries = balanceEntries(balance);
  const priceIds = entries
    .filter(([symbol]) => !USD_STABLES.has(symbol))
    .map(([symbol]) => EXCHANGE_ASSET_COIN_IDS[symbol])
    .filter(Boolean);
  const prices = await getPrices(priceIds);

  return entries.map(([symbol, amount]) => {
    const coinId = EXCHANGE_ASSET_COIN_IDS[symbol];
    const price = priceForSymbol(symbol, coinId ? prices[coinId] : undefined);
    const valueUsd = amount * price.usd;

    return {
      id: `${id}-${provider}-${symbol}`,
      address: label,
      chainId: provider,
      chainName: exchangeProviderLabel(provider),
      family: "exchange",
      symbol,
      name: symbol,
      amount,
      priceUsd: price.usd,
      valueUsd,
      change24h: price.usd_24h_change,
      explorerUrl: "",
      source: "exchange",
      status: "ok",
      walletLabel: label,
      exchangeId: id,
      exchangeProvider: provider
    } satisfies TrackedAsset;
  });
}

function balanceEntries(balance: ExchangeBalance) {
  const source = Object.keys(balance.total ?? {}).length > 0 ? balance.total : balance.free;

  return Object.entries(source ?? {})
    .map(([symbol, rawAmount]) => [normalizeSymbol(symbol), Number(rawAmount)] as const)
    .filter(([symbol, amount]) => symbol && Number.isFinite(amount) && amount > 0)
    .sort((a, b) => a[0].localeCompare(b[0]));
}

function normalizeSymbol(symbol: string) {
  return symbol.replace(/^XBT$/i, "BTC").replace(/^ZEUR$/i, "EUR").replace(/^ZUSD$/i, "USD").toUpperCase();
}

function priceForSymbol(symbol: string, price?: PricePoint): PricePoint {
  if (USD_STABLES.has(symbol)) return { usd: 1, usd_24h_change: 0 };
  return price ?? { usd: 0 };
}
