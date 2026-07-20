/**
 * Next.js instrumentation hook (stable in Next 16; no config flag required).
 * Runs once per server process at boot, before any request is served.
 *
 * A misconfigured production container must fail at startup instead of at its
 * first request, so the same validation /healthz performs per probe runs here
 * once and throws — the container never reports healthy with broken config.
 */
export async function register() {
  if (process.env.NEXT_RUNTIME === "nodejs" && process.env.NODE_ENV === "production") {
    // Dynamic import inside the runtime guard keeps this Node-only module
    // (and its transitive dependencies) out of the edge bundle.
    const { validateSyncRuntimeConfig } = await import("@/lib/sync/config");
    try {
      validateSyncRuntimeConfig();
    } catch (error) {
      const { generatedDiagnostics, recordSecurityEvent } = await import("@/lib/sync/diagnostics");
      recordSecurityEvent("config.unavailable", generatedDiagnostics("instrumentation.register"), {
        status: 503,
        reason: "startup_configuration_invalid",
        severity: "error"
      });
      throw error;
    }
  }
}
