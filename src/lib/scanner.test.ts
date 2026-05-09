import { afterEach, describe, expect, it, vi } from "vitest";
import {
  decodeXrplCurrency,
  parseCosmosDelegations,
  parseCosmosRewards,
  parseSplTokenAccounts,
  scanAddresses
} from "./scanner";

const SOLANA_ADDRESS = "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU";
const USDC_MINT = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
const USDT_MINT = "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB";
const UNKNOWN_MINT = "So11111111111111111111111111111111111111112";
const EVM_ADDRESS = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";
const ETHEREUM_USDC = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48";
const ETHEREUM_CRV = "0xd533a949740bb3306d119cc777fa900ba034cd52";

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
            if (body.params?.[1]?.programId === "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb") {
              return {
                ok: true,
                json: async () => ({ jsonrpc: "2.0", id: body.id, result: { value: [] } })
              };
            }
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

  it("keeps classic SPL balances when the Token-2022 lookup fails", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
        const url = typeof input === "string" ? input : input.toString();
        if (url.includes("api.coingecko.com")) return { ok: true, json: async () => ({}) };

        if (url.includes("api.mainnet-beta.solana.com")) {
          const body = JSON.parse(String(init?.body ?? "{}"));
          if (body.method === "getBalance") {
            return jsonResponse({ jsonrpc: "2.0", id: body.id, result: { value: 0 } });
          }
          if (body.method === "getTokenAccountsByOwner") {
            if (body.params?.[1]?.programId === "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb") {
              return jsonResponse({ jsonrpc: "2.0", id: body.id, error: { message: "token-2022-down" } });
            }
            return jsonResponse({
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
                            tokenAmount: { amount: "3000000", decimals: 6 }
                          }
                        }
                      }
                    }
                  }
                ]
              }
            });
          }
        }

        throw new Error(`Unexpected fetch ${url}`);
      })
    );

    const response = await scanAddresses(SOLANA_ADDRESS);

    expect(response.assets.map((asset) => asset.symbol)).toEqual(["USDC"]);
    expect(response.assets[0]).toMatchObject({ amount: 3, source: "spl" });
    expect(response.warnings.some((message) => message.includes("Token-2022"))).toBe(true);
  });
});

describe("scanAddresses EVM token batching", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("batches ERC-20 balance calls per chain and surfaces partial token failures", async () => {
    const batchSizes: number[] = [];

    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
        const url = typeof input === "string" ? input : input.toString();
        if (url.includes("api.coingecko.com")) {
          return jsonResponse({ "usd-coin": { usd: 1, usd_24h_change: 0 } });
        }

        const body = JSON.parse(String(init?.body ?? "{}"));
        if (Array.isArray(body)) {
          batchSizes.push(body.length);
          return jsonResponse(body.map((request) => {
            const tokenAddress = String(request.params?.[0]?.to ?? "").toLowerCase();
            if (tokenAddress === ETHEREUM_USDC) {
              return {
                jsonrpc: "2.0",
                id: request.id,
                result: `0x${(42_000_000n).toString(16)}`
              };
            }
            if (tokenAddress === ETHEREUM_CRV) {
              return {
                jsonrpc: "2.0",
                id: request.id,
                error: { message: "token-rpc-down" }
              };
            }
            return { jsonrpc: "2.0", id: request.id, result: "0x0" };
          }));
        }

        if (body.method === "eth_getBalance") {
          return jsonResponse({ jsonrpc: "2.0", id: body.id, result: "0x0" });
        }

        throw new Error(`Unexpected fetch ${url}`);
      })
    );

    const response = await scanAddresses(EVM_ADDRESS);

    expect(batchSizes.length).toBeGreaterThan(0);
    expect(batchSizes.some((size) => size > 1)).toBe(true);
    expect(response.assets).toEqual([
      expect.objectContaining({
        chainId: "ethereum",
        symbol: "USDC",
        source: "erc20",
        amount: 42,
        valueUsd: 42
      })
    ]);
    expect(response.warnings.some((warning) =>
      warning.includes("Ethereum ERC-20 token balance checks failed for CRV")
    )).toBe(true);
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

describe("TRON and XRP scan integration", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("emits native TRX and tracked TRC20 balances", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = typeof input === "string" ? input : input.toString();
        if (url.includes("api.coingecko.com")) {
          return jsonResponse({
            tron: { usd: 0.1, usd_24h_change: 2 },
            tether: { usd: 1, usd_24h_change: 0 }
          });
        }
        if (url.includes("api.trongrid.io/v1/accounts/")) {
          return jsonResponse({
            data: [
              {
                balance: 1_234_567,
                trc20: [
                  {
                    TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t: "2500000"
                  }
                ]
              }
            ]
          });
        }
        throw new Error(`Unexpected fetch ${url}`);
      })
    );

    const response = await scanAddresses("TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7");
    const assetsBySymbol = Object.fromEntries(response.assets.map((asset) => [asset.symbol, asset]));

    expect(response.addresses[0]?.detectedChains).toEqual(["tron"]);
    expect(assetsBySymbol.TRX).toMatchObject({ source: "native", amount: 1.234567 });
    expect(assetsBySymbol.USDT).toMatchObject({ source: "trc20", amount: 2.5 });
  });

  it("emits native XRP balances and positive issued-currency trust lines", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = typeof input === "string" ? input : input.toString();
        if (url.includes("api.coingecko.com")) return jsonResponse({ ripple: { usd: 2 } });
        if (url.includes("s1.ripple.com")) {
          const body = JSON.parse(String(init?.body ?? "{}"));
          if (body.method === "account_lines") {
            return jsonResponse({
              result: {
                status: "success",
                lines: [
                  {
                    account: "rIssuer111111111111111111111111111111",
                    currency: "USD",
                    balance: "42.5"
                  },
                  {
                    account: "rIssuer222222222222222222222222222222",
                    currency: "EUR",
                    balance: "-1"
                  }
                ]
              }
            });
          }
          expect(body.method).toBe("account_info");
          return jsonResponse({
            result: {
              status: "success",
              account_data: {
                Balance: "12345678"
              }
            }
          });
        }
        throw new Error(`Unexpected fetch ${url}`);
      })
    );

    const response = await scanAddresses("rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn");

    expect(response.addresses[0]?.detectedChains).toEqual(["xrp"]);
    const assetsBySymbol = Object.fromEntries(response.assets.map((asset) => [asset.symbol, asset]));
    expect(assetsBySymbol.XRP).toMatchObject({
      chainId: "xrp",
      symbol: "XRP",
      source: "native",
      amount: 12.345678
    });
    expect(assetsBySymbol.USD).toMatchObject({
      chainId: "xrp",
      symbol: "USD",
      source: "issued",
      amount: 42.5,
      priceUsd: 0
    });
  });
});

describe("decodeXrplCurrency", () => {
  it("keeps standard currency codes unchanged", () => {
    expect(decodeXrplCurrency("USD")).toBe("USD");
  });

  it("decodes printable 160-bit currency codes", () => {
    expect(decodeXrplCurrency("534F4C4F00000000000000000000000000000000")).toBe("SOLO");
  });
});

function jsonResponse(body: unknown) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "content-type": "application/json" }
  });
}
