import { afterEach, describe, expect, it, vi } from "vitest";
import { getPrices } from "./prices";

describe("price fetching", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it("returns an empty map when CoinGecko rejects", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("network down")));

    await expect(getPrices(["review-reject-coin"])).resolves.toEqual({});
  });

  it("falls back to stale cache when a refreshed request fails", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-01-01T00:00:00.000Z"));

    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          "review-stale-coin": {
            usd: 7,
            usd_24h_change: 1
          }
        })
      })
      .mockResolvedValueOnce({ ok: false });
    vi.stubGlobal("fetch", fetchMock);

    await expect(getPrices(["review-stale-coin"])).resolves.toEqual({
      "review-stale-coin": {
        usd: 7,
        usd_24h_change: 1
      }
    });

    vi.setSystemTime(new Date("2026-01-01T00:01:00.000Z"));

    await expect(getPrices(["review-stale-coin"])).resolves.toEqual({
      "review-stale-coin": {
        usd: 7,
        usd_24h_change: 1
      }
    });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("does not cache empty successful CoinGecko responses", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({})
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          "review-empty-cache-coin": {
            usd: 3,
            usd_24h_change: 0
          }
        })
      });
    vi.stubGlobal("fetch", fetchMock);

    await expect(getPrices(["review-empty-cache-coin"])).resolves.toEqual({});
    await expect(getPrices(["review-empty-cache-coin"])).resolves.toEqual({
      "review-empty-cache-coin": {
        usd: 3,
        usd_24h_change: 0
      }
    });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("uses stale prices when a refresh returns an empty map", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-01-01T00:00:00.000Z"));

    const stalePrice = {
      "review-empty-refresh-coin": {
        usd: 9,
        usd_24h_change: 2
      }
    };
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => stalePrice
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({})
      });
    vi.stubGlobal("fetch", fetchMock);

    await expect(getPrices(["review-empty-refresh-coin"])).resolves.toEqual(stalePrice);

    vi.setSystemTime(new Date("2026-01-01T00:01:00.000Z"));

    await expect(getPrices(["review-empty-refresh-coin"])).resolves.toEqual(stalePrice);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("times out stuck CoinGecko requests", async () => {
    vi.useFakeTimers();
    vi.stubGlobal(
      "fetch",
      vi.fn((_url: string | URL | Request, init?: RequestInit) =>
        new Promise((_resolve, reject) => {
          init?.signal?.addEventListener("abort", () => reject(new Error("aborted")));
        })
      )
    );

    const result = getPrices(["review-timeout-coin"]);
    await vi.advanceTimersByTimeAsync(4_600);

    await expect(result).resolves.toEqual({});
  });
});
