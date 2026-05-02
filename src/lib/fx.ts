const COINGECKO_SIMPLE_PRICE_URL = "https://api.coingecko.com/api/v3/simple/price";
const FX_BASE_COIN = "tether";
const FX_TTL_MS = 5 * 60_000;
const FX_TIMEOUT_MS = 4_500;

export const SUPPORTED_DISPLAY_CURRENCIES = ["USD", "EUR", "GBP", "TRY"] as const;
export type DisplayCurrency = (typeof SUPPORTED_DISPLAY_CURRENCIES)[number];

export type FxRates = Record<string, number>;

let fxCache: { data: FxRates; expiresAt: number } | null = null;

export function isSupportedDisplayCurrency(value: string): value is DisplayCurrency {
  return (SUPPORTED_DISPLAY_CURRENCIES as readonly string[]).includes(value.toUpperCase());
}

export function normalizeDisplayCurrency(value: string | undefined | null): DisplayCurrency {
  const upper = (value ?? "").toUpperCase();
  return isSupportedDisplayCurrency(upper) ? upper : "USD";
}

export function resetFxCacheForTesting() {
  fxCache = null;
}

export async function getUsdFxRates(): Promise<FxRates> {
  if (fxCache && Date.now() < fxCache.expiresAt) {
    return fxCache.data;
  }

  const url = new URL(COINGECKO_SIMPLE_PRICE_URL);
  url.searchParams.set("ids", FX_BASE_COIN);
  url.searchParams.set("vs_currencies", SUPPORTED_DISPLAY_CURRENCIES.map((code) => code.toLowerCase()).join(","));

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), FX_TIMEOUT_MS);

  try {
    const response = await fetch(url, {
      signal: controller.signal,
      headers: {
        accept: "application/json"
      }
    });

    if (!response.ok) {
      return fxCache?.data ?? { USD: 1 };
    }

    const body = (await response.json()) as Record<string, Record<string, number>>;
    const tether = body[FX_BASE_COIN] ?? {};
    const usdQuote = Number(tether.usd);
    if (!Number.isFinite(usdQuote) || usdQuote <= 0) {
      return fxCache?.data ?? { USD: 1 };
    }

    const rates: FxRates = { USD: 1 };
    for (const code of SUPPORTED_DISPLAY_CURRENCIES) {
      if (code === "USD") continue;
      const quote = Number(tether[code.toLowerCase()]);
      if (Number.isFinite(quote) && quote > 0) {
        rates[code] = quote / usdQuote;
      }
    }

    fxCache = {
      data: rates,
      expiresAt: Date.now() + FX_TTL_MS
    };
    return rates;
  } catch {
    return fxCache?.data ?? { USD: 1 };
  } finally {
    clearTimeout(timeout);
  }
}
