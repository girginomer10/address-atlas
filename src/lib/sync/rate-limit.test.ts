import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  acquireConcurrencyMany,
  clientKey,
  normalizeRequestClientKey,
  rateLimitMany,
  rateLimitWeightedMany,
  resetRateLimitsForTests
} from "./rate-limit";

function rateLimitOne(key: string, limit: number, windowMs: number) {
  return rateLimitMany([{ key, limit, windowMs }]);
}

describe("bounded rate limiter", () => {
  beforeEach(() => {
    resetRateLimitsForTests();
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-12T12:00:00Z"));
  });

  afterEach(() => {
    resetRateLimitsForTests();
    vi.useRealTimers();
  });

  it("enforces limits and resets expired windows", () => {
    expect(rateLimitOne("client", 2, 1_000)).toBe(true);
    expect(rateLimitOne("client", 2, 1_000)).toBe(true);
    expect(rateLimitOne("client", 2, 1_000)).toBe(false);
    vi.advanceTimersByTime(1_001);
    expect(rateLimitOne("client", 2, 1_000)).toBe(true);
  });

  it("does not consume other buckets when a multi-rule request is rejected", () => {
    expect(rateLimitOne("full", 1, 60_000)).toBe(true);
    expect(rateLimitMany([
      { key: "full", limit: 1, windowMs: 60_000 },
      { key: "untouched", limit: 1, windowMs: 60_000 }
    ])).toBe(false);
    expect(rateLimitOne("untouched", 1, 60_000)).toBe(true);
  });

  it("charges exact integer weights and resets expired windows", () => {
    expect(rateLimitWeightedMany([
      { key: "response-bytes", limit: 10, windowMs: 1_000, weight: 6 }
    ])).toBe(true);
    expect(rateLimitWeightedMany([
      { key: "response-bytes", limit: 10, windowMs: 1_000, weight: 4 }
    ])).toBe(true);
    expect(rateLimitWeightedMany([
      { key: "response-bytes", limit: 10, windowMs: 1_000, weight: 1 }
    ])).toBe(false);

    vi.advanceTimersByTime(1_001);
    expect(rateLimitWeightedMany([
      { key: "response-bytes", limit: 10, windowMs: 1_000, weight: 10 }
    ])).toBe(true);
  });

  it("rejects weighted rules atomically without consuming other budgets", () => {
    expect(rateLimitWeightedMany([
      { key: "full", limit: 10, windowMs: 60_000, weight: 7 }
    ])).toBe(true);

    expect(rateLimitWeightedMany([
      { key: "full", limit: 10, windowMs: 60_000, weight: 4 },
      { key: "untouched", limit: 5, windowMs: 60_000, weight: 5 }
    ])).toBe(false);

    expect(rateLimitWeightedMany([
      { key: "untouched", limit: 5, windowMs: 60_000, weight: 5 }
    ])).toBe(true);
  });

  it("validates every weighted rule before changing any bucket", () => {
    const invalidRules = [
      { key: "invalid", limit: 0, windowMs: 1_000, weight: 1 },
      { key: "invalid", limit: 1.5, windowMs: 1_000, weight: 1 },
      { key: "invalid", limit: 1, windowMs: 0, weight: 1 },
      { key: "invalid", limit: 1, windowMs: 1.5, weight: 1 },
      { key: "invalid", limit: 1, windowMs: 1_000, weight: 0 },
      { key: "invalid", limit: 1, windowMs: 1_000, weight: 1.5 },
      {
        key: "invalid",
        limit: Number.MAX_SAFE_INTEGER + 1,
        windowMs: 1_000,
        weight: 1
      },
      {
        key: "invalid",
        limit: 1,
        windowMs: Number.MAX_SAFE_INTEGER,
        weight: 1
      }
    ];

    for (const invalid of invalidRules) {
      expect(() => rateLimitWeightedMany([
        { key: "untouched", limit: 1, windowMs: 60_000, weight: 1 },
        invalid
      ])).toThrow("Invalid weighted rate-limit rule.");
    }

    expect(rateLimitWeightedMany([
      { key: "untouched", limit: 1, windowMs: 60_000, weight: 1 }
    ])).toBe(true);
  });

  it("defends safe-integer boundaries without overflowing counters", () => {
    expect(rateLimitWeightedMany([{
      key: "maximum",
      limit: Number.MAX_SAFE_INTEGER,
      windowMs: 60_000,
      weight: Number.MAX_SAFE_INTEGER - 1
    }])).toBe(true);
    expect(rateLimitWeightedMany([{
      key: "maximum",
      limit: Number.MAX_SAFE_INTEGER,
      windowMs: 60_000,
      weight: 1
    }])).toBe(true);
    expect(rateLimitWeightedMany([{
      key: "maximum",
      limit: Number.MAX_SAFE_INTEGER,
      windowMs: 60_000,
      weight: 1
    }])).toBe(false);

    expect(rateLimitWeightedMany([{
      key: "oversized-charge",
      limit: 10,
      windowMs: 60_000,
      weight: 11
    }])).toBe(false);
    expect(rateLimitWeightedMany([{
      key: "oversized-charge",
      limit: 10,
      windowMs: 60_000,
      weight: 10
    }])).toBe(true);
  });

  it("deduplicates a weighted budget using its strictest rule", () => {
    expect(rateLimitWeightedMany([
      { key: "duplicate", limit: 10, windowMs: 1_000, weight: 2 },
      { key: "duplicate", limit: 8, windowMs: 2_000, weight: 3 }
    ])).toBe(true);
    expect(rateLimitWeightedMany([
      { key: "duplicate", limit: 8, windowMs: 2_000, weight: 5 }
    ])).toBe(true);
    expect(rateLimitWeightedMany([
      { key: "duplicate", limit: 8, windowMs: 2_000, weight: 1 }
    ])).toBe(false);
  });

  it("fails closed instead of growing beyond the tracked-key ceiling", () => {
    for (let index = 0; index < 50_000; index += 1) {
      expect(rateLimitOne(`key-${index}`, 1, 60_000)).toBe(true);
    }
    expect(rateLimitOne("overflow", 1, 60_000)).toBe(false);
    expect(rateLimitWeightedMany([
      { key: "weighted-overflow", limit: 1, windowMs: 60_000, weight: 1 }
    ])).toBe(false);

    resetRateLimitsForTests();
    expect(rateLimitWeightedMany([
      { key: "weighted-after-reset", limit: 1, windowMs: 60_000, weight: 1 }
    ])).toBe(true);
  });

  it("bounds attacker-controlled forwarded identifiers", () => {
    const request = new Request("https://sync.example", {
      headers: { "x-forwarded-for": "x".repeat(10_000) }
    });
    expect(clientKey(request)).toMatch(/^sha256:[a-f0-9]{64}$/);
  });

  it("normalizes direct client identities to bounded fail-closed keys", () => {
    expect(normalizeRequestClientKey(undefined)).toBe("unknown");
    expect(normalizeRequestClientKey("x".repeat(10_000)))
      .toMatch(/^sha256:[a-f0-9]{64}$/);
  });

  it("reserves concurrency limits atomically and releases them idempotently", () => {
    const first = acquireConcurrencyMany([
      { key: "global", limit: 2 },
      { key: "account", limit: 1 }
    ]);
    expect(first).toBeTypeOf("function");

    expect(acquireConcurrencyMany([
      { key: "global", limit: 2 },
      { key: "account", limit: 1 }
    ])).toBeNull();

    const other = acquireConcurrencyMany([
      { key: "global", limit: 2 },
      { key: "other-account", limit: 1 }
    ]);
    expect(other).toBeTypeOf("function");
    expect(acquireConcurrencyMany([{ key: "global", limit: 2 }])).toBeNull();

    first!();
    first!();
    const replacement = acquireConcurrencyMany([
      { key: "global", limit: 2 },
      { key: "account", limit: 1 }
    ]);
    expect(replacement).toBeTypeOf("function");

    other!();
    replacement!();
  });
});
