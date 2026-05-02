import { NextRequest } from "next/server";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { DELETE, GET, PATCH, POST } from "./route";
import { prisma } from "@/lib/db";
import { clearTestDatabase } from "@/lib/test-db";

const VALID_TOKEN_BODY = {
  chainKind: "evm",
  chainId: "ethereum",
  address: "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9",
  symbol: "AAVE",
  name: "Aave",
  decimals: 18,
  coinGeckoId: "aave"
};

describe("tokens API route", () => {
  beforeEach(async () => {
    await clearTestDatabase();
  });

  afterEach(async () => {
    await clearTestDatabase();
  });

  it("creates and lists tokens through HTTP handlers", async () => {
    const created = await POST(jsonRequest("POST", VALID_TOKEN_BODY));
    expect(created.status).toBe(200);
    const createdBody = await created.json();
    expect(createdBody.token.address).toBe(VALID_TOKEN_BODY.address.toLowerCase());

    const list = await GET();
    expect(list.status).toBe(200);
    const body = await list.json();
    expect(body.tokens).toHaveLength(1);
    expect(body.chainOptions.length).toBeGreaterThan(0);
    expect(body.chainOptions.every((option: { id: string }) => Boolean(option.id))).toBe(true);
  });

  it("rejects invalid input with a 400 and a field hint", async () => {
    const response = await POST(
      jsonRequest("POST", { ...VALID_TOKEN_BODY, address: "0xnope" })
    );
    expect(response.status).toBe(400);
    const body = await response.json();
    expect(body.field).toBe("address");
  });

  it("toggles enabled state without losing other fields", async () => {
    const created = await prisma.customToken.create({
      data: {
        chainKind: "evm",
        chainId: "ethereum",
        address: VALID_TOKEN_BODY.address.toLowerCase(),
        symbol: "AAVE",
        name: "Aave",
        decimals: 18,
        coinGeckoId: "aave",
        enabled: true
      }
    });

    const response = await PATCH(jsonRequest("PATCH", { id: created.id, enabled: false }));
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.token.enabled).toBe(false);
    expect(body.token.symbol).toBe("AAVE");
  });

  it("deletes a token by id", async () => {
    const created = await prisma.customToken.create({
      data: {
        chainKind: "evm",
        chainId: "ethereum",
        address: VALID_TOKEN_BODY.address.toLowerCase(),
        symbol: "AAVE",
        name: "Aave",
        decimals: 18,
        coinGeckoId: "aave",
        enabled: true
      }
    });

    const response = await DELETE(
      new NextRequest(`http://localhost/api/tokens?id=${encodeURIComponent(created.id)}`, { method: "DELETE" })
    );
    expect(response.status).toBe(200);
    expect(await prisma.customToken.count()).toBe(0);
  });
});

function jsonRequest(method: string, body: unknown) {
  return new NextRequest("http://localhost/api/tokens", {
    method,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body)
  });
}
