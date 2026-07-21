import { afterEach, describe, expect, it, vi } from "vitest";
import {
  diagnosticHeaders,
  OperationalError,
  operationalErrorCode,
  recordSecurityEvent,
  requestDiagnostics
} from "./diagnostics";

describe("privacy-safe server diagnostics", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("replaces every untrusted request id inside the application boundary", () => {
    const first = requestDiagnostics(new Request("https://sync.example", {
      headers: { "x-request-id": "proxy_req-1234" }
    }), "/healthz");
    const second = requestDiagnostics(new Request("https://sync.example", {
      headers: { "x-request-id": "encoded_private_value_1234" }
    }), "/healthz");

    expect(first.requestId).toMatch(/^[0-9a-f-]{36}$/);
    expect(second.requestId).toMatch(/^[0-9a-f-]{36}$/);
    expect(first.requestId).not.toBe(second.requestId);
    expect(first.requestId).not.toContain("proxy_req");
    expect(diagnosticHeaders(first, { "cache-control": "no-store" })).toEqual({
      "cache-control": "no-store",
      "x-request-id": first.requestId
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

  it("emits an allow-listed operational code without exception details", () => {
    const error = new OperationalError(
      "schema_contract_invalid",
      "column drift includes postgres://admin:secret@db"
    );
    const output = vi.spyOn(console, "error").mockImplementation(() => undefined);
    recordSecurityEvent("health.not_ready", {
      requestId: "request_1234",
      route: "/healthz"
    }, {
      status: 503,
      reason: "runtime_or_database_not_ready",
      errorCode: operationalErrorCode(error, "unknown_internal_error")
    });

    const serialized = String(output.mock.calls[0]?.[0]);
    expect(JSON.parse(serialized)).toMatchObject({
      reason: "runtime_or_database_not_ready",
      errorCode: "schema_contract_invalid"
    });
    expect(serialized).not.toContain("secret");
    expect(serialized).not.toContain("column drift");
  });

  it("normalizes PostgreSQL failures without logging raw database codes", () => {
    expect(operationalErrorCode({ code: "28P01" }, "unknown_internal_error"))
      .toBe("database_connection_failed");
    expect(operationalErrorCode({ code: "23505" }, "unknown_internal_error"))
      .toBe("database_query_failed");
  });

  it.each([
    "ENOTFOUND",
    "EAI_AGAIN",
    "57P02",
    "57P03"
  ])("classifies connection failure %s without exposing its details", (code) => {
    const error = Object.assign(
      new Error("postgres://admin:secret@private-db.internal/address_atlas"),
      { code }
    );
    const output = vi.spyOn(console, "error").mockImplementation(() => undefined);

    recordSecurityEvent("health.not_ready", {
      requestId: "request_1234",
      route: "/healthz"
    }, {
      status: 503,
      reason: "runtime_or_database_not_ready",
      errorCode: operationalErrorCode(error, "migration_failed")
    });

    const serialized = String(output.mock.calls[0]?.[0]);
    expect(JSON.parse(serialized)).toMatchObject({
      errorCode: "database_connection_failed"
    });
    expect(serialized).not.toContain(code);
    expect(serialized).not.toContain("secret");
    expect(serialized).not.toContain("private-db.internal");
  });
});
