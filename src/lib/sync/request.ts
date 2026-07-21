import { performance } from "node:perf_hooks";

export class RequestBodyError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly byteLength = 0
  ) {
    super(message);
    this.name = "RequestBodyError";
  }
}

export interface ParsedJSONBody {
  value: unknown;
  byteLength: number;
}

export interface LimitedRequestBody {
  bytes: Buffer;
  byteLength: number;
}

export const REQUEST_BODY_DEADLINE_MS = 60_000;

/** Read and parse JSON without trusting Content-Length or buffering past maxBytes. */
export async function readLimitedJSON(
  request: Request,
  maxBytes: number,
  deadlineMs = REQUEST_BODY_DEADLINE_MS
): Promise<ParsedJSONBody> {
  assertJSONContentType(request);
  const body = await readLimitedBody(request, maxBytes, deadlineMs);
  return { value: parseLimitedJSON(body), byteLength: body.byteLength };
}

/**
 * Read a bounded request body before interpreting its media type or JSON. The
 * vault endpoint uses this split so authenticated ingress can be durably
 * charged even when content-type, UTF-8, JSON, or shape validation later fails.
 */
export async function readLimitedBody(
  request: Request,
  maxBytes: number,
  deadlineMs = REQUEST_BODY_DEADLINE_MS
): Promise<LimitedRequestBody> {
  if (!Number.isSafeInteger(deadlineMs) || deadlineMs < 1) {
    throw new Error("Request body deadline must be a positive integer.");
  }
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1) {
    throw new Error("Request body limit must be a positive integer.");
  }

  const declared = request.headers.get("content-length");
  let invalidDeclaredLength = false;
  let oversizedDeclaredLength = false;
  if (declared !== null) {
    const length = Number(declared);
    if (!Number.isSafeInteger(length) || length < 0) {
      // Read within the normal hard ceiling so an authenticated caller cannot
      // evade durable ingress accounting merely by supplying a malformed
      // length value. The route returns the header error after charging.
      invalidDeclaredLength = true;
    }
    if (!invalidDeclaredLength && length > maxBytes) {
      // Content-Length is caller-controlled. Keep reading under the normal
      // deadline and hard ceiling so durable ingress accounting reflects bytes
      // actually received instead of an arbitrarily large declaration.
      oversizedDeclaredLength = true;
    }
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
          await reader.cancel().catch(() => undefined);
          throw new RequestBodyError("Request body is too large.", 413, byteLength);
        }
        chunks.push(value);
      }
    } catch (error) {
      if (error instanceof RequestBodyError && error.byteLength === 0 && byteLength > 0) {
        throw new RequestBodyError(error.message, error.status, byteLength);
      }
      if (error instanceof RequestBodyError) throw error;
      // Treat an aborted/broken body stream as a bounded client request error
      // while preserving any bytes already received for durable accounting.
      throw new RequestBodyError("Request body could not be read.", 400, byteLength);
    } finally {
      reader.releaseLock();
    }
  }

  if (oversizedDeclaredLength) {
    throw new RequestBodyError("Request body is too large.", 413, byteLength);
  }
  if (byteLength === 0) throw new RequestBodyError("A JSON request body is required.", 400, 0);
  const result = {
    bytes: Buffer.concat(chunks.map((chunk) => Buffer.from(chunk)), byteLength),
    byteLength
  };
  if (invalidDeclaredLength) {
    throw new RequestBodyError("Invalid Content-Length.", 400, byteLength);
  }
  return result;
}

export function parseRequestJSON(request: Request, body: LimitedRequestBody) {
  assertJSONContentType(request, body.byteLength);
  return parseLimitedJSON(body);
}

function assertJSONContentType(request: Request, byteLength = 0) {
  const contentType = request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase();
  if (contentType !== "application/json") {
    throw new RequestBodyError("Content-Type must be application/json.", 415, byteLength);
  }
}

function parseLimitedJSON(body: LimitedRequestBody) {
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(body.bytes);
  } catch {
    throw new RequestBodyError("Request body must be valid UTF-8.", 400, body.byteLength);
  }
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new RequestBodyError("Request body must be valid JSON.", 400, body.byteLength);
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
