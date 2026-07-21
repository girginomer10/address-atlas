import { describe, expect, it } from "vitest";
import { base64urlEncode } from "./base64url";
import {
  type AuthenticationCryptoInput,
  verifyAuthenticationCryptographically
} from "./passkeys";

const RP_ID = "example.com";
const EXPECTED_ORIGIN = "https://example.com";
const CHALLENGE = base64urlEncode(Buffer.alloc(32, 3));
const CREDENTIAL_ID = base64urlEncode("deterministic-credential");

// Fixed ES256 fixture generated from the public SEC 2 P-256 generator point
// with private scalar 1. This is public test material only; fixed client,
// authenticator, and signature bytes keep the production verifier boundary
// deterministic without an external authenticator or a mocked library call.
const COSE_PUBLIC_KEY = Buffer.from(
  "a50102032620012158206b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2962258204fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
  "hex"
);
const CLIENT_DATA_JSON =
  "eyJ0eXBlIjoid2ViYXV0aG4uZ2V0IiwiY2hhbGxlbmdlIjoiQXdNREF3TURBd01EQXdNREF3TURBd01EQXdNREF3TURBd01EQXdNREF3TSIsIm9yaWdpbiI6Imh0dHBzOi8vZXhhbXBsZS5jb20iLCJjcm9zc09yaWdpbiI6ZmFsc2V9";
const AUTHENTICATOR_DATA =
  "o3mm9u6vuaVeN4wRgDTidR5oL6ufLTCrE9ISVYbOGUcFAAAAAQ";
const SIGNATURE =
  "MEUCIHCADSqlVDUBFeMLmDYCeJwZsywE_QilhuM8AFT4t9gDAiEAysU3NEtts4FY1tTY04hw1d-mhtjPFmCTxiM9cSJDvAo";

describe("real SimpleWebAuthn authentication boundary", () => {
  it("verifies a deterministic UV assertion and enforces the configured RP binding", async () => {
    const input = signedAuthenticationInput();

    await expect(verifyAuthenticationCryptographically(input)).resolves.toMatchObject({
      verified: true,
      authenticationInfo: {
        credentialID: CREDENTIAL_ID,
        newCounter: 1,
        userVerified: true,
        origin: EXPECTED_ORIGIN,
        rpID: RP_ID
      }
    });

    await expect(verifyAuthenticationCryptographically({
      ...input,
      expectedOrigin: "https://attacker.example"
    })).rejects.toThrow();

    await expect(verifyAuthenticationCryptographically({
      ...input,
      expectedRPID: "attacker.example"
    })).rejects.toThrow();
  });
});

function signedAuthenticationInput(): AuthenticationCryptoInput {
  return {
    expectedChallenge: CHALLENGE,
    expectedOrigin: EXPECTED_ORIGIN,
    expectedRPID: RP_ID,
    credential: {
      id: CREDENTIAL_ID,
      publicKey: COSE_PUBLIC_KEY,
      counter: 0
    },
    response: {
      id: CREDENTIAL_ID,
      rawId: CREDENTIAL_ID,
      type: "public-key",
      authenticatorAttachment: "platform",
      clientExtensionResults: {},
      response: {
        clientDataJSON: CLIENT_DATA_JSON,
        authenticatorData: AUTHENTICATOR_DATA,
        signature: SIGNATURE
      }
    }
  };
}
