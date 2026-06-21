// Simple in-memory fixed-window rate limiter. Adequate for the single-instance
// sync container (compose.prod.yml runs one `web` replica); it is NOT shared
// across replicas, so scale-out would need a Redis/Postgres-backed limiter.

type Bucket = { count: number; resetAt: number };

const buckets = new Map<string, Bucket>();
// Bound the map so a flood of distinct keys can't grow it without limit.
const MAX_TRACKED_KEYS = 50_000;

/**
 * Returns true if the call is allowed, false if the key has exceeded `limit`
 * within the current `windowMs`.
 */
export function rateLimit(key: string, limit: number, windowMs: number): boolean {
  const now = Date.now();
  const bucket = buckets.get(key);

  if (!bucket || now >= bucket.resetAt) {
    if (!bucket && buckets.size >= MAX_TRACKED_KEYS) sweepExpired(now);
    buckets.set(key, { count: 1, resetAt: now + windowMs });
    return true;
  }

  if (bucket.count >= limit) return false;
  bucket.count += 1;
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
  if (forwarded) return forwarded.split(",")[0]!.trim();
  const realIp = request.headers.get("x-real-ip");
  if (realIp) return realIp.trim();
  return "unknown";
}
