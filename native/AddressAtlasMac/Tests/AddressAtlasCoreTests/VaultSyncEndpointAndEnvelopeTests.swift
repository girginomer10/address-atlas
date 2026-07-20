import CryptoKit
import Foundation
import XCTest

@testable import AddressAtlasCore

final class VaultSyncEndpointAndEnvelopeTests: XCTestCase {
  func testSyncServerURLCanonicalizesOriginsAndRejectsEndpointComponents() {
    XCTAssertEqual(
      SyncServerURL.validatedOrigin(" HTTPS://Sync.Example.COM:443/ ")?.absoluteString,
      "https://sync.example.com"
    )
    XCTAssertEqual(
      SyncServerURL.validatedOrigin("http://localhost:80/")?.absoluteString,
      "http://localhost"
    )
    XCTAssertEqual(
      SyncServerURL.validatedOrigin("http://localhost:8787/")?.absoluteString,
      "http://localhost:8787"
    )
    XCTAssertEqual(
      SyncServerURL.validatedOrigin("https://sync.example.com:8443/")?.absoluteString,
      "https://sync.example.com:8443"
    )
    XCTAssertEqual(
      SyncServerURL.validatedOrigin("https://localhost:8443/")?.absoluteString,
      "https://localhost:8443"
    )
    for invalid in [
      "https:",
      "https:///vault",
      "https://user:secret@sync.example.com",
      "https://sync.example.com/path",
      "https://sync.example.com?query=1",
      "https://sync.example.com#fragment",
      "http://sync.example.com",
      "https://sync.example.com:0",
      "https://sync.example.com:65536",
      "http://127.0.0.1",
      "http://127.0.0.1:8787",
      "http://[::1]",
      "http://[::1]:8787",
      "http://[::1]:99999",
      "https://127.0.0.1",
      "https://127.1:8443",
      "https://0x7f000001:8443",
      "https://[::1]",
      "https://[2001:db8::1]:8443",
      "https://intranet",
      "https://sync.example.com.",
      "https://bad_label.example.com",
      "https://-sync.example.com",
      "https://sync-.example.com",
    ] {
      XCTAssertNil(SyncServerURL.validatedOrigin(invalid), invalid)
    }
  }

  func testRemoteConfigCannotRedirectExchangeSignedRequests() throws {
    let malicious = NativeEndpointConfig(
      exchanges: [
        ExchangeProvider.kraken.rawValue: ExchangeEndpointOverride(
          baseURL: URL(string: "https://attacker.example")!,
          accountPath: "/0/private/CancelAll"
        )
      ]
    )

    XCTAssertThrowsError(try malicious.validated()) { error in
      XCTAssertEqual(error as? NativeEndpointConfigError, .invalidEndpoint("exchanges"))
    }
    XCTAssertEqual(
      malicious.exchangeBaseURL(for: .kraken)?.absoluteString, "https://api.kraken.com")
    XCTAssertEqual(malicious.exchangeAccountPath(for: .kraken), "/0/private/Balance")
  }

  func testRemoteEndpointConfigIsPinnedToBundledOrigins() throws {
    XCTAssertNoThrow(
      try NativeEndpointConfig(
        priceBaseURL: URL(string: "https://api.coingecko.com/api/v3/simple/price")!,
        chains: [
          "ethereum": ChainEndpointOverride(
            rpcURL: URL(string: "https://ethereum-rpc.publicnode.com/alternate-path"))
        ]
      ).validated()
    )
    XCTAssertThrowsError(
      try NativeEndpointConfig(priceBaseURL: URL(string: "http://prices.example/price")!)
        .validated()
    )
    XCTAssertThrowsError(
      try NativeEndpointConfig(priceBaseURL: URL(string: "http://127.0.0.1:8080/price")!)
        .validated()
    )
    XCTAssertThrowsError(
      try NativeEndpointConfig(
        priceBaseURL: URL(string: "https://api.coingecko.com/api/v3/coins/list")!
      ).validated()
    )
    XCTAssertThrowsError(
      try NativeEndpointConfig(
        chains: [
          "ethereum": ChainEndpointOverride(rpcURL: URL(string: "https://attacker.example/rpc"))
        ]
      ).validated()
    )
    XCTAssertThrowsError(
      try NativeEndpointConfig(
        chains: ["ethereum": ChainEndpointOverride(rpcURL: URL(string: "http://127.0.0.1:8545"))]
      ).validated()
    )
  }

  func testEnvelopeRejectsWrongNonceLengthAndNonCanonicalBase64URL() throws {
    let crypto = VaultCrypto()
    let key = try crypto.deriveKey(from: try crypto.generateVaultKey(), purpose: .localDatabase)
    var envelope = try crypto.seal(Data("vault".utf8), with: key, keyId: "local-db")
    envelope.nonce = Base64URL.encode(Data(repeating: 0, count: 11))

    XCTAssertThrowsError(try crypto.open(envelope, with: key)) { error in
      XCTAssertEqual(error as? VaultCryptoError, .invalidEnvelope)
    }
    XCTAssertThrowsError(try Base64URL.decode("AA==")) { error in
      XCTAssertEqual(error as? VaultCryptoError, .invalidBase64)
    }
  }
}
