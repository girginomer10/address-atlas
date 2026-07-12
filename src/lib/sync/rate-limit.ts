import { createHash } from "node:crypto";

// Simple in-memory fixed-window rate limiter. Adequate for the single-instance
// sync container (compose.prod.yml runs one `web` replica); it is NOT shared
// across replicas, so scale-out would need a Redis/Postgres-backed limiter.

type Bucket = { count: number; resetAt: number };

const buckets = new Map<string, Bucket>();
// Bound the map so a flood of distinct keys can't grow it without limit.
const MAX_TRACKED_KEYS = 50_000;

export interface RateLimitRule {
  key: string;
  limit: number;
  windowMs: number;
}

/**
 * Returns true if the call is allowed, false if the key has exceeded `limit`
 * within the current `windowMs`.
 */
export function rateLimit(key: string, limit: number, windowMs: number): boolean {
  return rateLimitMany([{ key, limit, windowMs }]);
}

/**
 * Applies all limits atomically: a rejected request does not consume any of the
 * other buckets. New keys fail closed when the bounded map is saturated.
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

function sweepExpired(now: number) {
  for (const [key, bucket] of buckets) {
    if (now >= bucket.resetAt) buckets.delete(key);
  }
}

/** Best-effort client identity from proxy headers (Caddy sets X-Forwarded-For). */
export function clientKey(request: Request): string {
  const forwarded = request.headers.get("x-forwarded-for");
  if (forwarded) return boundedKey(forwarded.split(",")[0]!.trim());
  const realIp = request.headers.get("x-real-ip");
  if (realIp) return boundedKey(realIp.trim());
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

export function resetRateLimitsForTests() {
  buckets.clear();
}
