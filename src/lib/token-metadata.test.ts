import { afterEach, describe, expect, it, vi } from "vitest";
import { lookupTokenMetadata } from "./token-metadata";

describe("lookupTokenMetadata", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
  });

  it("loads non-registry ERC-20 symbol, name, and decimals from the selected chain RPC", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
        const url = typeof input === "string" ? input : input.toString();
        if (url.includes("api.coingecko.com")) {
          return jsonResponse({
            coins: [
              { id: "curve-dao-token", name: "Curve DAO", symbol: "CRV", market_cap_rank: 90 },
              { id: "convex-crv", name: "Convex CRV", symbol: "CVXCRV", market_cap_rank: 900 }
            ]
          });
        }
        const body = JSON.parse(String(init?.body ?? "{}"));
        const data = body.params?.[0]?.data;
        if (data === "0x95d89b41") return jsonRpc(body.id, encodeString("CRV"));
        if (data === "0x06fdde03") return jsonRpc(body.id, encodeString("Curve DAO"));
        if (data === "0x313ce567") return jsonRpc(body.id, encodeUint(18));
        throw new Error(`Unexpected selector ${data}`);
      })
    );

    const metadata = await lookupTokenMetadata({
      chainKind: "evm",
      chainId: "ethereum",
      address: "0xD533a949740bb3306d119CC777fa900bA034cd52"
    });

    expect(metadata).toMatchObject({
      chainKind: "evm",
      chainId: "ethereum",
      address: "0xd533a949740bb3306d119cc777fa900ba034cd52",
      symbol: "CRV",
      name: "Curve DAO",
      decimals: 18
    });
    expect(metadata.coinGeckoSuggestions[0]).toMatchObject({ id: "curve-dao-token", symbol: "CRV" });
  });

  it("loads Solana mint decimals from parsed account info", async () => {
    vi.stubEnv("JUPITER_API_KEY", "");
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_input: string | URL | Request, init?: RequestInit) => {
        const body = JSON.parse(String(init?.body ?? "{}"));
        return jsonRpc(body.id, {
          value: {
            data: {
              parsed: {
                info: {
                  decimals: 5
                }
              }
            }
          }
        });
      })
    );

    const metadata = await lookupTokenMetadata({
      chainKind: "solana",
      chainId: "solana",
      address: "So11111111111111111111111111111111111111112"
    });

    expect(metadata).toMatchObject({
      chainKind: "solana",
      chainId: "solana",
      decimals: 5
    });
  });

  it("uses Jupiter token information for Solana when an API key is configured", async () => {
    vi.stubEnv("JUPITER_API_KEY", "test-key");
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
        const url = typeof input === "string" ? input : input.toString();
        if (url.includes("api.jup.ag")) {
          expect((init?.headers as Record<string, string>)["x-api-key"]).toBe("test-key");
          return jsonResponse([
            {
              id: "So11111111111111111111111111111111111111112",
              symbol: "WSOL",
              name: "Wrapped SOL",
              decimals: 9,
              usdPrice: 100
            }
          ]);
        }
        if (url.includes("api.coingecko.com")) {
          return jsonResponse({
            coins: [{ id: "wrapped-solana", name: "Wrapped SOL", symbol: "SOL", market_cap_rank: 125 }]
          });
        }
        const body = JSON.parse(String(init?.body ?? "{}"));
        return jsonRpc(body.id, {
          value: {
            data: {
              parsed: {
                info: {
                  decimals: 5
                }
              }
            }
          }
        });
      })
    );

    const metadata = await lookupTokenMetadata({
      chainKind: "solana",
      chainId: "solana",
      address: "So11111111111111111111111111111111111111112"
    });

    expect(metadata).toMatchObject({
      chainKind: "solana",
      symbol: "WSOL",
      name: "Wrapped SOL",
      decimals: 9,
      priceUsd: 100,
      source: "mixed"
    });
    expect(metadata.coinGeckoSuggestions[0]).toMatchObject({ id: "wrapped-solana" });
  });
});

function jsonRpc(id: number, result: unknown) {
  return jsonResponse({ jsonrpc: "2.0", id, result });
}

function jsonResponse(body: unknown) {
  return {
    ok: true,
    json: async () => body
  };
}

function encodeUint(value: number) {
  return `0x${value.toString(16).padStart(64, "0")}`;
}

function encodeString(value: string) {
  const data = Buffer.from(value, "utf8").toString("hex");
  const paddedLength = Math.ceil(data.length / 64) * 64;
  return `0x${"20".padStart(64, "0")}${(data.length / 2).toString(16).padStart(64, "0")}${data.padEnd(paddedLength, "0")}`;
}
