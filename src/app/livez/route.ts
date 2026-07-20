import { NextResponse } from "next/server";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

// Pure liveness: this handler deliberately performs zero configuration or
// database work. Caddy's active health probe targets /livez so a Postgres
// blip does not 502 every route; the deep /healthz readiness check remains
// the container healthcheck.
export async function GET() {
  return NextResponse.json(
    { ok: true, service: "address-atlas-sync" },
    { headers: { "cache-control": "no-store" } }
  );
}
