import { afterEach, describe, expect, it, vi } from "vitest";
import { DEFAULT_NATIVE_ENDPOINT_CONFIG, getNativeEndpointConfig } from "./native-config";

describe("native endpoint config", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("returns bundled public endpoints without remotely-configurable exchanges", () => {
    const config = getNativeEndpointConfig();

    expect(config.schemaVersion).toBe(1);
    expect(config.configVersion).toBe(3);
    expect(config.minSupportedAppVersion).toBe("0.2.0");
    expect(config.priceBaseUrl).toBe("https://api.coingecko.com/api/v3/simple/price");
    expect(config.chains.ethereum.rpcUrl).toBe("https://eth.llamarpc.com");
    expect(config.chains.scroll.rpcUrl).toBe("https://rpc.scroll.io");
    expect(config.chains["zksync-era"].rpcUrl).toBe("https://mainnet.era.zksync.io");
    expect(config.exchanges).toEqual({});
  });

  it("allows only path changes on known bundled chain origins", () => {
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_VERSION", "7");
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_UPDATED_AT", "2026-05-09T12:00:00.000Z");
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_JSON", JSON.stringify({
      priceBaseUrl: "https://api.coingecko.com/api/v3/simple/price",
      chains: {
        ethereum: { rpcUrl: "https://eth.llamarpc.com/rpc" },
        unknown: { rpcUrl: "https://unknown.example/rpc" }
      },
      exchanges: {
        binance: { baseUrl: "https://evil.example", accountPath: "/0/private/CancelAll" }
      }
    }));

    const config = getNativeEndpointConfig();

    expect(config.configVersion).toBe(7);
    expect(config.updatedAt).toBe("2026-05-09T12:00:00.000Z");
    expect(config.priceBaseUrl).toBe(DEFAULT_NATIVE_ENDPOINT_CONFIG.priceBaseUrl);
    expect(config.chains.ethereum.rpcUrl).toBe("https://eth.llamarpc.com/rpc");
    expect(config.chains.solana.rpcUrl).toBe(DEFAULT_NATIVE_ENDPOINT_CONFIG.chains.solana.rpcUrl);
    expect(config.chains.unknown).toBeUndefined();
    expect(config.exchanges).toEqual({});
  });

  it("falls back on arbitrary origins, HTTP, credentials, fragments, and price queries", () => {
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_JSON", JSON.stringify({
      priceBaseUrl: "https://api.coingecko.com/api/v3/simple/price?redirect=evil",
      chains: {
        ethereum: { rpcUrl: "https://evil.example/rpc" },
        solana: { rpcUrl: "http://127.0.0.1:8899" },
        scroll: { rpcUrl: "https://user:password@rpc.scroll.io/private" },
        polygon: { rpcUrl: "https://polygon-rpc.com/path#fragment" }
      }
    }));

    const config = getNativeEndpointConfig();

    expect(config.priceBaseUrl).toBe(DEFAULT_NATIVE_ENDPOINT_CONFIG.priceBaseUrl);
    expect(config.chains.ethereum.rpcUrl).toBe(DEFAULT_NATIVE_ENDPOINT_CONFIG.chains.ethereum.rpcUrl);
    expect(config.chains.solana.rpcUrl).toBe(DEFAULT_NATIVE_ENDPOINT_CONFIG.chains.solana.rpcUrl);
    expect(config.chains.scroll.rpcUrl).toBe(DEFAULT_NATIVE_ENDPOINT_CONFIG.chains.scroll.rpcUrl);
    expect(config.chains.polygon.rpcUrl).toBe(DEFAULT_NATIVE_ENDPOINT_CONFIG.chains.polygon.rpcUrl);
  });
});
