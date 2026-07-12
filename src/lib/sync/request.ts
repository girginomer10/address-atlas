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

/** Read and parse JSON without trusting Content-Length or buffering past maxBytes. */
export async function readLimitedJSON(request: Request, maxBytes: number): Promise<ParsedJSONBody> {
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
    try {
      while (true) {
        const { done, value } = await reader.read();
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
