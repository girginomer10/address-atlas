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
        ethereum: { rpcUrl: "https://eth.llamarpc.com/rpc" }
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

  it.each([
    [{ priceBaseUrl: "https://api.coingecko.com/api/v3/simple/price?redirect=evil" }, /priceBaseUrl/i],
    [{ chains: { ethereum: { rpcUrl: "https://evil.example/rpc" } } }, /ethereum\.rpcUrl/i],
    [{ chains: { solana: { rpcUrl: "http://127.0.0.1:8899" } } }, /solana\.rpcUrl/i],
    [{ chains: { scroll: { rpcUrl: "https://user:password@rpc.scroll.io/private" } } }, /scroll\.rpcUrl/i],
    [{ chains: { polygon: { rpcUrl: "https://polygon-rpc.com/path#fragment" } } }, /polygon\.rpcUrl/i],
    [{ chains: { ethereum: { rpcUrl: "https://eth.llamarpc.com/rpc?network=other" } } }, /ethereum\.rpcUrl/i]
  ])("rejects an explicitly unsafe endpoint override", (override, message) => {
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_JSON", JSON.stringify(override));
    expect(() => getNativeEndpointConfig()).toThrow(message);
  });

  it.each([
    [{ apiKey: "must-never-be-public" }, /unknown field apiKey/i],
    [{ chains: { etheruem: { rpcUrl: "https://eth.llamarpc.com" } } }, /unknown chain etheruem/i],
    [{ chains: { ethereum: [] } }, /ethereum must be an object/i],
    [{ chains: { ethereum: "https://eth.llamarpc.com" } }, /ethereum must be an object/i],
    [{ chains: { ethereum: { restUrl: "https://eth.llamarpc.com" } } }, /unsupported field restUrl/i]
  ])("rejects unknown or malformed nested config instead of silently falling back", (override, message) => {
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_JSON", JSON.stringify(override));
    expect(() => getNativeEndpointConfig()).toThrow(message);
  });

  it.each([
    ["NATIVE_ENDPOINT_CONFIG_JSON", "not-json"],
    ["NATIVE_ENDPOINT_CONFIG_JSON", "[]"],
    ["NATIVE_ENDPOINT_CONFIG_VERSION", "3.5"],
    ["NATIVE_ENDPOINT_CONFIG_UPDATED_AT", "not-a-date"],
    ["NATIVE_ENDPOINT_MIN_APP_VERSION", "latest"]
  ])("rejects an invalid explicit %s value", (name, value) => {
    vi.stubEnv(name, value);
    expect(() => getNativeEndpointConfig()).toThrow(/native|config|version|timestamp|json/i);
  });

  it("rejects malformed typed fields inside a JSON override", () => {
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_JSON", JSON.stringify({
      configVersion: "7",
      refreshAfterSeconds: 1
    }));

    expect(() => getNativeEndpointConfig()).toThrow(/configVersion|refreshAfter/i);
  });

  it("uses the native bounded dotted-version grammar for compatibility policy", () => {
    vi.stubEnv("NATIVE_ENDPOINT_MIN_APP_VERSION", "2000000000.0.0.0");
    expect(getNativeEndpointConfig().minSupportedAppVersion).toBe("2000000000.0.0.0");

    for (const value of [
      "2000000001.0",
      "999999999999999999999999999999.0",
      "1",
      "1..2",
      "1.2.3.4.5",
      " 1.2.3 "
    ]) {
      vi.stubEnv("NATIVE_ENDPOINT_MIN_APP_VERSION", value);
      expect(() => getNativeEndpointConfig()).toThrow(/version/i);
    }
  });

  it("rejects oversized compatibility components in JSON overrides", () => {
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_JSON", JSON.stringify({
      minSupportedAppVersion: "9223372036854775808.0"
    }));

    expect(() => getNativeEndpointConfig()).toThrow(/minSupportedAppVersion/i);
  });

  it.each(["__proto__", "constructor", "prototype"])(
    "rejects prototype-like chain key %s instead of reading inherited properties",
    (chainId) => {
      vi.stubEnv("NATIVE_ENDPOINT_CONFIG_JSON", `{"chains":{"${chainId}":{}}}`);
      expect(() => getNativeEndpointConfig()).toThrow(new RegExp(`unknown chain ${chainId}`, "i"));
    }
  );
});
