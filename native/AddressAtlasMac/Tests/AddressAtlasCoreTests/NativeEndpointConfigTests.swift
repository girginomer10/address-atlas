import CryptoKit
import Foundation
import SQLite3
import XCTest

@testable import AddressAtlasCore

final class NativeEndpointConfigTests: XCTestCase {
  func testBundledEndpointConfigCoversExpandedEvmChains() {
    XCTAssertEqual(NativeEndpointConfig.bundled.configVersion, 5)
    XCTAssertEqual(
      NativeEndpointConfig.bundled.chains["ethereum"]?.rpcURL?.absoluteString,
      "https://ethereum-rpc.publicnode.com"
    )
    XCTAssertEqual(
      NativeEndpointConfig.bundled.chains["polygon"]?.rpcURL?.absoluteString,
      "https://polygon.drpc.org"
    )
    XCTAssertEqual(
      NativeEndpointConfig.bundled.chains["scroll"]?.rpcURL?.absoluteString,
      "https://rpc.scroll.io"
    )
    XCTAssertEqual(
      NativeEndpointConfig.bundled.chains["zksync-era"]?.rpcURL?.absoluteString,
      "https://mainnet.era.zksync.io"
    )
    XCTAssertNil(NativeEndpointConfig.bundled.chains["stargaze"])
  }

  func testEndpointConfigOverridesChainsButKeepsExchangeEndpointsFixed() throws {
    let config = NativeEndpointConfig(
      configVersion: 5,
      priceBaseURL: URL(string: "https://prices.example/simple/price")!,
      chains: [
        "ethereum": ChainEndpointOverride(
          rpcURL: URL(string: "https://ethereum-rpc.publicnode.com/rotated-rpc"))
      ],
      exchanges: [
        ExchangeProvider.binance.rawValue: ExchangeEndpointOverride(
          baseURL: URL(string: "https://binance.example")!,
          accountPath: "/api/v4/account"
        )
      ]
    )

    let chain = config.applying(to: ChainRegistry.evmChains.first { $0.id == "ethereum" }!)

    XCTAssertEqual(config.configVersion, 5)
    XCTAssertEqual(chain.rpcUrl?.absoluteString, "https://ethereum-rpc.publicnode.com/rotated-rpc")
    XCTAssertEqual(config.exchangeBaseURL(for: .binance)?.absoluteString, "https://api.binance.com")
    XCTAssertEqual(config.exchangeAccountPath(for: .binance), "/api/v3/account")
    XCTAssertEqual(
      config.exchangeBaseURL(for: .coinbase)?.absoluteString, "https://api.coinbase.com")
  }

  func testEndpointConfigClientFetchesNativeConfig() async throws {
    let expected = NativeEndpointConfig(
      configVersion: 5,
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      priceBaseURL: URL(string: "https://api.coingecko.com/api/v3/simple/price")!,
      chains: [
        "solana": ChainEndpointOverride(
          rpcURL: URL(string: "https://api.mainnet-beta.solana.com/rotated"))
      ],
      exchanges: [:]
    )
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.url?.path, "/config/native")
      return (try JSONEncoder.addressAtlas.encode(expected), httpResponse(for: request))
    }
    let client = NativeEndpointConfigClient(http: http)

    let config = try await client.fetch(from: URL(string: "https://sync.example")!)

    XCTAssertEqual(config, expected)
  }

  func testEndpointConfigClientDecodesServerShapedNativeConfigJSON() async throws {
    // Bundled configVersion is cross-pinned to the server's
    // BUNDLED_NATIVE_ENDPOINT_CONFIG_VERSION (src/lib/sync/native-config.ts:31).
    // Deploy ordering rule: the server value must be raised FIRST, because the
    // native client rejects any payload version below its own bundled version.
    XCTAssertEqual(NativeEndpointConfig.bundled.configVersion, 5)

    // Literal JSON mirroring the wire shape of getNativeEndpointConfig() in
    // src/lib/sync/native-config.ts (served by GET /config/native). Note the
    // server-side casing `priceBaseUrl` and the JS toISOString() timestamp
    // with fractional seconds.
    let json = """
      {
        "schemaVersion": 1,
        "configVersion": 5,
        "updatedAt": "2026-07-14T00:00:00.000Z",
        "refreshAfterSeconds": 21600,
        "minSupportedAppVersion": "0.2.0",
        "message": "Planned maintenance this weekend.",
        "priceBaseUrl": "https://api.coingecko.com/api/v3/simple/price",
        "chains": {
          "bitcoin": { "restUrl": "https://blockstream.info/api" },
          "solana": { "rpcUrl": "https://api.mainnet-beta.solana.com" },
          "tron": { "restUrl": "https://api.trongrid.io" },
          "xrp": { "rpcUrl": "https://s1.ripple.com:51234/" },
          "ethereum": { "rpcUrl": "https://ethereum-rpc.publicnode.com" },
          "base": { "rpcUrl": "https://mainnet.base.org" },
          "arbitrum": { "rpcUrl": "https://arb1.arbitrum.io/rpc" },
          "optimism": { "rpcUrl": "https://mainnet.optimism.io" },
          "polygon": { "rpcUrl": "https://polygon.drpc.org" },
          "bsc": { "rpcUrl": "https://bsc-dataseed.binance.org" },
          "avalanche": { "rpcUrl": "https://api.avax.network/ext/bc/C/rpc" },
          "gnosis": { "rpcUrl": "https://rpc.gnosischain.com" },
          "linea": { "rpcUrl": "https://rpc.linea.build" },
          "mantle": { "rpcUrl": "https://rpc.mantle.xyz" },
          "scroll": { "rpcUrl": "https://rpc.scroll.io" },
          "zksync-era": { "rpcUrl": "https://mainnet.era.zksync.io" },
          "cosmoshub": { "restUrl": "https://cosmos-api.polkachu.com" },
          "osmosis": { "restUrl": "https://lcd.osmosis.zone" },
          "celestia": { "restUrl": "https://celestia-api.polkachu.com" },
          "stride": { "restUrl": "https://stride-api.polkachu.com" }
        },
        "exchanges": {}
      }
      """
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.url?.path, "/config/native")
      return (Data(json.utf8), httpResponse(for: request))
    }
    let client = NativeEndpointConfigClient(http: http)

    let config = try await client.fetch(from: URL(string: "https://sync.example")!)

    XCTAssertEqual(config.schemaVersion, 1)
    XCTAssertEqual(config.configVersion, 5)
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    XCTAssertEqual(
      config.updatedAt,
      try XCTUnwrap(fractionalFormatter.date(from: "2026-07-14T00:00:00.000Z"))
    )
    XCTAssertEqual(config.refreshAfterSeconds, 21_600)
    XCTAssertEqual(config.minSupportedAppVersion, "0.2.0")
    XCTAssertEqual(config.message, "Planned maintenance this weekend.")
    XCTAssertEqual(
      config.priceBaseURL.absoluteString,
      "https://api.coingecko.com/api/v3/simple/price"
    )
    XCTAssertEqual(config.chains.count, 20)
    XCTAssertEqual(
      config.chains["bitcoin"]?.restURL?.absoluteString, "https://blockstream.info/api")
    XCTAssertEqual(
      config.chains["solana"]?.rpcURL?.absoluteString, "https://api.mainnet-beta.solana.com")
    XCTAssertEqual(config.chains["tron"]?.restURL?.absoluteString, "https://api.trongrid.io")
    XCTAssertEqual(config.chains["xrp"]?.rpcURL?.absoluteString, "https://s1.ripple.com:51234/")
    XCTAssertEqual(
      config.chains["ethereum"]?.rpcURL?.absoluteString, "https://ethereum-rpc.publicnode.com")
    XCTAssertEqual(config.chains["base"]?.rpcURL?.absoluteString, "https://mainnet.base.org")
    XCTAssertEqual(
      config.chains["arbitrum"]?.rpcURL?.absoluteString, "https://arb1.arbitrum.io/rpc")
    XCTAssertEqual(config.chains["optimism"]?.rpcURL?.absoluteString, "https://mainnet.optimism.io")
    XCTAssertEqual(config.chains["polygon"]?.rpcURL?.absoluteString, "https://polygon.drpc.org")
    XCTAssertEqual(config.chains["bsc"]?.rpcURL?.absoluteString, "https://bsc-dataseed.binance.org")
    XCTAssertEqual(
      config.chains["avalanche"]?.rpcURL?.absoluteString, "https://api.avax.network/ext/bc/C/rpc")
    XCTAssertEqual(config.chains["gnosis"]?.rpcURL?.absoluteString, "https://rpc.gnosischain.com")
    XCTAssertEqual(config.chains["linea"]?.rpcURL?.absoluteString, "https://rpc.linea.build")
    XCTAssertEqual(config.chains["mantle"]?.rpcURL?.absoluteString, "https://rpc.mantle.xyz")
    XCTAssertEqual(config.chains["scroll"]?.rpcURL?.absoluteString, "https://rpc.scroll.io")
    XCTAssertEqual(
      config.chains["zksync-era"]?.rpcURL?.absoluteString, "https://mainnet.era.zksync.io")
    XCTAssertEqual(
      config.chains["cosmoshub"]?.restURL?.absoluteString, "https://cosmos-api.polkachu.com")
    XCTAssertEqual(config.chains["osmosis"]?.restURL?.absoluteString, "https://lcd.osmosis.zone")
    XCTAssertEqual(
      config.chains["celestia"]?.restURL?.absoluteString, "https://celestia-api.polkachu.com")
    XCTAssertEqual(
      config.chains["stride"]?.restURL?.absoluteString, "https://stride-api.polkachu.com")
    XCTAssertTrue(config.exchanges.isEmpty)
  }

  func testEndpointConfigClientRejectsAStaleOrOutOfRangePayloadVersion() async throws {
    for version in [4, 2_000_000_001] {
      let response = NativeEndpointConfig(
        configVersion: version,
        priceBaseURL: NativeEndpointConfig.bundled.priceBaseURL,
        exchanges: [:]
      )
      let http = StubHTTPClient { request in
        (try JSONEncoder.addressAtlas.encode(response), httpResponse(for: request))
      }
      let client = NativeEndpointConfigClient(http: http)

      do {
        _ = try await client.fetch(from: URL(string: "https://sync.example")!)
        XCTFail("Expected config version \(version) to be rejected.")
      } catch let error as NativeEndpointConfigError {
        XCTAssertEqual(error, .invalidConfigVersion)
      }
    }
  }

  func testEndpointConfigClientRejectsIPLiteralAndNonOriginServersBeforeRequest() async throws {
    let rejectingHTTP = StubHTTPClient { _ in
      XCTFail("Passkey-incompatible or malformed servers must be rejected before any HTTP request.")
      throw URLError(.badURL)
    }
    let rejectingClient = NativeEndpointConfigClient(http: rejectingHTTP)
    for raw in [
      "https://sync.example:0",
      "https://sync.example:65536",
      "http://127.0.0.1:8787",
      "http://[::1]:8787",
      "https://127.0.0.1:8787",
      "https://[2001:db8::1]:8787",
      "http://[::1]:99999",
      "https://sync.example/prefix",
      "https://sync.example?tenant=other",
      "https://sync.example#fragment",
    ] {
      do {
        _ = try await rejectingClient.fetch(from: URL(string: raw)!)
        XCTFail("Expected incompatible server to be rejected: \(raw)")
      } catch let error as NativeEndpointConfigError {
        XCTAssertEqual(error, .invalidEndpoint("serverUrl"))
      }
    }
  }

  func testEndpointConfigRejectsUnsafeRefreshIntervals() {
    for seconds in [299, 86_401] {
      XCTAssertThrowsError(try NativeEndpointConfig(refreshAfterSeconds: seconds).validated()) {
        error in
        XCTAssertEqual(error as? NativeEndpointConfigError, .invalidRefreshInterval)
      }
    }
    XCTAssertNoThrow(try NativeEndpointConfig(refreshAfterSeconds: 300).validated())
    XCTAssertNoThrow(try NativeEndpointConfig(refreshAfterSeconds: 86_400).validated())
  }

  func testEndpointConfigUsesBoundedDottedAppVersions() {
    for version in ["0.2", "0.2.0", "2000000000.0.0.0"] {
      XCTAssertNoThrow(
        try NativeEndpointConfig(minSupportedAppVersion: version).validated(),
        "Expected valid version \(version)"
      )
    }

    for version in [
      "2000000001.0",
      "9223372036854775808.0",
      "999999999999999999999999999999.0",
      "1",
      "1..2",
      "1.2.3.4.5",
      " 1.2.3 ",
    ] {
      XCTAssertThrowsError(try NativeEndpointConfig(minSupportedAppVersion: version).validated()) {
        error in
        XCTAssertEqual(error as? NativeEndpointConfigError, .invalidMinimumAppVersion)
      }
    }
  }

  func testEndpointConfigClientRejectsUnsafeURLsAndPaths() async throws {
    let invalid = NativeEndpointConfig(
      configVersion: 5,
      priceBaseURL: URL(string: "file:///tmp/prices")!,
      exchanges: [
        ExchangeProvider.binance.rawValue: ExchangeEndpointOverride(
          baseURL: URL(string: "https://binance.example")!,
          accountPath: "https://bad.example/account"
        )
      ]
    )
    let http = StubHTTPClient { request in
      (try JSONEncoder.addressAtlas.encode(invalid), httpResponse(for: request))
    }
    let client = NativeEndpointConfigClient(http: http)

    do {
      _ = try await client.fetch(from: URL(string: "https://sync.example")!)
      XCTFail("Expected unsafe endpoint config to fail.")
    } catch NativeEndpointConfigError.invalidEndpoint(_) {
      // Expected.
    }
  }

  func testEndpointConfigClientRejectsRemoteExchangeOverrides() async throws {
    let invalid = NativeEndpointConfig(
      configVersion: 5,
      exchanges: [
        ExchangeProvider.binance.rawValue: ExchangeEndpointOverride(
          baseURL: URL(string: "https://api.binance.com")!,
          accountPath: "/api/v3/account"
        )
      ]
    )
    let http = StubHTTPClient { request in
      (try JSONEncoder.addressAtlas.encode(invalid), httpResponse(for: request))
    }
    let client = NativeEndpointConfigClient(http: http)

    do {
      _ = try await client.fetch(from: URL(string: "https://sync.example")!)
      XCTFail("Expected plain HTTP exchange endpoint config to fail.")
    } catch NativeEndpointConfigError.invalidEndpoint(let field) {
      XCTAssertEqual(field, "exchanges")
    }
  }
}
