export interface NativeChainEndpointConfig {
  rpcUrl?: string;
  restUrl?: string;
  explorerUrl?: string;
}

export interface NativeExchangeEndpointConfig {
  baseUrl: string;
  accountPath?: string;
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
  configVersion: 3,
  updatedAt: "2026-07-12T00:00:00.000Z",
  refreshAfterSeconds: 21_600,
  minSupportedAppVersion: "0.2.0",
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
    gnosis: { rpcUrl: "https://rpc.gnosischain.com" },
    linea: { rpcUrl: "https://rpc.linea.build" },
    mantle: { rpcUrl: "https://rpc.mantle.xyz" },
    scroll: { rpcUrl: "https://rpc.scroll.io" },
    "zksync-era": { rpcUrl: "https://mainnet.era.zksync.io" },
    cosmoshub: { restUrl: "https://cosmos-api.polkachu.com" },
    osmosis: { restUrl: "https://lcd.osmosis.zone" },
    celestia: { restUrl: "https://celestia-api.polkachu.com" },
    stargaze: { restUrl: "https://rest.stargaze-apis.com" },
    stride: { restUrl: "https://stride-api.polkachu.com" }
  },
  // Exchange endpoints are credential-bearing security boundaries and are
  // intentionally NOT remotely configurable. The native binary owns its fixed
  // provider host/method/path allowlist; this field stays for schema compatibility.
  exchanges: {}
};

export function getNativeEndpointConfig(): NativeEndpointConfig {
  const envOverride = parseNativeConfigOverride(process.env.NATIVE_ENDPOINT_CONFIG_JSON);
  const config = mergeNativeConfig(DEFAULT_NATIVE_ENDPOINT_CONFIG, envOverride);
  return sanitizeNativeConfig({
    ...config,
    configVersion: numberFromEnv("NATIVE_ENDPOINT_CONFIG_VERSION", config.configVersion),
    updatedAt: process.env.NATIVE_ENDPOINT_CONFIG_UPDATED_AT || config.updatedAt,
    message: process.env.NATIVE_ENDPOINT_CONFIG_MESSAGE || config.message,
    minSupportedAppVersion:
      process.env.NATIVE_ENDPOINT_MIN_APP_VERSION || config.minSupportedAppVersion
  });
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
    priceBaseUrl: typeof override.priceBaseUrl === "string" ? override.priceBaseUrl : base.priceBaseUrl,
    chains: mergeKnownRecord(base.chains, override.chains),
    exchanges: {}
  };
}

function mergeKnownRecord<T>(base: Record<string, T>, override?: Record<string, Partial<T>>): Record<string, T> {
  const safeOverride = override && typeof override === "object" && !Array.isArray(override) ? override : undefined;
  return Object.fromEntries(
    Object.entries(base).map(([key, value]) => {
      const candidate = safeOverride?.[key];
      const fields = candidate && typeof candidate === "object" && !Array.isArray(candidate) ? candidate : {};
      return [key, { ...value, ...fields }];
    })
  ) as Record<string, T>;
}

function sanitizeNativeConfig(config: NativeEndpointConfig): NativeEndpointConfig {
  return {
    ...config,
    schemaVersion: 1,
    configVersion: boundedInteger(config.configVersion, DEFAULT_NATIVE_ENDPOINT_CONFIG.configVersion, 1, 2_000_000_000),
    updatedAt: isoDateOrFallback(config.updatedAt, DEFAULT_NATIVE_ENDPOINT_CONFIG.updatedAt),
    refreshAfterSeconds: boundedInteger(config.refreshAfterSeconds, 21_600, 300, 86_400),
    message: typeof config.message === "string" ? config.message.trim().slice(0, 500) || undefined : undefined,
    minSupportedAppVersion: semverOrUndefined(config.minSupportedAppVersion),
    priceBaseUrl: fixedPriceURL(config.priceBaseUrl, DEFAULT_NATIVE_ENDPOINT_CONFIG.priceBaseUrl),
    chains: Object.fromEntries(
      Object.entries(config.chains).map(([chainId, value]) => {
        const fallback = DEFAULT_NATIVE_ENDPOINT_CONFIG.chains[chainId] ?? {};
        return [chainId, {
          rpcUrl: sameOriginURL(value.rpcUrl, fallback.rpcUrl),
          restUrl: sameOriginURL(value.restUrl, fallback.restUrl),
          explorerUrl: sameOriginURL(value.explorerUrl, fallback.explorerUrl)
        }];
      })
    ),
    exchanges: {}
  };
}

function sameOriginURL(value: string | undefined, fallback: string | undefined) {
  if (!fallback) return undefined;
  if (!value) return fallback;
  try {
    const url = new URL(value);
    const bundled = new URL(fallback);
    if (
      url.protocol === "https:"
      && url.origin === bundled.origin
      && !url.username
      && !url.password
      && !url.hash
    ) {
      return value;
    }
  } catch {
    // Fall through to fallback.
  }
  return fallback ?? "";
}

function fixedPriceURL(value: string | undefined, fallback: string) {
  if (!value) return fallback;
  try {
    const url = new URL(value);
    const bundled = new URL(fallback);
    if (
      url.protocol === "https:"
      && url.origin === bundled.origin
      && url.pathname === bundled.pathname
      && !url.username
      && !url.password
      && !url.hash
      && !url.search
    ) {
      return value;
    }
  } catch {
    // Fall through to the bundled endpoint.
  }
  return fallback;
}

function numberFromEnv(name: string, fallback: number) {
  const parsed = Number(process.env[name]);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function boundedInteger(value: number, fallback: number, min: number, max: number) {
  return Number.isSafeInteger(value) && value >= min && value <= max ? value : fallback;
}

function isoDateOrFallback(value: unknown, fallback: string) {
  return typeof value === "string"
    && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/.test(value)
    && Number.isFinite(Date.parse(value))
    ? value
    : fallback;
}

// Only emit a well-formed dotted version (e.g. "1.2.3"); anything else is
// dropped so the native client never tries to enforce a garbage kill-switch.
function semverOrUndefined(value: unknown): string | undefined {
  if (typeof value !== "string" || !value) return undefined;
  return /^\d+(\.\d+){1,3}$/.test(value.trim()) ? value.trim() : undefined;
}
