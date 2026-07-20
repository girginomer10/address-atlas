import { performance } from "node:perf_hooks";

export class RequestBodyError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
    this.name = "RequestBodyError";
  }
}

export interface ParsedJSONBody {
  value: unknown;
  byteLength: number;
}

export const REQUEST_BODY_DEADLINE_MS = 60_000;

/** Read and parse JSON without trusting Content-Length or buffering past maxBytes. */
export async function readLimitedJSON(
  request: Request,
  maxBytes: number,
  deadlineMs = REQUEST_BODY_DEADLINE_MS
): Promise<ParsedJSONBody> {
  if (!Number.isSafeInteger(deadlineMs) || deadlineMs < 1) {
    throw new Error("Request body deadline must be a positive integer.");
  }
  const contentType = request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase();
  if (contentType !== "application/json") {
    throw new RequestBodyError("Content-Type must be application/json.", 415);
  }

  const declared = request.headers.get("content-length");
  if (declared !== null) {
    const length = Number(declared);
    if (!Number.isSafeInteger(length) || length < 0) {
      throw new RequestBodyError("Invalid Content-Length.", 400);
    }
    if (length > maxBytes) throw new RequestBodyError("Request body is too large.", 413);
  }

  const chunks: Uint8Array[] = [];
  let byteLength = 0;
  const reader = request.body?.getReader();
  if (reader) {
    // Wall-clock time can jump backwards under NTP/operator correction and
    // silently extend a slow-drip upload. performance.now() is monotonic within
    // this process, so the absolute body deadline cannot be moved by clock skew.
    const deadlineAt = performance.now() + deadlineMs;
    try {
      while (true) {
        const { done, value } = await readBeforeDeadline(reader, deadlineAt);
        if (done) break;
        byteLength += value.byteLength;
        if (byteLength > maxBytes) {
          await reader.cancel();
          throw new RequestBodyError("Request body is too large.", 413);
        }
        chunks.push(value);
      }
    } finally {
      reader.releaseLock();
    }
  }

  if (byteLength === 0) throw new RequestBodyError("A JSON request body is required.", 400);
  const bytes = Buffer.concat(chunks.map((chunk) => Buffer.from(chunk)), byteLength);
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new RequestBodyError("Request body must be valid UTF-8.", 400);
  }
  try {
    return { value: JSON.parse(text), byteLength };
  } catch {
    throw new RequestBodyError("Request body must be valid JSON.", 400);
  }
}

async function readBeforeDeadline(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  deadlineAt: number
) {
  const remainingMs = deadlineAt - performance.now();
  if (remainingMs <= 0) {
    void reader.cancel("Request body deadline exceeded.").catch(() => undefined);
    throw new RequestBodyError("Request body took too long.", 408);
  }

  let timeout: ReturnType<typeof setTimeout> | undefined;
  try {
    const deadlineExceeded = Symbol("request-body-deadline");
    const result = await Promise.race([
      reader.read(),
      new Promise<typeof deadlineExceeded>((resolve) => {
        timeout = setTimeout(() => {
          resolve(deadlineExceeded);
        }, remainingMs);
      })
    ]);
    // Decide the race before cancellation. Cancelling inside the timer can make
    // the pending read resolve `{ done: true }` first and misreport a timeout as
    // malformed JSON.
    if (result === deadlineExceeded) {
      void reader.cancel("Request body deadline exceeded.").catch(() => undefined);
      throw new RequestBodyError("Request body took too long.", 408);
    }
    return result;
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}
