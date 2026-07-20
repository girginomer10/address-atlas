import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { clientKey, rateLimitMany, resetRateLimitsForTests } from "./rate-limit";

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

  it("fails closed instead of growing beyond the tracked-key ceiling", () => {
    for (let index = 0; index < 50_000; index += 1) {
      expect(rateLimitOne(`key-${index}`, 1, 60_000)).toBe(true);
    }
    expect(rateLimitOne("overflow", 1, 60_000)).toBe(false);
  });

  it("bounds attacker-controlled forwarded identifiers", () => {
    const request = new Request("https://sync.example", {
      headers: { "x-forwarded-for": "x".repeat(10_000) }
    });
    expect(clientKey(request)).toMatch(/^sha256:[a-f0-9]{64}$/);
  });
});
