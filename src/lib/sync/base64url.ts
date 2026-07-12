export function base64urlEncode(input: Buffer | Uint8Array | string) {
  const buffer = typeof input === "string" ? Buffer.from(input, "utf8") : Buffer.from(input);
  return buffer
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

export function base64urlDecode(input: string) {
  if (!input || !/^[A-Za-z0-9_-]+$/.test(input)) {
    throw new Error("Invalid base64url value.");
  }
  const normalized = input.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  const decoded = Buffer.from(padded, "base64");
  // Node's base64 decoder is intentionally permissive. Reject alternate and
  // non-canonical encodings so signatures and encrypted metadata have exactly
  // one wire representation.
  if (base64urlEncode(decoded) !== input) {
    throw new Error("Invalid base64url value.");
  }
  return decoded;
}
