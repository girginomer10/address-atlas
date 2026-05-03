import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  CustomTokenValidationError,
  createCustomToken,
  deleteCustomToken,
  listCustomTokens,
  listEnabledCustomTokens,
  normalizeCustomTokenInput,
  updateCustomToken
} from "./local-store";
import { mergeSplTokensByChain, mergeTokensByChain } from "./scanner";
import { clearTestDatabase } from "./test-db";
import { ERC20_TOKENS_BY_CHAIN } from "./chain-registry";
import type { TokenConfig } from "./types";

const VALID_TOKEN = {
  chainKind: "evm",
  chainId: "ethereum",
  address: "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9",
  symbol: "AAVE",
  name: "Aave",
  decimals: 18,
  coinGeckoId: "aave",
  priceUsd: null
};

describe("custom token persistence", () => {
  beforeEach(async () => {
    await clearTestDatabase();
  });

  afterEach(async () => {
    await clearTestDatabase();
  });

  it("creates, lists, toggles, and deletes a custom token", async () => {
    const created = await createCustomToken(VALID_TOKEN);
    expect(created.id).toBeTruthy();
    expect(created.address).toBe(VALID_TOKEN.address.toLowerCase());
    expect(created.enabled).toBe(true);

    const listed = await listCustomTokens();
    expect(listed).toHaveLength(1);
    expect(listed[0].symbol).toBe("AAVE");

    const enabled = await listEnabledCustomTokens();
    expect(enabled).toHaveLength(1);

    const disabled = await updateCustomToken(created.id, { enabled: false });
    expect(disabled.enabled).toBe(false);
    expect(await listEnabledCustomTokens()).toHaveLength(0);
    expect(await listCustomTokens()).toHaveLength(1);

    const renamed = await updateCustomToken(created.id, {
      symbol: "AAVE2",
      name: "Aave V2",
      decimals: 18,
      coinGeckoId: "aave",
      priceUsd: 99
    });
    expect(renamed.symbol).toBe("AAVE2");
    expect(renamed.name).toBe("Aave V2");
    expect(renamed.priceUsd).toBe(99);

    await deleteCustomToken(created.id);
    expect(await listCustomTokens()).toHaveLength(0);
  });

  it("rejects duplicate (chain, address) combinations", async () => {
    await createCustomToken(VALID_TOKEN);
    await expect(
      createCustomToken({ ...VALID_TOKEN, address: VALID_TOKEN.address.toLowerCase() })
    ).rejects.toBeInstanceOf(CustomTokenValidationError);
  });
});

describe("custom token validation", () => {
  it("normalizes and lowercases EVM addresses", () => {
    const normalized = normalizeCustomTokenInput({ ...VALID_TOKEN, address: VALID_TOKEN.address });
    expect(normalized.address).toBe(VALID_TOKEN.address.toLowerCase());
    expect(normalized.chainKind).toBe("evm");
    expect(normalized.coinGeckoId).toBe("aave");
  });

  it("rejects bad EVM addresses", () => {
    expect(() =>
      normalizeCustomTokenInput({ ...VALID_TOKEN, address: "0xnope" })
    ).toThrow(CustomTokenValidationError);
  });

  it("rejects unknown EVM chain ids", () => {
    expect(() =>
      normalizeCustomTokenInput({ ...VALID_TOKEN, chainId: "fantom" })
    ).toThrow(CustomTokenValidationError);
  });

  it("supports Solana mint allowlist entries", () => {
    const normalized = normalizeCustomTokenInput({
      chainKind: "solana",
      chainId: "solana",
      address: "DezXAZ8z7PnrnRJjz3JpPZsM1pPB263KGg1W53WZyQb",
      symbol: "BONK",
      name: "Bonk",
      decimals: 5,
      coinGeckoId: "",
      priceUsd: "0.00001"
    });

    expect(normalized.chainKind).toBe("solana");
    expect(normalized.coinGeckoId).toBeNull();
    expect(normalized.priceUsd).toBe(0.00001);
  });

  it("rejects non-integer or out-of-range decimals", () => {
    expect(() =>
      normalizeCustomTokenInput({ ...VALID_TOKEN, decimals: 1.5 })
    ).toThrow(CustomTokenValidationError);
    expect(() =>
      normalizeCustomTokenInput({ ...VALID_TOKEN, decimals: -1 })
    ).toThrow(CustomTokenValidationError);
    expect(() =>
      normalizeCustomTokenInput({ ...VALID_TOKEN, decimals: 99 })
    ).toThrow(CustomTokenValidationError);
  });

  it("rejects missing required fields", () => {
    expect(() =>
      normalizeCustomTokenInput({ ...VALID_TOKEN, symbol: "" })
    ).toThrow(CustomTokenValidationError);
    expect(() =>
      normalizeCustomTokenInput({ ...VALID_TOKEN, name: "" })
    ).toThrow(CustomTokenValidationError);
    expect(normalizeCustomTokenInput({ ...VALID_TOKEN, coinGeckoId: "" }).coinGeckoId).toBeNull();
  });

  it("rejects invalid CoinGecko ids", () => {
    expect(() =>
      normalizeCustomTokenInput({ ...VALID_TOKEN, coinGeckoId: "Bad ID!" })
    ).toThrow(CustomTokenValidationError);
  });

  it("rejects invalid manual prices", () => {
    expect(() =>
      normalizeCustomTokenInput({ ...VALID_TOKEN, priceUsd: -1 })
    ).toThrow(CustomTokenValidationError);
    expect(() =>
      normalizeCustomTokenInput({ ...VALID_TOKEN, priceUsd: "nope" })
    ).toThrow(CustomTokenValidationError);
  });
});

describe("scanner token merge", () => {
  it("merges custom tokens after the built-in registry", () => {
    const custom: TokenConfig = {
      symbol: "CRV",
      name: "Curve DAO",
      address: "0xd533a949740bb3306d119cc777fa900ba034cd52",
      decimals: 18,
      coinGeckoId: "curve-dao-token"
    };

    const merged = mergeTokensByChain([{ chainId: "ethereum", token: custom }]);

    const ethereum = merged.ethereum ?? [];
    const builtin = ERC20_TOKENS_BY_CHAIN.ethereum ?? [];
    expect(ethereum.length).toBe(builtin.length + 1);
    expect(ethereum[ethereum.length - 1].symbol).toBe("CRV");
  });

  it("does not duplicate when a custom token shares an address with a built-in token", () => {
    const builtin = ERC20_TOKENS_BY_CHAIN.ethereum ?? [];
    const usdc = builtin.find((token) => token.symbol === "USDC");
    if (!usdc) throw new Error("expected built-in USDC for the test fixture");

    const merged = mergeTokensByChain([
      {
        chainId: "ethereum",
        token: {
          ...usdc,
          symbol: "USDC-CUSTOM",
          name: "Custom USDC",
          decimals: 4,
          coinGeckoId: "fake-id",
          priceUsd: null
        }
      }
    ]);

    const ethereum = merged.ethereum ?? [];
    expect(ethereum.length).toBe(builtin.length);
    const matched = ethereum.find((token) => token.address.toLowerCase() === usdc.address.toLowerCase());
    expect(matched?.symbol).toBe("USDC");
    expect(matched?.decimals).toBe(usdc.decimals);
  });

  it("introduces a chain bucket when the custom token targets an unmapped chain", () => {
    const merged = mergeTokensByChain([
      {
        chainId: "base",
        token: {
          symbol: "WETH",
          name: "Wrapped Ether",
          address: "0x4200000000000000000000000000000000000006",
          decimals: 18,
          coinGeckoId: "weth",
          priceUsd: null
        }
      }
    ]);
    expect(merged.base?.some((token) => token.symbol === "WETH")).toBe(true);
  });

  it("merges custom Solana mints after the built-in SPL registry", () => {
    const merged = mergeSplTokensByChain([
      {
        chainId: "solana",
        token: {
          symbol: "MYCOIN",
          name: "My Coin",
          mint: "So11111111111111111111111111111111111111112",
          decimals: 9,
          coinGeckoId: null,
          priceUsd: 0.25
        }
      }
    ]);

    expect(merged.solana?.some((token) => token.symbol === "MYCOIN")).toBe(true);
  });
});
