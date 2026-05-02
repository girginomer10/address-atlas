import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { getUsdFxRates, normalizeDisplayCurrency, resetFxCacheForTesting } from "./fx";

describe("display currency normalization", () => {
  it("accepts the four supported currency codes regardless of case", () => {
    expect(normalizeDisplayCurrency("usd")).toBe("USD");
    expect(normalizeDisplayCurrency("eur")).toBe("EUR");
    expect(normalizeDisplayCurrency("gbp")).toBe("GBP");
    expect(normalizeDisplayCurrency("try")).toBe("TRY");
  });

  it("falls back to USD for unknown currencies", () => {
    expect(normalizeDisplayCurrency("JPY")).toBe("USD");
    expect(normalizeDisplayCurrency("")).toBe("USD");
    expect(normalizeDisplayCurrency(null)).toBe("USD");
    expect(normalizeDisplayCurrency(undefined)).toBe("USD");
  });
});

describe("USD FX rate fetching", () => {
  beforeEach(() => {
    resetFxCacheForTesting();
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
    vi.useRealTimers();
    resetFxCacheForTesting();
  });

  it("derives USD->target rates from the tether quote", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          tether: { usd: 1, eur: 0.92, gbp: 0.79, try: 35 }
        })
      })
    );

    const rates = await getUsdFxRates();
    expect(rates.USD).toBe(1);
    expect(rates.EUR).toBeCloseTo(0.92, 5);
    expect(rates.GBP).toBeCloseTo(0.79, 5);
    expect(rates.TRY).toBeCloseTo(35, 5);
  });

  it("normalizes when tether is not exactly 1 USD", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          tether: { usd: 0.999, eur: 0.92, gbp: 0.78, try: 34 }
        })
      })
    );

    const rates = await getUsdFxRates();
    expect(rates.EUR).toBeCloseTo(0.92 / 0.999, 5);
  });

  it("falls back to USD-only rates when CoinGecko fails", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("network down")));

    await expect(getUsdFxRates()).resolves.toEqual({ USD: 1 });
  });

  it("falls back to USD-only rates when the tether quote is missing", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({ tether: {} })
      })
    );

    await expect(getUsdFxRates()).resolves.toEqual({ USD: 1 });
  });

  it("returns the cached payload while it is fresh", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-05-02T12:00:00.000Z"));

    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ tether: { usd: 1, eur: 0.91, gbp: 0.78, try: 33 } })
      })
      .mockResolvedValueOnce({ ok: false });
    vi.stubGlobal("fetch", fetchMock);

    const first = await getUsdFxRates();
    expect(first.EUR).toBeCloseTo(0.91, 5);

    vi.setSystemTime(new Date("2026-05-02T12:01:00.000Z"));
    const second = await getUsdFxRates();
    expect(second).toEqual(first);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
});
