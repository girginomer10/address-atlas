import CryptoKit
import Foundation
import XCTest

@testable import AddressAtlasCore

final class ExchangeSigningKnownAnswerTests: XCTestCase {
  func testCoinbaseSignerBuildsVerifiableCDPJWT() throws {
    let key = try scannerPrivateKey()
    let keyName = "organizations/test/apiKeys/key-id"
    let signed = try ExchangeRequestSigner.coinbaseAccountsRequest(
      credentials: ExchangeCredentials(apiKey: keyName, secret: key.pemRepresentation),
      timestamp: 1_700_000_000,
      nonce: "nonce-1",
      query: "limit=250"
    )
    let authorization = try XCTUnwrap(signed.headers["Authorization"])
    let token = String(authorization.dropFirst("Bearer ".count))
    let parts = token.split(separator: ".").map(String.init)
    XCTAssertEqual(parts.count, 3)

    let header = try scannerJSONObject(Base64URL.decode(parts[0]))
    let payload = try scannerJSONObject(Base64URL.decode(parts[1]))
    XCTAssertEqual(header["alg"] as? String, "ES256")
    XCTAssertEqual(header["kid"] as? String, keyName)
    XCTAssertEqual(header["nonce"] as? String, "nonce-1")
    XCTAssertEqual(payload["iss"] as? String, "cdp")
    XCTAssertEqual(payload["sub"] as? String, keyName)
    XCTAssertEqual(payload["nbf"] as? NSNumber, 1_700_000_000)
    XCTAssertEqual(payload["exp"] as? NSNumber, 1_700_000_120)
    XCTAssertEqual(payload["uri"] as? String, "GET api.coinbase.com/api/v3/brokerage/accounts")

    let signature = try P256.Signing.ECDSASignature(rawRepresentation: Base64URL.decode(parts[2]))
    XCTAssertTrue(
      key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
  }

  func testBinanceSignatureMatchesIndependentKnownAnswer() {
    // Known-answer regression vector: HMAC-SHA256 over the exact query string
    // "timestamp=1700000000000" keyed with the UTF-8 secret bytes. The expected
    // hex digest was computed independently of CryptoKit with Python 3
    // (hmac/hashlib) and cross-checked with `openssl dgst -sha256 -hmac`.
    let signed = ExchangeRequestSigner.binanceAccountRequest(
      credentials: ExchangeCredentials(apiKey: "binance-test-key", secret: "binance-test-secret"),
      timestampMs: 1_700_000_000_000
    )

    XCTAssertEqual(signed.method, "GET")
    XCTAssertEqual(signed.path, "/api/v3/account")
    XCTAssertEqual(signed.headers["X-MBX-APIKEY"], "binance-test-key")
    XCTAssertEqual(
      signed.query,
      "timestamp=1700000000000&signature=57c21d08d72ee276b60f4f007be5b483d2e6ab3bb56bcaf5889cacf79bc90f78"
    )
  }

  func testKrakenSignatureMatchesIndependentKnownAnswer() throws {
    // Known-answer regression vector for Kraken's documented message layout:
    // HMAC-SHA512(base64-decoded secret, path + SHA256(nonce + postdata)) with
    // postdata "nonce=1700000000000000", emitted as standard Base64. The
    // Base64 secret decodes to the ASCII bytes of
    // "kraken-test-secret-0123456789abcdef". The expected signature was
    // computed independently of CryptoKit with Python 3 (hmac/hashlib) and
    // cross-checked with `openssl dgst -sha512 -hmac`.
    let signed = try ExchangeRequestSigner.krakenBalanceRequest(
      credentials: ExchangeCredentials(
        apiKey: "kraken-test-key",
        secret: "a3Jha2VuLXRlc3Qtc2VjcmV0LTAxMjM0NTY3ODlhYmNkZWY="
      ),
      nonce: "1700000000000000"
    )

    XCTAssertEqual(signed.method, "POST")
    XCTAssertEqual(signed.path, "/0/private/Balance")
    XCTAssertEqual(signed.body, "nonce=1700000000000000")
    XCTAssertEqual(signed.headers["API-Key"], "kraken-test-key")
    XCTAssertEqual(
      signed.headers["API-Sign"],
      "Jg5JyL2dUCUtmMCPmGfDs7Rdt5SfD7rvwpIUP7Zte6hiNeqAH2+zNfDJRUG+JdzLORjPsPTjuqVG+lwYODnASA=="
    )
  }

}
