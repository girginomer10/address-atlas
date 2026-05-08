export interface NativeChainEndpointConfig {
  rpcUrl?: string;
  restUrl?: string;
  explorerUrl?: string;
}

export interface NativeExchangeEndpointConfig {
  baseUrl: string;
}

export interface NativeEndpointConfig {
  schemaVersion: number;
  configVersion: number;
  updatedAt: string;
  refreshAfterSeconds: number;
  minSupportedAppVersion?: string;
  message?: string;
  priceBaseUrl: string;
  chains: Record<string, NativeChainEndpointConfig>;
  exchanges: Record<string, NativeExchangeEndpointConfig>;
}

export const DEFAULT_NATIVE_ENDPOINT_CONFIG: NativeEndpointConfig = {
  schemaVersion: 1,
  configVersion: 1,
  updatedAt: "2026-05-09T00:00:00.000Z",
  refreshAfterSeconds: 21_600,
  priceBaseUrl: "https://api.coingecko.com/api/v3/simple/price",
  chains: {
    bitcoin: { restUrl: "https://blockstream.info/api" },
    solana: { rpcUrl: "https://api.mainnet-beta.solana.com" },
    tron: { restUrl: "https://api.trongrid.io" },
    xrp: { rpcUrl: "https://s1.ripple.com:51234/" },
    ethereum: { rpcUrl: "https://eth.llamarpc.com" },
    base: { rpcUrl: "https://mainnet.base.org" },
    arbitrum: { rpcUrl: "https://arb1.arbitrum.io/rpc" },
    optimism: { rpcUrl: "https://mainnet.optimism.io" },
    polygon: { rpcUrl: "https://polygon-rpc.com" },
    bsc: { rpcUrl: "https://bsc-dataseed.binance.org" },
    avalanche: { rpcUrl: "https://api.avax.network/ext/bc/C/rpc" },
    cosmoshub: { restUrl: "https://cosmos-api.polkachu.com" },
    osmosis: { restUrl: "https://lcd.osmosis.zone" },
    celestia: { restUrl: "https://celestia-api.polkachu.com" },
    stargaze: { restUrl: "https://rest.stargaze-apis.com" },
    stride: { restUrl: "https://stride-api.polkachu.com" }
  },
  exchanges: {
    binance: { baseUrl: "https://api.binance.com" },
    coinbase: { baseUrl: "https://api.coinbase.com" },
    kraken: { baseUrl: "https://api.kraken.com" }
  }
};

export function getNativeEndpointConfig(): NativeEndpointConfig {
  const envOverride = parseNativeConfigOverride(process.env.NATIVE_ENDPOINT_CONFIG_JSON);
  const config = mergeNativeConfig(DEFAULT_NATIVE_ENDPOINT_CONFIG, envOverride);
  return {
    ...config,
    configVersion: numberFromEnv("NATIVE_ENDPOINT_CONFIG_VERSION", config.configVersion),
    updatedAt: process.env.NATIVE_ENDPOINT_CONFIG_UPDATED_AT || config.updatedAt,
    message: process.env.NATIVE_ENDPOINT_CONFIG_MESSAGE || config.message
  };
}

function parseNativeConfigOverride(raw: string | undefined) {
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return {};
    }
    return parsed as Partial<NativeEndpointConfig>;
  } catch {
    return {};
  }
}

function mergeNativeConfig(base: NativeEndpointConfig, override: Partial<NativeEndpointConfig>): NativeEndpointConfig {
  return {
    ...base,
    ...override,
    schemaVersion: override.schemaVersion ?? base.schemaVersion,
    configVersion: override.configVersion ?? base.configVersion,
    updatedAt: override.updatedAt ?? base.updatedAt,
    refreshAfterSeconds: override.refreshAfterSeconds ?? base.refreshAfterSeconds,
    priceBaseUrl: override.priceBaseUrl ?? base.priceBaseUrl,
    chains: {
      ...base.chains,
      ...override.chains
    },
    exchanges: {
      ...base.exchanges,
      ...override.exchanges
    }
  };
}

function numberFromEnv(name: string, fallback: number) {
  const parsed = Number(process.env[name]);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}
