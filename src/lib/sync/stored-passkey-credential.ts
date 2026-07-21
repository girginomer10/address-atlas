import { createPublicKey } from "node:crypto";
import { cose, decodeCredentialPublicKey } from "@simplewebauthn/server/helpers";
import { base64urlDecode, base64urlEncode } from "./base64url";
import { OperationalError } from "./diagnostics";

export const MAX_PASSKEY_CREDENTIAL_ID_BYTES = 1_023;
export const MAX_PASSKEY_PUBLIC_KEY_BYTES = 4_096;
export const PASSKEY_SUPPORTED_COSE_ALGORITHM_IDS = Object.freeze([
  cose.COSEALG.ES256,
  cose.COSEALG.RS256
]);
const PASSKEY_SUPPORTED_COSE_ALGORITHMS = new Set<number>(
  PASSKEY_SUPPORTED_COSE_ALGORITHM_IDS
);
const EC2_COSE_FIELDS = Object.freeze([
  cose.COSEKEYS.kty,
  cose.COSEKEYS.alg,
  cose.COSEKEYS.crv,
  cose.COSEKEYS.x,
  cose.COSEKEYS.y
]);
const RSA_COSE_FIELDS = Object.freeze([
  cose.COSEKEYS.kty,
  cose.COSEKEYS.alg,
  cose.COSEKEYS.n,
  cose.COSEKEYS.e
]);
export const MAX_PASSKEY_CREDENTIAL_ID_TEXT_LENGTH = Math.ceil(
  MAX_PASSKEY_CREDENTIAL_ID_BYTES * 4 / 3
);
const MAX_PUBLIC_KEY_TEXT_BYTES = Math.ceil(MAX_PASSKEY_PUBLIC_KEY_BYTES * 4 / 3);
const MAX_STORED_CREDENTIAL_ID_BYTES = MAX_PASSKEY_CREDENTIAL_ID_TEXT_LENGTH + 8;
const MAX_STORED_PUBLIC_KEY_BYTES = MAX_PUBLIC_KEY_TEXT_BYTES + 8;

export interface GuardedStoredPasskeyCredentialRow {
  id: unknown | null;
  user_id: unknown;
  public_key_base64url: unknown | null;
  counter: unknown;
  created_at: unknown | null;
  updated_at: unknown | null;
  stored_row_valid: boolean;
}

export class StoredPasskeyCredentialIntegrityError extends OperationalError {
  constructor() {
    super("passkey_credential_invalid", "Stored passkey credential is invalid.");
    this.name = "StoredPasskeyCredentialIntegrityError";
  }
}

/**
 * Reject oversized/compressed variable-width fields inside PostgreSQL before
 * node-postgres can detoast or allocate them. Keep the alias `credential`
 * stable in every caller; these fragments contain no request-derived SQL.
 */
export const STORED_PASSKEY_CREDENTIAL_SAFETY_LATERAL_SQL = `CROSS JOIN LATERAL (
         SELECT (CASE
           WHEN pg_catalog.pg_column_compression(credential.id) IS NULL
             AND pg_catalog.pg_column_size(credential.id)
               BETWEEN 1 AND ${MAX_STORED_CREDENTIAL_ID_BYTES}
             AND pg_catalog.pg_column_compression(credential.public_key_base64url) IS NULL
             AND pg_catalog.pg_column_size(credential.public_key_base64url)
               BETWEEN 1 AND ${MAX_STORED_PUBLIC_KEY_BYTES}
           THEN (
             pg_catalog.octet_length(credential.id)
               BETWEEN 1 AND ${MAX_PASSKEY_CREDENTIAL_ID_TEXT_LENGTH}
             AND pg_catalog.octet_length(credential.public_key_base64url)
               BETWEEN 1 AND ${MAX_PUBLIC_KEY_TEXT_BYTES}
             AND credential.counter BETWEEN 0 AND 4294967295
             AND pg_catalog.isfinite(credential.created_at)
             AND pg_catalog.isfinite(credential.updated_at)
           )
           ELSE false
         END) IS TRUE AS stored_row_valid
         OFFSET 0
       ) AS credential_safety`;

export const GUARDED_STORED_PASSKEY_CREDENTIAL_PROJECTION_SQL = `CASE
         WHEN credential_safety.stored_row_valid THEN credential.id ELSE NULL
       END AS id,
       credential.user_id,
       CASE
         WHEN credential_safety.stored_row_valid
           THEN credential.public_key_base64url
         ELSE NULL
       END AS public_key_base64url,
       credential.counter,
       CASE
         WHEN credential_safety.stored_row_valid THEN credential.created_at ELSE NULL
       END AS created_at,
       CASE
         WHEN credential_safety.stored_row_valid THEN credential.updated_at ELSE NULL
       END AS updated_at,
       credential_safety.stored_row_valid`;

export function validatePasskeyCredentialId(value: unknown) {
  if (typeof value !== "string" || value.length > MAX_PASSKEY_CREDENTIAL_ID_TEXT_LENGTH) {
    throw new StoredPasskeyCredentialIntegrityError();
  }
  let decoded: Buffer;
  try {
    decoded = base64urlDecode(value);
  } catch {
    throw new StoredPasskeyCredentialIntegrityError();
  }
  if (decoded.byteLength < 1 || decoded.byteLength > MAX_PASSKEY_CREDENTIAL_ID_BYTES) {
    throw new StoredPasskeyCredentialIntegrityError();
  }
  return value;
}

export function validatePasskeyPublicKey(value: unknown) {
  if (typeof value !== "string" || value.length > MAX_PUBLIC_KEY_TEXT_BYTES) {
    throw new StoredPasskeyCredentialIntegrityError();
  }
  let publicKey: Uint8Array<ArrayBuffer>;
  try {
    publicKey = Uint8Array.from(base64urlDecode(value));
    if (publicKey.byteLength < 1 || publicKey.byteLength > MAX_PASSKEY_PUBLIC_KEY_BYTES) {
      throw new Error("Passkey public key length is invalid.");
    }
    assertSupportedCOSEPublicKey(publicKey);
  } catch {
    throw new StoredPasskeyCredentialIntegrityError();
  }
  return publicKey;
}

export function validateGuardedStoredPasskeyCredentialRow(
  row: GuardedStoredPasskeyCredentialRow
) {
  if (row.stored_row_valid !== true
      || typeof row.user_id !== "string"
      || !validCounter(row.counter)
      || !finiteDate(row.created_at)
      || !finiteDate(row.updated_at)) {
    throw new StoredPasskeyCredentialIntegrityError();
  }
  const id = validatePasskeyCredentialId(row.id);
  const publicKey = validatePasskeyPublicKey(row.public_key_base64url);
  return {
    id,
    userId: row.user_id,
    publicKey,
    counter: Number(row.counter)
  };
}

function assertSupportedCOSEPublicKey(publicKey: Uint8Array<ArrayBuffer>) {
  const decoded = decodeCredentialPublicKey(publicKey);
  const fields = decoded as unknown as Map<number, unknown>;
  const algorithm = fields.get(cose.COSEKEYS.alg);
  if (typeof algorithm !== "number"
      || !PASSKEY_SUPPORTED_COSE_ALGORITHMS.has(algorithm)) {
    throw new Error("Unsupported COSE algorithm.");
  }

  if (cose.isCOSEPublicKeyEC2(decoded)) {
    const curve = fields.get(cose.COSEKEYS.crv);
    const x = fields.get(cose.COSEKEYS.x);
    const y = fields.get(cose.COSEKEYS.y);
    if (!hasExactFields(fields, EC2_COSE_FIELDS)
        || algorithm !== cose.COSEALG.ES256
        || curve !== cose.COSECRV.P256
        || !exactBytes(x, 32)
        || !exactBytes(y, 32)) {
      throw new Error("Invalid EC2 COSE key.");
    }
    assertImportablePublicKey({
      kty: "EC",
      crv: "P-256",
      x: base64urlEncode(x),
      y: base64urlEncode(y)
    }, "ec");
    return;
  }
  if (cose.isCOSEPublicKeyRSA(decoded)) {
    // RSA reuses COSE labels -1 and -2 as n/e; -3 is only EC2's y.
    const modulus = fields.get(cose.COSEKEYS.n);
    const exponentBytes = fields.get(cose.COSEKEYS.e);
    const exponent = exponentBytes instanceof Uint8Array
      ? unsignedBigInt(exponentBytes)
      : 0n;
    if (!hasExactFields(fields, RSA_COSE_FIELDS)
        || algorithm !== cose.COSEALG.RS256
        || !boundedBytes(modulus, 256, 512)
        || !boundedBytes(exponentBytes, 1, 4)
        || modulus[0] === 0
        || exponentBytes[0] === 0
        || exponent < 3n
        || exponent % 2n === 0n) {
      throw new Error("Invalid RSA COSE key.");
    }
    const key = assertImportablePublicKey({
      kty: "RSA",
      n: base64urlEncode(modulus),
      e: base64urlEncode(exponentBytes)
    }, "rsa");
    const modulusLength = key.asymmetricKeyDetails?.modulusLength;
    if (typeof modulusLength !== "number"
        || modulusLength < 2_048
        || modulusLength > 4_096) {
      throw new Error("Invalid RSA modulus length.");
    }
    return;
  }
  throw new Error("Unsupported COSE key type.");
}

function assertImportablePublicKey(
  jwk: Record<string, string>,
  expectedType: "ec" | "rsa"
) {
  const key = createPublicKey({ key: jwk, format: "jwk" });
  if (key.type !== "public" || key.asymmetricKeyType !== expectedType) {
    throw new Error("COSE public key type did not survive cryptographic import.");
  }
  return key;
}

function unsignedBigInt(value: Uint8Array) {
  let result = 0n;
  for (const byte of value) result = (result << 8n) | BigInt(byte);
  return result;
}

function exactBytes(value: unknown, length: number): value is Uint8Array {
  return value instanceof Uint8Array && value.byteLength === length;
}

function boundedBytes(
  value: unknown,
  minimumLength: number,
  maximumLength: number
): value is Uint8Array {
  return value instanceof Uint8Array
    && value.byteLength >= minimumLength
    && value.byteLength <= maximumLength;
}

function hasExactFields(fields: Map<number, unknown>, expected: readonly number[]) {
  return fields.size === expected.length && expected.every((field) => fields.has(field));
}

function validCounter(value: unknown) {
  if ((typeof value !== "string" && typeof value !== "number")
      || !/^\d+$/.test(String(value))) return false;
  const counter = BigInt(value);
  return counter >= 0n && counter <= 4_294_967_295n;
}

function finiteDate(value: unknown): value is Date {
  return value instanceof Date && Number.isFinite(value.getTime());
}
