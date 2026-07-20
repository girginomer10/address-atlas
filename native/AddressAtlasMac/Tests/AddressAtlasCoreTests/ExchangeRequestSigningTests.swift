import CryptoKit
import Foundation
import SQLite3
import XCTest

@testable import AddressAtlasCore

final class ExchangeRequestSigningTests: XCTestCase {
  func testBinanceSignerBuildsExpectedQueryAndHeader() {
    let signed = ExchangeRequestSigner.binanceAccountRequest(
      credentials: ExchangeCredentials(apiKey: "key", secret: "secret"),
      timestampMs: 1_700_000_000_000
    )

    XCTAssertEqual(signed.method, "GET")
    XCTAssertEqual(signed.path, "/api/v3/account")
    XCTAssertTrue(signed.query.contains("timestamp=1700000000000"))
    XCTAssertTrue(signed.query.contains("signature="))
    XCTAssertEqual(signed.headers["X-MBX-APIKEY"], "key")
  }

  func testKrakenSignerAcceptsStandardBase64SecretAndMatchesExpectedSignature() throws {
    // Kraken's published example secret contains '/', '+' and '=' characters,
    // so this also guards against accidentally using Base64URL decoding again.
    let signed = try ExchangeRequestSigner.krakenBalanceRequest(
      credentials: ExchangeCredentials(
        apiKey: "key",
        secret:
          "kQH5HW/8p1uGOVjbgWA7FunAmGO8lsSUXNsu3eow76sz84Q18fWxnyRzBHCd3pd5nE9qa99HAZtuZuj6F1huXg=="
      ),
      nonce: "1616492376594"
    )

    XCTAssertEqual(signed.body, "nonce=1616492376594")
    XCTAssertEqual(
      signed.headers["API-Sign"],
      "1nH4vwR+8FHiYh1QT649xXkGd3JR3x0DWkgv3u9Ed/Qqv6KPtgQpEU4m+Emb/VgpEji3j1XNwI+HCbfXxmrTOg=="
    )
  }

  func testAddressDetectionRejectsSeedLikeInput() {
    let phrase = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima"
    XCTAssertFalse(AddressDetection.isSafePublicAddress(phrase))
  }

  func testAddressDetectionPrefersSpecificBase58ChainsBeforeSolana() {
    XCTAssertEqual(
      AddressDetection.detectChains(for: "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7").map(\.id),
      ["tron"]
    )
    XCTAssertEqual(
      AddressDetection.detectChains(for: "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn").map(\.id),
      ["xrp"]
    )
  }
}
