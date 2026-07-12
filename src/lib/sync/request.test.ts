import { describe, expect, it } from "vitest";
import { readLimitedJSON } from "./request";

describe("limited JSON request reader", () => {
  it("returns parsed JSON and the actual UTF-8 byte length", async () => {
    const body = JSON.stringify({ label: "İstanbul" });
    const result = await readLimitedJSON(new Request("https://sync.example", {
      method: "POST",
      headers: { "content-type": "application/json; charset=utf-8" },
      body
    }), 1_000);
    expect(result.value).toEqual({ label: "İstanbul" });
    expect(result.byteLength).toBe(Buffer.byteLength(body));
  });

  it.each([
    ["text/plain", "{}", 415],
    ["application/json", "not-json", 400]
  ])("rejects invalid requests", async (contentType, body, status) => {
    await expect(readLimitedJSON(new Request("https://sync.example", {
      method: "POST",
      headers: { "content-type": contentType },
      body
    }), 1_000)).rejects.toMatchObject({ status });
  });

  it("stops reading once the streaming size ceiling is exceeded", async () => {
    await expect(readLimitedJSON(new Request("https://sync.example", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ data: "x".repeat(200) })
    }), 50)).rejects.toMatchObject({ status: 413 });
  });
});
