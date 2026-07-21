import { beforeEach, describe, expect, it } from "vitest";
import { resetRateLimitsForTests } from "@/lib/sync/rate-limit";
import { acquirePasskeyVerificationConcurrency } from "./verification-concurrency";

describe("passkey verification concurrency", () => {
  beforeEach(() => resetRateLimitsForTests());

  it("rejects parallel work for one credential before it can queue on PostgreSQL", () => {
    const release = acquirePasskeyVerificationConcurrency("client-a", "credential-a", 10);

    expect(release).toBeTypeOf("function");
    expect(acquirePasskeyVerificationConcurrency("client-b", "credential-a", 10)).toBeNull();

    release?.();
    expect(acquirePasskeyVerificationConcurrency("client-b", "credential-a", 10))
      .toBeTypeOf("function");
  });

  it("reserves at least half the configured pool for non-authentication traffic", () => {
    const releases = Array.from({ length: 5 }, (_, index) =>
      acquirePasskeyVerificationConcurrency(`client-${index}`, `credential-${index}`, 10)
    );

    expect(releases.every((release) => typeof release === "function")).toBe(true);
    expect(acquirePasskeyVerificationConcurrency("client-six", "credential-six", 10)).toBeNull();
    for (const release of releases) release?.();
  });

  it("reserves one client even at the smallest supported two-client pool", () => {
    const release = acquirePasskeyVerificationConcurrency("client-a", "credential-a", 2);

    expect(release).toBeTypeOf("function");
    expect(acquirePasskeyVerificationConcurrency("client-b", "credential-b", 2)).toBeNull();
    release?.();
  });

  it("rejects an invalid pool size that cannot reserve non-authentication capacity", () => {
    expect(() => acquirePasskeyVerificationConcurrency("client-a", "credential-a", 1))
      .toThrow(/reserved capacity/i);
  });
});
