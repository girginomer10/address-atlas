import { afterEach, describe, expect, it, vi } from "vitest";
import { GET } from "./route";

describe("sync liveness", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("reports liveness without configuration or database work", async () => {
    const response = await GET();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, service: "address-atlas-sync" });
    expect(response.headers.get("cache-control")).toBe("no-store");
  });

  it("stays live while runtime configuration and the database are broken", async () => {
    // /livez only proves the process serves requests. Unlike /healthz it must
    // not depend on env validation or PostgreSQL, so a database blip cannot
    // take the proxy's active health probe (and with it every route) down.
    vi.stubEnv("SYNC_SESSION_SECRET", "short");
    vi.stubEnv("SYNC_DATABASE_URL", "not-a-postgres-url");

    const response = await GET();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, service: "address-atlas-sync" });
  });
});
