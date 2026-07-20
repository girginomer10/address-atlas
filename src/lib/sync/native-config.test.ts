import { afterEach, describe, expect, it, vi } from "vitest";
import { DEFAULT_NATIVE_ENDPOINT_CONFIG, getNativeEndpointConfig } from "./native-config";

describe("native endpoint config", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("returns bundled public endpoints without remotely-configurable exchanges", () => {
    const config = getNativeEndpointConfig();

    expect(config.schemaVersion).toBe(1);
    expect(config.configVersion).toBe(5);
    expect(config.updatedAt).toBe("2026-07-14T00:00:00.000Z");
    expect(config.minSupportedAppVersion).toBe("0.2.0");
    expect(config.priceBaseUrl).toBe("https://api.coingecko.com/api/v3/simple/price");
    expect(config.chains.ethereum.rpcUrl).toBe("https://ethereum-rpc.publicnode.com");
    expect(config.chains.polygon.rpcUrl).toBe("https://polygon.drpc.org");
    expect(config.chains.scroll.rpcUrl).toBe("https://rpc.scroll.io");
    expect(config.chains["zksync-era"].rpcUrl).toBe("https://mainnet.era.zksync.io");
    expect(config.chains.stargaze).toBeUndefined();
    expect(config.exchanges).toEqual({});
  });

  it("pins the bundled configVersion to the native client contract", () => {
    // Cross-pin: this must stay >= the Swift bundled configVersion in
    // native/AddressAtlasMac/Sources/AddressAtlasCore/Sync/NativeEndpointConfig.swift
    // (bundled 5). The Mac client rejects any server config older than its own
    // bundled version, so the server value must be raised BEFORE shipping a
    // client with a higher bundled version — otherwise sync fails closed.
    expect(DEFAULT_NATIVE_ENDPOINT_CONFIG.configVersion).toBe(5);
    expect(getNativeEndpointConfig().configVersion).toBe(5);
  });

  it("allows only path changes on known bundled chain origins", () => {
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_VERSION", "7");
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_UPDATED_AT", "2026-05-09T12:00:00.000Z");
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_JSON", JSON.stringify({
      priceBaseUrl: "https://api.coingecko.com/api/v3/simple/price",
      chains: {
        ethereum: { rpcUrl: "https://ethereum-rpc.publicnode.com/rpc" }
      },
      exchanges: {
        binance: { baseUrl: "https://evil.example", accountPath: "/0/private/CancelAll" }
      }
    }));

    const config = getNativeEndpointConfig();

    expect(config.configVersion).toBe(7);
    expect(config.updatedAt).toBe("2026-05-09T12:00:00.000Z");
    expect(config.priceBaseUrl).toBe(DEFAULT_NATIVE_ENDPOINT_CONFIG.priceBaseUrl);
    expect(config.chains.ethereum.rpcUrl).toBe("https://ethereum-rpc.publicnode.com/rpc");
    expect(config.chains.solana.rpcUrl).toBe(DEFAULT_NATIVE_ENDPOINT_CONFIG.chains.solana.rpcUrl);
    expect(config.chains.unknown).toBeUndefined();
    expect(config.exchanges).toEqual({});
  });

  it.each([
    [{ priceBaseUrl: "https://api.coingecko.com/api/v3/simple/price?redirect=evil" }, /priceBaseUrl/i],
    [{ chains: { ethereum: { rpcUrl: "https://evil.example/rpc" } } }, /ethereum\.rpcUrl/i],
    [{ chains: { solana: { rpcUrl: "http://127.0.0.1:8899" } } }, /solana\.rpcUrl/i],
    [{ chains: { scroll: { rpcUrl: "https://user:password@rpc.scroll.io/private" } } }, /scroll\.rpcUrl/i],
    [{ chains: { polygon: { rpcUrl: "https://polygon.drpc.org/path#fragment" } } }, /polygon\.rpcUrl/i],
    [{ chains: { ethereum: { rpcUrl: "https://ethereum-rpc.publicnode.com/rpc?network=other" } } }, /ethereum\.rpcUrl/i]
  ])("rejects an explicitly unsafe endpoint override", (override, message) => {
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_JSON", JSON.stringify(override));
    expect(() => getNativeEndpointConfig()).toThrow(message);
  });

  it.each([
    [{ apiKey: "must-never-be-public" }, /unknown field apiKey/i],
    [{ chains: { etheruem: { rpcUrl: "https://ethereum-rpc.publicnode.com" } } }, /unknown chain etheruem/i],
    [{ chains: { stargaze: { restUrl: "https://rest.stargaze-apis.com" } } }, /unknown chain stargaze/i],
    [{ chains: { ethereum: [] } }, /ethereum must be an object/i],
    [{ chains: { ethereum: "https://ethereum-rpc.publicnode.com" } }, /ethereum must be an object/i],
    [{ chains: { ethereum: { restUrl: "https://ethereum-rpc.publicnode.com" } } }, /unsupported field restUrl/i]
  ])("rejects unknown or malformed nested config instead of silently falling back", (override, message) => {
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_JSON", JSON.stringify(override));
    expect(() => getNativeEndpointConfig()).toThrow(message);
  });

  it.each([
    ["NATIVE_ENDPOINT_CONFIG_JSON", "not-json"],
    ["NATIVE_ENDPOINT_CONFIG_JSON", "[]"],
    ["NATIVE_ENDPOINT_CONFIG_VERSION", "4"],
    ["NATIVE_ENDPOINT_CONFIG_VERSION", "4.5"],
    ["NATIVE_ENDPOINT_CONFIG_UPDATED_AT", "not-a-date"],
    ["NATIVE_ENDPOINT_CONFIG_UPDATED_AT", "2026-02-30T12:00:00Z"],
    ["NATIVE_ENDPOINT_CONFIG_UPDATED_AT", "2026-01-01T24:00:00Z"],
    ["NATIVE_ENDPOINT_CONFIG_UPDATED_AT", "2026-12-31T23:59:60Z"],
    ["NATIVE_ENDPOINT_CONFIG_UPDATED_AT", "2026-01-01T00:00:00.1234567890Z"],
    ["NATIVE_ENDPOINT_MIN_APP_VERSION", "latest"]
  ])("rejects an invalid explicit %s value", (name, value) => {
    vi.stubEnv(name, value);
    expect(() => getNativeEndpointConfig()).toThrow(/native|config|version|timestamp|json/i);
  });

  it.each([
    "0000-01-01T00:00:00Z",
    "2026-01-01T00:00:00Z",
    "2026-01-01T00:00:00.1Z",
    "2026-01-01T00:00:00.123456789Z"
  ])("accepts timestamp %s within the native decoder's explicit server contract", (updatedAt) => {
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_UPDATED_AT", updatedAt);
    expect(getNativeEndpointConfig().updatedAt).toBe(updatedAt);
  });

  it("applies the same timestamp contract to JSON config overrides", () => {
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_JSON", JSON.stringify({
      updatedAt: "2026-01-01T00:00:00.123456789Z"
    }));
    expect(getNativeEndpointConfig().updatedAt).toBe("2026-01-01T00:00:00.123456789Z");

    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_JSON", JSON.stringify({
      updatedAt: "2026-01-01T24:00:00Z"
    }));
    expect(() => getNativeEndpointConfig()).toThrow(/updatedAt/i);
  });

  it("rejects malformed typed fields inside a JSON override", () => {
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_JSON", JSON.stringify({
      configVersion: "7",
      refreshAfterSeconds: 1
    }));

    expect(() => getNativeEndpointConfig()).toThrow(/configVersion|refreshAfter/i);
  });

  it("rejects a JSON override that labels the bundled v5 payload with an older version", () => {
    vi.stubEnv("NATIVE_ENDPOINT_CONFIG_JSON", JSON.stringify({ configVersion: 4 }));
    expect(() => getNativeEndpointConfig()).toThrow(/configVersion/i);
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
