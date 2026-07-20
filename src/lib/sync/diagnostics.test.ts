import { afterEach, describe, expect, it, vi } from "vitest";
import {
  diagnosticHeaders,
  recordSecurityEvent,
  requestDiagnostics
} from "./diagnostics";

describe("privacy-safe server diagnostics", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("keeps a valid proxy request id and replaces unsafe values", () => {
    const valid = requestDiagnostics(new Request("https://sync.example", {
      headers: { "x-request-id": "proxy_req-1234" }
    }), "/healthz");
    const unsafe = requestDiagnostics(new Request("https://sync.example", {
      headers: { "x-request-id": "short" }
    }), "/healthz");

    expect(valid.requestId).toBe("proxy_req-1234");
    expect(unsafe.requestId).toMatch(/^[0-9a-f-]{36}$/);
    expect(diagnosticHeaders(valid, { "cache-control": "no-store" })).toEqual({
      "cache-control": "no-store",
      "x-request-id": "proxy_req-1234"
    });
  });

  it("emits only the fixed diagnostic schema", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const context = { requestId: "request_1234", route: "/vault/latest" };
    recordSecurityEvent("vault.request_rejected", context, {
      status: 400,
      reason: "invalid_body"
    });

    const parsed = JSON.parse(String(warn.mock.calls[0]?.[0]));
    expect(parsed).toMatchObject({
      service: "address-atlas-sync",
      event: "vault.request_rejected",
      requestId: "request_1234",
      route: "/vault/latest",
      status: 400,
      reason: "invalid_body"
    });
    expect(Object.keys(parsed).sort()).toEqual([
      "event",
      "reason",
      "requestId",
      "route",
      "service",
      "severity",
      "status",
      "timestamp"
    ]);
  });
});
