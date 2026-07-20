import { afterEach, describe, expect, it, vi } from "vitest";
import { readLimitedBody, readLimitedJSON } from "./request";

describe("limited JSON request reader", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

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
    }), 50)).rejects.toMatchObject({ status: 413, byteLength: 50 });
  });

  it("reports chargeable bytes even when Content-Length is malformed", async () => {
    const body = "{\"ok\":true}";
    await expect(readLimitedBody(new Request("https://sync.example", {
      method: "POST",
      headers: { "content-length": "not-a-number" },
      body
    }), 1_000)).rejects.toMatchObject({
      status: 400,
      byteLength: Buffer.byteLength(body)
    });
  });

  it("cancels a slow-drip stream at an absolute body deadline", async () => {
    let cancelled = false;
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode("{"));
      },
      cancel() {
        cancelled = true;
      }
    });
    const request = new Request("https://sync.example", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body,
      duplex: "half"
    } as RequestInit);

    await expect(readLimitedJSON(request, 1_000, 25)).rejects.toMatchObject({
      status: 408,
      message: "Request body took too long."
    });
    expect(cancelled).toBe(true);
  });

  it("keeps the deadline bounded when the wall clock jumps backwards", async () => {
    const dateNow = vi.spyOn(Date, "now")
      .mockReturnValueOnce(1_000)
      .mockReturnValue(-1_000_000_000);
    let scheduledDelay = Number.POSITIVE_INFINITY;
    vi.spyOn(globalThis, "setTimeout").mockImplementation(((
      callback: (...args: never[]) => void,
      delay?: number
    ) => {
      scheduledDelay = Number(delay);
      queueMicrotask(() => (callback as () => void)());
      return 1 as unknown as ReturnType<typeof setTimeout>;
    }) as unknown as typeof setTimeout);

    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode("{"));
      }
    });
    const request = new Request("https://sync.example", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body,
      duplex: "half"
    } as RequestInit);

    await expect(readLimitedJSON(request, 1_000, 25)).rejects.toMatchObject({ status: 408 });
    expect(dateNow).not.toHaveBeenCalled();
    expect(scheduledDelay).toBeGreaterThan(0);
    expect(scheduledDelay).toBeLessThanOrEqual(25);
  });
});
