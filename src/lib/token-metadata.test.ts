import { afterEach, describe, expect, it, vi } from "vitest";
import { lookupTokenMetadata } from "./token-metadata";

describe("lookupTokenMetadata", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("loads ERC-20 symbol, name, and decimals from the selected chain RPC", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_input: string | URL | Request, init?: RequestInit) => {
        const body = JSON.parse(String(init?.body ?? "{}"));
        const data = body.params?.[0]?.data;
        if (data === "0x95d89b41") return jsonRpc(body.id, encodeString("AAVE"));
        if (data === "0x06fdde03") return jsonRpc(body.id, encodeString("Aave"));
        if (data === "0x313ce567") return jsonRpc(body.id, encodeUint(18));
        throw new Error(`Unexpected selector ${data}`);
      })
    );

    const metadata = await lookupTokenMetadata({
      chainKind: "evm",
      chainId: "ethereum",
      address: "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9"
    });

    expect(metadata).toMatchObject({
      chainKind: "evm",
      chainId: "ethereum",
      address: "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9",
      symbol: "AAVE",
      name: "Aave",
      decimals: 18
    });
  });

  it("loads Solana mint decimals from parsed account info", async () => {
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
      address: "DezXAZ8z7PnrnRJjz3JpPZsM1pPB263KGg1W53WZyQb"
    });

    expect(metadata).toMatchObject({
      chainKind: "solana",
      chainId: "solana",
      decimals: 5
    });
  });
});

function jsonRpc(id: number, result: unknown) {
  return {
    ok: true,
    json: async () => ({ jsonrpc: "2.0", id, result })
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
