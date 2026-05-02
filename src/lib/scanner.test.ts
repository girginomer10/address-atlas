import { afterEach, describe, expect, it, vi } from "vitest";
import {
  parseCosmosDelegations,
  parseCosmosRewards,
  parseSplTokenAccounts,
  scanAddresses
} from "./scanner";

const SOLANA_ADDRESS = "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU";
const USDC_MINT = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
const USDT_MINT = "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB";
const UNKNOWN_MINT = "So11111111111111111111111111111111111111112";

describe("parseSplTokenAccounts", () => {
  it("returns mint, raw amount, and decimals from jsonParsed accounts", () => {
    const parsed = parseSplTokenAccounts([
      {
        account: {
          data: {
            parsed: {
              info: {
                mint: USDC_MINT,
                tokenAmount: { amount: "1500000", decimals: 6 }
              }
            }
          }
        }
      }
    ]);

    expect(parsed).toEqual([{ mint: USDC_MINT, rawAmount: "1500000", decimals: 6 }]);
  });

  it("ignores malformed entries", () => {
    const parsed = parseSplTokenAccounts([
      null,
      { account: null },
      { account: { data: { parsed: { info: { mint: 42 } } } } },
      {
        account: {
          data: {
            parsed: {
              info: {
                mint: USDC_MINT,
                tokenAmount: { amount: 5, decimals: 6 }
              }
            }
          }
        }
      }
    ]);

    expect(parsed).toEqual([]);
  });

  it("returns an empty array when given non-array input", () => {
    expect(parseSplTokenAccounts(undefined)).toEqual([]);
    expect(parseSplTokenAccounts({})).toEqual([]);
  });
});

describe("scanAddresses Solana SPL", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("emits native SOL plus tracked SPL token balances and skips unknown mints", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
        const url = typeof input === "string" ? input : input.toString();

        if (url.includes("api.coingecko.com")) {
          return {
            ok: true,
            json: async () => ({})
          };
        }

        if (url.includes("api.mainnet-beta.solana.com")) {
          const body = JSON.parse(String(init?.body ?? "{}"));

          if (body.method === "getBalance") {
            return {
              ok: true,
              json: async () => ({ jsonrpc: "2.0", id: body.id, result: { value: 250_000_000 } })
            };
          }

          if (body.method === "getTokenAccountsByOwner") {
            return {
              ok: true,
              json: async () => ({
                jsonrpc: "2.0",
                id: body.id,
                result: {
                  value: [
                    {
                      account: {
                        data: {
                          parsed: {
                            info: {
                              mint: USDC_MINT,
                              tokenAmount: { amount: "5500000", decimals: 6 }
                            }
                          }
                        }
                      }
                    },
                    {
                      account: {
                        data: {
                          parsed: {
                            info: {
                              mint: USDC_MINT,
                              tokenAmount: { amount: "500000", decimals: 6 }
                            }
                          }
                        }
                      }
                    },
                    {
                      account: {
                        data: {
                          parsed: {
                            info: {
                              mint: USDT_MINT,
                              tokenAmount: { amount: "12000000", decimals: 6 }
                            }
                          }
                        }
                      }
                    },
                    {
                      account: {
                        data: {
                          parsed: {
                            info: {
                              mint: UNKNOWN_MINT,
                              tokenAmount: { amount: "1000000000", decimals: 9 }
                            }
                          }
                        }
                      }
                    }
                  ]
                }
              })
            };
          }
        }

        throw new Error(`Unexpected fetch ${url}`);
      })
    );

    const response = await scanAddresses(SOLANA_ADDRESS);
    const assetsBySymbol = Object.fromEntries(response.assets.map((asset) => [asset.symbol, asset]));

    expect(response.assets.map((asset) => asset.symbol).sort()).toEqual(["SOL", "USDC", "USDT"]);
    expect(assetsBySymbol.SOL).toMatchObject({ source: "native", family: "solana", amount: 0.25 });
    expect(assetsBySymbol.USDC).toMatchObject({ source: "spl", family: "solana", amount: 6, chainId: "solana" });
    expect(assetsBySymbol.USDT).toMatchObject({ source: "spl", family: "solana", amount: 12, chainId: "solana" });
  });

  it("warns and still returns native SOL when SPL fetch fails", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
        const url = typeof input === "string" ? input : input.toString();
        if (url.includes("api.coingecko.com")) return { ok: true, json: async () => ({}) };

        if (url.includes("api.mainnet-beta.solana.com")) {
          const body = JSON.parse(String(init?.body ?? "{}"));
          if (body.method === "getBalance") {
            return {
              ok: true,
              json: async () => ({ jsonrpc: "2.0", id: body.id, result: { value: 1_000_000_000 } })
            };
          }
          if (body.method === "getTokenAccountsByOwner") {
            return {
              ok: true,
              json: async () => ({ jsonrpc: "2.0", id: body.id, error: { message: "rpc-down" } })
            };
          }
        }

        throw new Error(`Unexpected fetch ${url}`);
      })
    );

    const response = await scanAddresses(SOLANA_ADDRESS);

    expect(response.assets.map((asset) => asset.symbol)).toEqual(["SOL"]);
    expect(response.warnings.some((message) => message.includes("SPL token balances failed"))).toBe(true);
  });
});

describe("cosmos parsers", () => {
  it("sums only the chain's native denom across delegations", () => {
    const data = {
      delegation_responses: [
        { balance: { denom: "uatom", amount: "1500000" } },
        { balance: { denom: "uatom", amount: "2500000" } },
        { balance: { denom: "ibc/foo", amount: "999999999" } }
      ]
    };

    expect(parseCosmosDelegations(data, "uatom", 6)).toBeCloseTo(4, 9);
  });

  it("handles empty delegation responses", () => {
    expect(parseCosmosDelegations({}, "uatom", 6)).toBe(0);
    expect(parseCosmosDelegations({ delegation_responses: [] }, "uatom", 6)).toBe(0);
  });

  it("parses high-precision reward decimal strings", () => {
    const data = {
      total: [
        { denom: "uatom", amount: "12345678.123456789012345678" },
        { denom: "uosmo", amount: "999999999" }
      ]
    };

    expect(parseCosmosRewards(data, "uatom", 6)).toBeCloseTo(12.345678123456789, 9);
  });

  it("returns zero when reward total is missing", () => {
    expect(parseCosmosRewards({}, "uatom", 6)).toBe(0);
    expect(parseCosmosRewards({ total: [] }, "uatom", 6)).toBe(0);
  });
});

describe("cosmos scan integration", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("emits separate liquid, staked, and rewards assets", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = typeof input === "string" ? input : input.toString();
      if (url.includes("api.coingecko.com")) {
        return jsonResponse({ cosmos: { usd: 10, usd_24h_change: 1 } });
      }
      if (url.includes("/cosmos/bank/v1beta1/balances/")) {
        return jsonResponse({ balances: [{ denom: "uatom", amount: "5000000" }] });
      }
      if (url.includes("/cosmos/staking/v1beta1/delegations/")) {
        return jsonResponse({
          delegation_responses: [
            { balance: { denom: "uatom", amount: "10000000" } },
            { balance: { denom: "uatom", amount: "2000000" } }
          ]
        });
      }
      if (url.includes("/cosmos/distribution/v1beta1/delegators/")) {
        return jsonResponse({ total: [{ denom: "uatom", amount: "3500000.000000000000000000" }] });
      }
      throw new Error(`Unexpected fetch ${url}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    const response = await scanAddresses("cosmos1p8s5k7eyed68x2qplfw0e5a8svjqx39g7yr82m");
    const cosmosAssets = response.assets.filter((asset) => asset.chainId === "cosmoshub");

    expect(cosmosAssets.map((asset) => asset.source).sort()).toEqual(["native", "rewards", "staked"]);
    expect(cosmosAssets.find((asset) => asset.source === "native")?.amount).toBeCloseTo(5, 9);
    expect(cosmosAssets.find((asset) => asset.source === "staked")?.amount).toBeCloseTo(12, 9);
    expect(cosmosAssets.find((asset) => asset.source === "rewards")?.amount).toBeCloseTo(3.5, 9);
  });

  it("warns instead of failing when staking and rewards endpoints are missing", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = typeof input === "string" ? input : input.toString();
      if (url.includes("api.coingecko.com")) return jsonResponse({ cosmos: { usd: 10 } });
      if (url.includes("/cosmos/bank/v1beta1/balances/")) {
        return jsonResponse({ balances: [{ denom: "uatom", amount: "7000000" }] });
      }
      if (url.includes("/cosmos/staking/v1beta1/delegations/")) {
        return new Response("not found", { status: 404, statusText: "Not Found" });
      }
      if (url.includes("/cosmos/distribution/v1beta1/delegators/")) {
        return new Response("not found", { status: 404, statusText: "Not Found" });
      }
      throw new Error(`Unexpected fetch ${url}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    const response = await scanAddresses("cosmos1p8s5k7eyed68x2qplfw0e5a8svjqx39g7yr82m");
    const cosmosAssets = response.assets.filter((asset) => asset.chainId === "cosmoshub");

    expect(cosmosAssets).toHaveLength(1);
    expect(cosmosAssets[0]?.source).toBe("native");
    expect(cosmosAssets[0]?.amount).toBeCloseTo(7, 9);
    expect(response.warnings.some((warning) => warning.includes("delegations fetch failed"))).toBe(true);
    expect(response.warnings.some((warning) => warning.includes("rewards fetch failed"))).toBe(true);
  });
});

function jsonResponse(body: unknown) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "content-type": "application/json" }
  });
}
