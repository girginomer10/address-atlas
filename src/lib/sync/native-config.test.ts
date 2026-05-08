import { afterEach, describe, expect, it, vi } from "vitest";
import { DEFAULT_NATIVE_ENDPOINT_CONFIG, getNativeEndpointConfig } from "./native-config";

describe("native endpoint config", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("returns bundled defaults for the native app", () => {
    const config = getNativeEndpointConfig();

    expect(config.schemaVersion).toBe(1);
    expect(config.priceBaseUrl).toBe("https://api.coingecko.com/api/v3/simple/price");
    expect(config.chains.ethereum.rpcUrl).toBe("https://eth.llamarpc.com");
    expect(config.exchanges.binance.baseUrl).toBe("https://api.binance.com");
  });

  it("allows server-side endpoint overrides without changing the Mac app", () => {
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_VERSION", "7");
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_UPDATED_AT", "2026-05-09T12:00:00.000Z");
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_JSON", JSON.stringify({
      priceBaseUrl: "https://prices.example/simple/price",
      chains: {
        ethereum: { rpcUrl: "https://eth.example/rpc" }
      },
      exchanges: {
        binance: { baseUrl: "https://binance.example" }
      }
    }));

    const config = getNativeEndpointConfig();

    expect(config.configVersion).toBe(7);
    expect(config.updatedAt).toBe("2026-05-09T12:00:00.000Z");
    expect(config.priceBaseUrl).toBe("https://prices.example/simple/price");
    expect(config.chains.ethereum.rpcUrl).toBe("https://eth.example/rpc");
    expect(config.chains.solana.rpcUrl).toBe(DEFAULT_NATIVE_ENDPOINT_CONFIG.chains.solana.rpcUrl);
    expect(config.exchanges.binance.baseUrl).toBe("https://binance.example");
  });
});
