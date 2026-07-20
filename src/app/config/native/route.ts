import { NextResponse } from "next/server";
import {
  diagnosticHeaders,
  generatedDiagnostics,
  recordSecurityEvent,
  requestDiagnostics
} from "@/lib/sync/diagnostics";
import { nativeConfigDigest } from "@/lib/sync/native-config-digest";
import { getNativeEndpointConfig } from "@/lib/sync/native-config";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

// force-dynamic paired with "cache-control: public, max-age=300" is
// intentional: Next's own route cache is disabled so every origin hit
// re-reads the env-driven config, while CDNs/proxies may still cache the
// response for five minutes to absorb client fan-out.
export async function GET(request?: Request) {
  const diagnostics = request
    ? requestDiagnostics(request, "/config/native")
    : generatedDiagnostics("/config/native");
  try {
    const config = getNativeEndpointConfig();
    const digest = nativeConfigDigest(config);
    const buildRevision = process.env.ADDRESS_ATLAS_BUILD_REVISION;
    const isDeploymentProbe = request
      ? ["deployment_probe", "release_probe"].some((name) => new URL(request.url).searchParams.has(name))
      : false;
    const headers: Record<string, string> = {
      "cache-control": isDeploymentProbe ? "no-store" : "public, max-age=300",
      etag: `"sha256-${digest}"`
    };
    if (buildRevision && /^[0-9a-f]{40}$/.test(buildRevision)) {
      headers["x-address-atlas-build-revision"] = buildRevision;
    }
    return NextResponse.json(config, {
      // Do not attach a per-request correlation header to this deliberately
      // cacheable response; a CDN could replay another caller's request ID.
      headers
    });
  } catch {
    recordSecurityEvent("config.unavailable", diagnostics, {
      status: 503,
      reason: "configuration_invalid",
      severity: "error"
    });
    return NextResponse.json(
      { error: "Native configuration unavailable." },
      {
        status: 503,
        headers: diagnosticHeaders(diagnostics, { "cache-control": "no-store" })
      }
    );
  }
}
