import { describe, expect, it } from "vitest";
import { toMoney, toUsd } from "./format";

describe("toMoney", () => {
  it("formats USD amounts unchanged when no rates are supplied", () => {
    expect(toMoney(123.45, "USD")).toBe("$123.45");
  });

  it("converts USD into the requested currency using the provided rate", () => {
    const formatted = toMoney(100, "EUR", { USD: 1, EUR: 0.92 });
    expect(formatted).toContain("92.00");
    expect(formatted).toMatch(/€/);
  });

  it("converts USD into Turkish lira when a TRY rate is provided", () => {
    const formatted = toMoney(10, "TRY", { USD: 1, TRY: 35 });
    expect(formatted).toContain("350.00");
  });

  it("falls back to USD formatting when the requested currency has no rate", () => {
    expect(toMoney(50, "EUR", { USD: 1 })).toBe("$50.00");
  });

  it("falls back to USD when the requested currency is unknown", () => {
    expect(toMoney(7.5, "XYZ", { USD: 1 })).toBe("$7.50");
  });

  it("uses extra fraction digits for sub-unit values", () => {
    expect(toMoney(0.0001234, "USD")).toMatch(/\$0\.0001/);
  });

  it("delegates the legacy toUsd helper to toMoney", () => {
    expect(toUsd(42)).toBe(toMoney(42, "USD"));
  });
});
