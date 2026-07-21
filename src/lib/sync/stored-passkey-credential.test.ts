import { generateKeyPairSync } from "node:crypto";
import { cose, decodeCredentialPublicKey, isoCBOR } from "@simplewebauthn/server/helpers";
import { describe, expect, it } from "vitest";
import { base64urlDecode, base64urlEncode } from "./base64url";
import {
  GUARDED_STORED_PASSKEY_CREDENTIAL_PROJECTION_SQL,
  PASSKEY_SUPPORTED_COSE_ALGORITHM_IDS,
  STORED_PASSKEY_CREDENTIAL_SAFETY_LATERAL_SQL,
  StoredPasskeyCredentialIntegrityError,
  validateGuardedStoredPasskeyCredentialRow,
  validatePasskeyCredentialId,
  validatePasskeyPublicKey
} from "./stored-passkey-credential";

const PUBLIC_KEY = Buffer.from(
  "a50102032620012158206b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2962258204fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
  "hex"
);
const INVALID_EC_POINT = Buffer.from(
  "a501020326200121582000000000000000000000000000000000000000000000000000000000000000002258200000000000000000000000000000000000000000000000000000000000000000",
  "hex"
);
const MISMATCHED_EC_ALGORITHM = Buffer.from(
  "a5010203382320012158206b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2962258204fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
  "hex"
);
const EC2_KEY_WITH_OKP_CURVE = Buffer.from(PUBLIC_KEY);
EC2_KEY_WITH_OKP_CURVE[6] = 0x06;
const EC2_KEY_WITH_EDDSA_ALGORITHM = Buffer.from(PUBLIC_KEY);
EC2_KEY_WITH_EDDSA_ALGORITHM[4] = 0x27;
const GENERATED_RSA_JWK = generateKeyPairSync("rsa", {
  modulusLength: 2_048,
  publicExponent: 0x10001
}).publicKey.export({ format: "jwk" });

function generatedRSAKey(algorithm = cose.COSEALG.RS256) {
  if (!GENERATED_RSA_JWK.n || !GENERATED_RSA_JWK.e) {
    throw new Error("Generated RSA key is missing its public parameters.");
  }
  return Buffer.from(isoCBOR.encode(new Map<number, number | Uint8Array>([
    [cose.COSEKEYS.kty, cose.COSEKTY.RSA],
    [cose.COSEKEYS.alg, algorithm],
    [cose.COSEKEYS.n, base64urlDecode(GENERATED_RSA_JWK.n)],
    [cose.COSEKEYS.e, base64urlDecode(GENERATED_RSA_JWK.e)]
  ])));
}

function zeroEd25519Key() {
  return Buffer.from(isoCBOR.encode(new Map<number, number | Uint8Array>([
    [cose.COSEKEYS.kty, cose.COSEKTY.OKP],
    [cose.COSEKEYS.alg, cose.COSEALG.EdDSA],
    [cose.COSEKEYS.crv, cose.COSECRV.ED25519],
    [cose.COSEKEYS.x, new Uint8Array(32)]
  ])));
}

function ec2KeyWithUnknownField() {
  const decoded = decodeCredentialPublicKey(PUBLIC_KEY) as unknown as Map<
    number,
    number | Uint8Array
  >;
  const fields = new Map(decoded);
  fields.set(99, new Uint8Array(3_000));
  return Buffer.from(isoCBOR.encode(fields));
}

function validRow() {
  return {
    id: base64urlEncode("credential-id"),
    user_id: "11111111-1111-4111-8111-111111111111",
    public_key_base64url: base64urlEncode(PUBLIC_KEY),
    counter: "8",
    created_at: new Date("2026-07-13T12:00:00Z"),
    updated_at: new Date("2026-07-13T12:00:00Z"),
    stored_row_valid: true
  };
}

describe("stored passkey credential integrity", () => {
  it("pins the application crypto policy to ES256 and RS256", () => {
    expect(PASSKEY_SUPPORTED_COSE_ALGORITHM_IDS).toEqual([
      cose.COSEALG.ES256,
      cose.COSEALG.RS256
    ]);
  });

  it("accepts one canonical bounded credential and parsed COSE key", () => {
    expect(validatePasskeyCredentialId(validRow().id)).toBe(validRow().id);
    expect(Buffer.from(validatePasskeyPublicKey(validRow().public_key_base64url)))
      .toEqual(PUBLIC_KEY);
    expect(validateGuardedStoredPasskeyCredentialRow(validRow())).toMatchObject({
      id: validRow().id,
      userId: validRow().user_id,
      counter: 8
    });
  });

  it("accepts a generated RSA-2048 RS256 COSE key", () => {
    const publicKey = generatedRSAKey();
    expect(Buffer.from(validatePasskeyPublicKey(base64urlEncode(publicKey))))
      .toEqual(publicKey);
  });

  it.each([
    ["RSA-PSS", cose.COSEALG.PS256],
    ["deprecated RSA-SHA1", cose.COSEALG.RS1]
  ])("rejects an excluded %s key", (_case, algorithm) => {
    expect(() => validatePasskeyPublicKey(base64urlEncode(generatedRSAKey(algorithm))))
      .toThrow(StoredPasskeyCredentialIntegrityError);
  });

  it.each([
    ["noncanonical ID", { id: "A" }],
    ["malformed public key encoding", { public_key_base64url: "!" }],
    ["non-COSE public key", { public_key_base64url: base64urlEncode("not-cbor") }],
    ["non-curve EC point", { public_key_base64url: base64urlEncode(INVALID_EC_POINT) }],
    ["algorithm-curve mismatch", {
      public_key_base64url: base64urlEncode(MISMATCHED_EC_ALGORITHM)
    }],
    ["EC2 key with an unusable OKP curve", {
      public_key_base64url: base64urlEncode(EC2_KEY_WITH_OKP_CURVE)
    }],
    ["EC2 key with an incompatible EdDSA algorithm", {
      public_key_base64url: base64urlEncode(EC2_KEY_WITH_EDDSA_ALGORITHM)
    }],
    ["low-order Ed25519 key", {
      public_key_base64url: base64urlEncode(zeroEd25519Key())
    }],
    ["COSE key with an oversized unknown field", {
      public_key_base64url: base64urlEncode(ec2KeyWithUnknownField())
    }],
    ["unsafe SQL sentinel", {
      stored_row_valid: false,
      id: null,
      public_key_base64url: null
    }],
    ["infinite timestamp", { updated_at: new Date(Number.POSITIVE_INFINITY) }],
    ["invalid counter", { counter: "4294967296" }]
  ])("rejects a %s", (_case, patch) => {
    expect(() => validateGuardedStoredPasskeyCredentialRow({ ...validRow(), ...patch }))
      .toThrow(StoredPasskeyCredentialIntegrityError);
  });

  it("guards every variable field before projecting it to Node", () => {
    expect(STORED_PASSKEY_CREDENTIAL_SAFETY_LATERAL_SQL)
      .toContain("pg_catalog.pg_column_compression(credential.id) IS NULL");
    expect(STORED_PASSKEY_CREDENTIAL_SAFETY_LATERAL_SQL)
      .toContain("pg_catalog.pg_column_size(credential.public_key_base64url)");
    expect(STORED_PASSKEY_CREDENTIAL_SAFETY_LATERAL_SQL)
      .toContain("pg_catalog.isfinite(credential.updated_at)");
    expect(GUARDED_STORED_PASSKEY_CREDENTIAL_PROJECTION_SQL)
      .toContain("WHEN credential_safety.stored_row_valid");
  });
});
