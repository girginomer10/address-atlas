import { beforeEach, describe, expect, it } from "vitest";
import {
  acquireAccountDeletionReplayDatabaseConcurrency,
  acquireBearerSessionDatabaseConcurrency
} from "@/lib/sync/auth-database-concurrency";
import {
  normalizeRequestClientKey,
  resetRateLimitsForTests
} from "@/lib/sync/rate-limit";
import {
  acquireNativeAuthorizationExchangeConcurrency,
  acquirePasskeyVerificationConcurrency
} from "./verification-concurrency";

describe("authentication database concurrency", () => {
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

  it("shares the reserved authentication budget with native code exchange", () => {
    const passkeyReleases = Array.from({ length: 3 }, (_, index) =>
      acquirePasskeyVerificationConcurrency(`client-${index}`, `credential-${index}`, 10)
    );
    const exchangeReleases = Array.from({ length: 2 }, (_, index) =>
      acquireNativeAuthorizationExchangeConcurrency(
        `exchange-client-${index}`,
        `native-code:${index}`,
        10
      )
    );

    expect([...passkeyReleases, ...exchangeReleases].every(
      (release) => typeof release === "function"
    )).toBe(true);
    expect(acquireNativeAuthorizationExchangeConcurrency(
      "overflow-client",
      "native-code:overflow",
      10
    )).toBeNull();
    for (const release of [...passkeyReleases, ...exchangeReleases]) release?.();
  });

  it("shares one non-queueing half-pool budget with bearer and replay lookups", () => {
    const releases = [
      acquirePasskeyVerificationConcurrency("passkey-a", "credential-a", 10),
      acquirePasskeyVerificationConcurrency("passkey-b", "credential-b", 10),
      acquireNativeAuthorizationExchangeConcurrency("native-a", "native-code:a", 10),
      acquireBearerSessionDatabaseConcurrency(
        normalizeRequestClientKey("bearer-a"),
        "session-a",
        10
      ),
      acquireAccountDeletionReplayDatabaseConcurrency(
        normalizeRequestClientKey("replay-a"),
        "a".repeat(64),
        10
      )
    ];

    expect(releases.every((release) => typeof release === "function")).toBe(true);
    expect(acquireBearerSessionDatabaseConcurrency(
      normalizeRequestClientKey("overflow-client"),
      "overflow-session",
      10
    )).toBeNull();

    for (const release of releases) release?.();
    const restored = acquireBearerSessionDatabaseConcurrency(
      normalizeRequestClientKey("overflow-client"),
      "overflow-session",
      10
    );
    expect(restored).toBeTypeOf("function");
    restored?.();
  });

  it("bounds bearer bursts independently by client and signed session", () => {
    const clientReleaseA = acquireBearerSessionDatabaseConcurrency(
      normalizeRequestClientKey("same-client"),
      "session-a",
      10
    );
    const clientReleaseB = acquireBearerSessionDatabaseConcurrency(
      normalizeRequestClientKey("same-client"),
      "session-b",
      10
    );
    expect(acquireBearerSessionDatabaseConcurrency(
      normalizeRequestClientKey("same-client"),
      "session-c",
      10
    )).toBeNull();

    clientReleaseA?.();
    const clientReleaseC = acquireBearerSessionDatabaseConcurrency(
      normalizeRequestClientKey("same-client"),
      "session-c",
      10
    );
    expect(clientReleaseC).toBeTypeOf("function");
    clientReleaseB?.();
    clientReleaseC?.();

    const sessionReleaseA = acquireBearerSessionDatabaseConcurrency(
      normalizeRequestClientKey("client-a"),
      "same-session",
      10
    );
    const sessionReleaseB = acquireBearerSessionDatabaseConcurrency(
      normalizeRequestClientKey("client-b"),
      "same-session",
      10
    );
    expect(acquireBearerSessionDatabaseConcurrency(
      normalizeRequestClientKey("client-c"),
      "same-session",
      10
    )).toBeNull();

    sessionReleaseA?.();
    sessionReleaseA?.();
    const sessionReleaseC = acquireBearerSessionDatabaseConcurrency(
      normalizeRequestClientKey("client-c"),
      "same-session",
      10
    );
    expect(sessionReleaseC).toBeTypeOf("function");
    sessionReleaseB?.();
    sessionReleaseC?.();
  });

  it("bounds unauthenticated deletion replays by normalized client and digest", () => {
    const oversizedClient = normalizeRequestClientKey("client".repeat(1_000));
    const releaseA = acquireAccountDeletionReplayDatabaseConcurrency(
      oversizedClient,
      "a".repeat(64),
      10
    );
    const releaseB = acquireAccountDeletionReplayDatabaseConcurrency(
      oversizedClient,
      "b".repeat(64),
      10
    );
    expect(releaseA).toBeTypeOf("function");
    expect(releaseB).toBeTypeOf("function");
    expect(acquireAccountDeletionReplayDatabaseConcurrency(
      oversizedClient,
      "c".repeat(64),
      10
    )).toBeNull();

    releaseA?.();
    releaseB?.();
    const digestRelease = acquireAccountDeletionReplayDatabaseConcurrency(
      normalizeRequestClientKey("client-a"),
      "d".repeat(64),
      10
    );
    expect(digestRelease).toBeTypeOf("function");
    expect(acquireAccountDeletionReplayDatabaseConcurrency(
      normalizeRequestClientKey("client-b"),
      "d".repeat(64),
      10
    )).toBeNull();
    digestRelease?.();
  });

  it("rejects parallel exchange attempts for one authorization code", () => {
    const release = acquireNativeAuthorizationExchangeConcurrency(
      "client-a",
      "native-code:same",
      10
    );

    expect(release).toBeTypeOf("function");
    expect(acquireNativeAuthorizationExchangeConcurrency(
      "client-b",
      "native-code:same",
      10
    )).toBeNull();
    release?.();
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
