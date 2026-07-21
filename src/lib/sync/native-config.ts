import { OperationalError } from "./diagnostics";

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

export class NativeConfigError extends OperationalError {
  constructor(message: string) {
    super("native_config_invalid", message);
    this.name = "NativeConfigError";
  }
}

const BUNDLED_NATIVE_ENDPOINT_CONFIG_VERSION = 5;

export const DEFAULT_NATIVE_ENDPOINT_CONFIG: NativeEndpointConfig = {
  schemaVersion: 1,
  configVersion: BUNDLED_NATIVE_ENDPOINT_CONFIG_VERSION,
  updatedAt: "2026-07-14T00:00:00.000Z",
  refreshAfterSeconds: 21_600,
  minSupportedAppVersion: "0.2.0",
  priceBaseUrl: "https://api.coingecko.com/api/v3/simple/price",
  chains: {
    bitcoin: { restUrl: "https://blockstream.info/api" },
    solana: { rpcUrl: "https://api.mainnet-beta.solana.com" },
    tron: { restUrl: "https://api.trongrid.io" },
    xrp: { rpcUrl: "https://s1.ripple.com:51234/" },
    ethereum: { rpcUrl: "https://ethereum-rpc.publicnode.com" },
    base: { rpcUrl: "https://mainnet.base.org" },
    arbitrum: { rpcUrl: "https://arb1.arbitrum.io/rpc" },
    optimism: { rpcUrl: "https://mainnet.optimism.io" },
    polygon: { rpcUrl: "https://polygon.drpc.org" },
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
    stride: { restUrl: "https://stride-api.polkachu.com" }
  },
  // Exchange endpoints are credential-bearing security boundaries and are
  // intentionally NOT remotely configurable. The native binary owns its fixed
  // provider host/method/path allowlist; this field stays for schema compatibility.
  exchanges: {}
};

const NATIVE_CONFIG_KEYS = new Set([
  "schemaVersion",
  "configVersion",
  "updatedAt",
  "refreshAfterSeconds",
  "minSupportedAppVersion",
  "message",
  "priceBaseUrl",
  "chains",
  "exchanges"
]);
const CHAIN_ENDPOINT_KEYS = new Set(["rpcUrl", "restUrl", "explorerUrl"]);
const APP_VERSION_MIN_COMPONENTS = 2;
const APP_VERSION_MAX_COMPONENTS = 4;
const APP_VERSION_MAX_COMPONENT = 2_000_000_000;
const APP_VERSION_MAX_COMPONENT_DIGITS = 10;

export function getNativeEndpointConfig(): NativeEndpointConfig {
  const envOverride = parseNativeConfigOverride(process.env.NATIVE_ENDPOINT_CONFIG_JSON);
  const config = mergeNativeConfig(DEFAULT_NATIVE_ENDPOINT_CONFIG, envOverride);
  return sanitizeNativeConfig({
    ...config,
    configVersion: integerFromEnv(
      "NATIVE_ENDPOINT_CONFIG_VERSION",
      config.configVersion,
      BUNDLED_NATIVE_ENDPOINT_CONFIG_VERSION,
      2_000_000_000
    ),
    updatedAt: isoDateFromEnv("NATIVE_ENDPOINT_CONFIG_UPDATED_AT", config.updatedAt),
    message: process.env.NATIVE_ENDPOINT_CONFIG_MESSAGE || config.message,
    minSupportedAppVersion: semverFromEnv("NATIVE_ENDPOINT_MIN_APP_VERSION", config.minSupportedAppVersion)
  });
}

function parseNativeConfigOverride(raw: string | undefined) {
  if (raw === undefined || !raw.trim()) return {};
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new NativeConfigError("NATIVE_ENDPOINT_CONFIG_JSON must contain a JSON object.");
    }
    validateNativeConfigOverride(parsed as Partial<NativeEndpointConfig>);
    return parsed as Partial<NativeEndpointConfig>;
  } catch (error) {
    if (error instanceof NativeConfigError) throw error;
    throw new NativeConfigError("NATIVE_ENDPOINT_CONFIG_JSON must contain valid JSON.");
  }
}

function validateNativeConfigOverride(value: Partial<NativeEndpointConfig>) {
  const unknownKey = Object.keys(value).find((key) => !NATIVE_CONFIG_KEYS.has(key));
  if (unknownKey) {
    throw new NativeConfigError(`Native endpoint config contains unknown field ${unknownKey}.`);
  }
  if (value.schemaVersion !== undefined && value.schemaVersion !== 1) {
    throw new NativeConfigError("Native endpoint schemaVersion must be 1.");
  }
  if (
    value.configVersion !== undefined
    && !isBoundedInteger(value.configVersion, BUNDLED_NATIVE_ENDPOINT_CONFIG_VERSION, 2_000_000_000)
  ) {
    throw new NativeConfigError("Native endpoint configVersion is invalid.");
  }
  if (value.updatedAt !== undefined && !isISODate(value.updatedAt)) {
    throw new NativeConfigError("Native endpoint updatedAt is invalid.");
  }
  if (value.refreshAfterSeconds !== undefined && !isBoundedInteger(value.refreshAfterSeconds, 300, 86_400)) {
    throw new NativeConfigError("Native endpoint refreshAfterSeconds is invalid.");
  }
  if (
    value.minSupportedAppVersion !== undefined
    && (
      typeof value.minSupportedAppVersion !== "string"
      || semverOrUndefined(value.minSupportedAppVersion) !== value.minSupportedAppVersion.trim()
    )
  ) {
    throw new NativeConfigError("Native endpoint minSupportedAppVersion is invalid.");
  }
  if (value.message !== undefined && (typeof value.message !== "string" || value.message.length > 500)) {
    throw new NativeConfigError("Native endpoint message must be a string of at most 500 characters.");
  }
  if (
    value.priceBaseUrl !== undefined
    && (typeof value.priceBaseUrl !== "string" || !isFixedPriceURL(value.priceBaseUrl, DEFAULT_NATIVE_ENDPOINT_CONFIG.priceBaseUrl))
  ) {
    throw new NativeConfigError("Native endpoint priceBaseUrl must match the bundled HTTPS price endpoint.");
  }
  if (value.exchanges !== undefined && !isPlainRecord(value.exchanges)) {
    throw new NativeConfigError("Native endpoint exchanges must be an object.");
  }
  if (value.chains !== undefined && !isPlainRecord(value.chains)) {
    throw new NativeConfigError("Native endpoint chains must be an object.");
  }
  for (const [chainId, candidate] of Object.entries(value.chains ?? {})) {
    if (!Object.hasOwn(DEFAULT_NATIVE_ENDPOINT_CONFIG.chains, chainId)) {
      throw new NativeConfigError(`Native endpoint config contains unknown chain ${chainId}.`);
    }
    const bundled = DEFAULT_NATIVE_ENDPOINT_CONFIG.chains[chainId]!;
    if (!isPlainRecord(candidate)) {
      throw new NativeConfigError(`Native endpoint chain ${chainId} must be an object.`);
    }
    for (const [field, endpoint] of Object.entries(candidate)) {
      if (!CHAIN_ENDPOINT_KEYS.has(field) || !(field in bundled)) {
        throw new NativeConfigError(`Native endpoint chain ${chainId} contains unsupported field ${field}.`);
      }
      const fallback = bundled[field as keyof NativeChainEndpointConfig];
      if (typeof endpoint !== "string" || !isSameOriginURL(endpoint, fallback)) {
        throw new NativeConfigError(`Native endpoint ${chainId}.${field} is not an allowed HTTPS URL.`);
      }
    }
  }
}

function mergeNativeConfig(base: NativeEndpointConfig, override: Partial<NativeEndpointConfig>): NativeEndpointConfig {
  return {
    schemaVersion: override.schemaVersion ?? base.schemaVersion,
    configVersion: override.configVersion ?? base.configVersion,
    updatedAt: override.updatedAt ?? base.updatedAt,
    refreshAfterSeconds: override.refreshAfterSeconds ?? base.refreshAfterSeconds,
    minSupportedAppVersion: override.minSupportedAppVersion ?? base.minSupportedAppVersion,
    message: override.message ?? base.message,
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
    schemaVersion: 1,
    configVersion: boundedInteger(
      config.configVersion,
      DEFAULT_NATIVE_ENDPOINT_CONFIG.configVersion,
      BUNDLED_NATIVE_ENDPOINT_CONFIG_VERSION,
      2_000_000_000
    ),
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
  return isSameOriginURL(value, fallback) ? value : fallback;
}

function isSameOriginURL(value: string, fallback: string | undefined) {
  if (!fallback) return false;
  try {
    const url = new URL(value);
    const bundled = new URL(fallback);
    if (
      url.protocol === "https:"
      && url.origin === bundled.origin
      && !url.username
      && !url.password
      && !url.search
      && !url.hash
    ) {
      return true;
    }
  } catch {
    // Invalid URL.
  }
  return false;
}

function fixedPriceURL(value: string | undefined, fallback: string) {
  if (!value) return fallback;
  return isFixedPriceURL(value, fallback) ? value : fallback;
}

function isFixedPriceURL(value: string, fallback: string) {
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
      return true;
    }
  } catch {
    // Invalid URL.
  }
  return false;
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function integerFromEnv(name: string, fallback: number, min: number, max: number) {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  const parsed = Number(raw);
  if (!raw.trim() || !isBoundedInteger(parsed, min, max)) {
    throw new NativeConfigError(`${name} must be an integer between ${min} and ${max}.`);
  }
  return parsed;
}

function isoDateFromEnv(name: string, fallback: string) {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  if (!isISODate(raw)) throw new NativeConfigError(`${name} must be an ISO-8601 UTC timestamp.`);
  return raw;
}

function semverFromEnv(name: string, fallback: string | undefined) {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  const parsed = semverOrUndefined(raw);
  if (!parsed) throw new NativeConfigError(`${name} must be a dotted numeric version.`);
  return parsed;
}

function boundedInteger(value: number, fallback: number, min: number, max: number) {
  return Number.isSafeInteger(value) && value >= min && value <= max ? value : fallback;
}

function isBoundedInteger(value: unknown, min: number, max: number): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= min && value <= max;
}

function isoDateOrFallback(value: unknown, fallback: string) {
  return isISODate(value) ? value : fallback;
}

function isISODate(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?Z$/.exec(value);
  if (!match) return false;
  const parsed = new Date(value);
  if (!Number.isFinite(parsed.getTime())) return false;
  const [, year, month, day, hour, minute, second] = match;
  return parsed.getUTCFullYear() === Number(year)
    && parsed.getUTCMonth() + 1 === Number(month)
    && parsed.getUTCDate() === Number(day)
    && parsed.getUTCHours() === Number(hour)
    && parsed.getUTCMinutes() === Number(minute)
    && parsed.getUTCSeconds() === Number(second);
}

// Keep this grammar and component ceiling in sync with
// NativeEndpointConfig.appVersionComponents(_:). A compatibility policy must
// never contain a component that the native Int parser cannot represent.
function semverOrUndefined(value: unknown): string | undefined {
  if (typeof value !== "string" || !value) return undefined;
  if (value !== value.trim()) return undefined;
  const components = value.split(".");
  if (components.length < APP_VERSION_MIN_COMPONENTS || components.length > APP_VERSION_MAX_COMPONENTS) {
    return undefined;
  }
  for (const component of components) {
    if (
      component.length < 1
      || component.length > APP_VERSION_MAX_COMPONENT_DIGITS
      || !/^[0-9]+$/.test(component)
    ) {
      return undefined;
    }
    const parsed = Number(component);
    if (!Number.isSafeInteger(parsed) || parsed < 0 || parsed > APP_VERSION_MAX_COMPONENT) {
      return undefined;
    }
  }
  return value;
}
