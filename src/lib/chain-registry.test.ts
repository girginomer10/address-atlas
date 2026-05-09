import { describe, expect, it } from "vitest";
import {
  detectChainsForAddress,
  ERC20_TOKENS_BY_CHAIN,
  EVM_CHAINS,
  getAllCoinGeckoIds,
  SPL_TOKENS_BY_CHAIN
} from "./chain-registry";

describe("chain registry", () => {
  it("includes the expanded EVM chain set in address detection", () => {
    const chainIds = EVM_CHAINS.map((chain) => chain.id);
    const detected = detectChainsForAddress("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045")
      .map((chain) => chain.id);

    expect(chainIds).toEqual(expect.arrayContaining([
      "gnosis",
      "linea",
      "mantle",
      "scroll",
      "zksync-era"
    ]));
    expect(detected).toEqual(expect.arrayContaining([
      "gnosis",
      "linea",
      "mantle",
      "scroll",
      "zksync-era"
    ]));
  });

  it("tracks common assets on the added EVM and Solana registries", () => {
    expect(ERC20_TOKENS_BY_CHAIN.gnosis).toEqual(expect.arrayContaining([
      expect.objectContaining({ symbol: "GNO", decimals: 18 }),
      expect.objectContaining({ symbol: "WXDAI", decimals: 18 })
    ]));
    expect(ERC20_TOKENS_BY_CHAIN.scroll).toEqual(expect.arrayContaining([
      expect.objectContaining({
        symbol: "USDC",
        address: "0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4",
        decimals: 6
      }),
      expect.objectContaining({ symbol: "SCR", decimals: 18 })
    ]));
    expect(ERC20_TOKENS_BY_CHAIN["zksync-era"]).toEqual(expect.arrayContaining([
      expect.objectContaining({
        symbol: "ZK",
        address: "0x5A7d6b2F92C77FAD6CCaBd7EE0624E64907Eaf3E",
        decimals: 18
      })
    ]));
    expect(SPL_TOKENS_BY_CHAIN.solana).toEqual(expect.arrayContaining([
      expect.objectContaining({ symbol: "PYTH", decimals: 6 }),
      expect.objectContaining({ symbol: "RAY", decimals: 6 }),
      expect.objectContaining({ symbol: "mSOL", decimals: 9 }),
      expect.objectContaining({ symbol: "ORCA", decimals: 6 })
    ]));
  });

  it("exposes price ids for expanded built-in assets", () => {
    expect(getAllCoinGeckoIds()).toEqual(expect.arrayContaining([
      "mantle",
      "scroll",
      "xdai",
      "zksync",
      "pyth-network",
      "raydium",
      "msol",
      "orca"
    ]));
  });
});
