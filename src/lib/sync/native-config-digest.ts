import { createHash } from "node:crypto";
import type { NativeEndpointConfig } from "./native-config";

export function nativeConfigDigest(config: NativeEndpointConfig) {
  const canonical = JSON.stringify(canonicalize(config));
  return createHash("sha256").update(canonical, "utf8").digest("hex");
}

function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (!isPlainRecord(value)) return value;
  return Object.fromEntries(
    Object.keys(value).sort().map((key) => [key, canonicalize(value[key])])
  );
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}
