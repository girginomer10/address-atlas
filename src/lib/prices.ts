import { PricePoint } from "./types";

const COINGECKO_SIMPLE_PRICE_URL = "https://api.coingecko.com/api/v3/simple/price";
const PRICE_CACHE = new Map<string, { data: Record<string, PricePoint>; expiresAt: number }>();
const PRICE_TTL_MS = 45_000;

export async function getPrices(coinIds: string[]): Promise<Record<string, PricePoint>> {
  const uniqueIds = Array.from(new Set(coinIds.filter(Boolean))).sort();
  if (uniqueIds.length === 0) return {};

  const cacheKey = uniqueIds.join(",");
  const cached = PRICE_CACHE.get(cacheKey);
  if (cached && Date.now() < cached.expiresAt) {
    return cached.data;
  }

  const url = new URL(COINGECKO_SIMPLE_PRICE_URL);
  url.searchParams.set("ids", uniqueIds.join(","));
  url.searchParams.set("vs_currencies", "usd");
  url.searchParams.set("include_24hr_change", "true");

  const response = await fetch(url, {
    headers: {
      accept: "application/json"
    },
    next: {
      revalidate: 45
    }
  });

  if (!response.ok) {
    return {};
  }

  const data = (await response.json()) as Record<string, PricePoint>;
  PRICE_CACHE.set(cacheKey, {
    data,
    expiresAt: Date.now() + PRICE_TTL_MS
  });
  return data;
}
