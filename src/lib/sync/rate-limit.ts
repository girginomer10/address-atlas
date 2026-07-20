import { createHash } from "node:crypto";

// Simple in-memory fixed-window rate limiter. Adequate for the single-instance
// sync container (compose.prod.yml runs one `web` replica); it is NOT shared
// across replicas, so scale-out would need a Redis/Postgres-backed limiter.

type Bucket = { count: number; resetAt: number };

const buckets = new Map<string, Bucket>();
const activeConcurrency = new Map<string, number>();
// Bound the map so a flood of distinct keys can't grow it without limit.
const MAX_TRACKED_KEYS = 50_000;

export interface RateLimitRule {
  key: string;
  limit: number;
  windowMs: number;
}

export interface ConcurrencyLimitRule {
  key: string;
  limit: number;
}

/**
 * Applies all limits atomically: a rejected request does not consume any of the
 * other buckets. New keys fail closed when the bounded map is saturated.
 * Returns true if the call is allowed, false if any key has exceeded its
 * `limit` within the current `windowMs`.
 */
export function rateLimitMany(rules: RateLimitRule[]): boolean {
  const now = Date.now();
  const normalized = deduplicateRules(rules);
  if (normalized.length === 0) return true;

  if (buckets.size >= MAX_TRACKED_KEYS) sweepExpired(now);
  let newKeys = 0;
  for (const rule of normalized) {
    if (!Number.isSafeInteger(rule.limit) || rule.limit < 1 || !Number.isFinite(rule.windowMs) || rule.windowMs < 1) {
      throw new Error("Invalid rate-limit rule.");
    }
    const bucket = buckets.get(rule.key);
    if (!bucket || now >= bucket.resetAt) {
      if (!bucket) newKeys += 1;
      continue;
    }
    if (bucket.count >= rule.limit) return false;
  }

  if (buckets.size + newKeys > MAX_TRACKED_KEYS) return false;

  for (const rule of normalized) {
    const bucket = buckets.get(rule.key);
    if (!bucket || now >= bucket.resetAt) {
      buckets.set(rule.key, { count: 1, resetAt: now + rule.windowMs });
    } else {
      bucket.count += 1;
    }
  }
  return true;
}

/**
 * Atomically reserves every requested active-operation slot. The returned
 * release function is idempotent so callers can safely invoke it from a
 * `finally` block. This complements request-rate limits: a bounded number of
 * slow, individually allowed bodies can remain buffered at one time.
 */
export function acquireConcurrencyMany(
  rules: ConcurrencyLimitRule[]
): (() => void) | null {
  const normalized = deduplicateConcurrencyRules(rules);
  if (normalized.length === 0) return () => undefined;

  let newKeys = 0;
  for (const rule of normalized) {
    if (!Number.isSafeInteger(rule.limit) || rule.limit < 1) {
      throw new Error("Invalid concurrency-limit rule.");
    }
    const current = activeConcurrency.get(rule.key);
    if (current === undefined) newKeys += 1;
    else if (current >= rule.limit) return null;
  }
  if (activeConcurrency.size + newKeys > MAX_TRACKED_KEYS) return null;

  for (const rule of normalized) {
    activeConcurrency.set(rule.key, (activeConcurrency.get(rule.key) ?? 0) + 1);
  }

  let released = false;
  return () => {
    if (released) return;
    released = true;
    for (const rule of normalized) {
      const current = activeConcurrency.get(rule.key);
      if (current === undefined) continue;
      if (current <= 1) activeConcurrency.delete(rule.key);
      else activeConcurrency.set(rule.key, current - 1);
    }
  };
}

function sweepExpired(now: number) {
  for (const [key, bucket] of buckets) {
    if (now >= bucket.resetAt) buckets.delete(key);
  }
}

/**
 * Best-effort client identity from the production proxy boundary. Caddy is the
 * only published peer and explicitly sets X-Forwarded-For to the client IP
 * (header_up in the Caddyfile), so client-supplied values never reach here.
 */
export function clientKey(request: Request): string {
  const forwarded = request.headers.get("x-forwarded-for");
  if (forwarded) return boundedKey(forwarded.split(",")[0]!.trim());
  return "unknown";
}

function boundedKey(value: string) {
  if (!value) return "unknown";
  if (value.length <= 128) return value;
  return `sha256:${createHash("sha256").update(value).digest("hex")}`;
}

function deduplicateRules(rules: RateLimitRule[]) {
  const byKey = new Map<string, RateLimitRule>();
  for (const rule of rules) {
    const key = boundedKey(rule.key);
    const existing = byKey.get(key);
    if (!existing) {
      byKey.set(key, { ...rule, key });
      continue;
    }
    // A duplicate key must honor the strictest compatible limits.
    byKey.set(key, {
      key,
      limit: Math.min(existing.limit, rule.limit),
      windowMs: Math.max(existing.windowMs, rule.windowMs)
    });
  }
  return [...byKey.values()];
}

function deduplicateConcurrencyRules(rules: ConcurrencyLimitRule[]) {
  const byKey = new Map<string, ConcurrencyLimitRule>();
  for (const rule of rules) {
    const key = boundedKey(rule.key);
    const existing = byKey.get(key);
    byKey.set(key, {
      key,
      limit: existing ? Math.min(existing.limit, rule.limit) : rule.limit
    });
  }
  return [...byKey.values()];
}

export function resetRateLimitsForTests() {
  buckets.clear();
  activeConcurrency.clear();
}
