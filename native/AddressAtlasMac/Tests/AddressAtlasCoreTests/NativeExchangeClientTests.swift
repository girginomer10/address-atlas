import CryptoKit
import Foundation
import SQLite3
import XCTest

@testable import AddressAtlasCore

final class NativeExchangeClientTests: XCTestCase {
  func testBinanceScopeValidationUsesAuthoritativePinnedPermissionEndpoint() async throws {
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.url?.host, "api.binance.com")
      XCTAssertEqual(request.url?.path, "/sapi/v1/account/apiRestrictions")
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-MBX-APIKEY"), "key")
      XCTAssertTrue(request.url?.query?.contains("timestamp=1700000000000") == true)
      XCTAssertTrue(request.url?.query?.contains("signature=") == true)
      return (
        Data(
          #"{"enableReading":true,"ipRestrict":true,"enableWithdrawals":false,"enableSpotAndMarginTrading":false,"enableMargin":false,"enableFutures":false,"permitsUniversalTransfer":false}"#
            .utf8),
        httpResponse(for: request)
      )
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    let result = try await client.validateCredentialScope(
      provider: .binance,
      credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
    )

    XCTAssertEqual(result, .verifiedReadOnly)
  }

  func testBinanceScopeValidationRefusesEveryDangerousOrFutureCapability() async throws {
    let http = StubHTTPClient { request in
      return (
        Data(
          #"{"enableReading":true,"enableWithdrawals":true,"enableSpotAndMarginTrading":true,"enableFuturePower":true}"#
            .utf8),
        httpResponse(for: request)
      )
    }
    let client = NativeExchangeBalanceClient(http: http)

    do {
      _ = try await client.validateCredentialScope(
        provider: .binance,
        credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
      )
      XCTFail("Expected dangerous Binance key rejection")
    } catch ExchangeClientError.unsafeCredentialScope(let provider, let permissions) {
      XCTAssertEqual(provider, .binance)
      XCTAssertEqual(
        Set(permissions),
        ["enableWithdrawals", "enableSpotAndMarginTrading", "enableFuturePower"]
      )
    }
  }

  func testBinanceScopeValidationRequiresReadingPermission() async throws {
    let http = StubHTTPClient { request in
      (
        Data(#"{"enableReading":false,"enableWithdrawals":false}"#.utf8),
        httpResponse(for: request)
      )
    }
    let client = NativeExchangeBalanceClient(http: http)

    do {
      _ = try await client.validateCredentialScope(
        provider: .binance,
        credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
      )
      XCTFail("Expected missing read permission rejection")
    } catch {
      XCTAssertEqual(
        error as? ExchangeClientError,
        .missingReadPermission(provider: .binance)
      )
    }
  }

  func testProvidersWithoutAuthoritativeScopeAPIStayExplicitlyUnverified() async throws {
    let http = StubHTTPClient { _ in
      XCTFail("Manual scope validation must not send credential-bearing requests")
      throw URLError(.badServerResponse)
    }
    let client = NativeExchangeBalanceClient(http: http)

    for provider in [ExchangeProvider.coinbase, .kraken] {
      let result = try await client.validateCredentialScope(
        provider: provider,
        credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
      )
      guard case .manualVerificationRequired(let actualProvider, let guidance) = result else {
        return XCTFail("Expected explicit manual verification result")
      }
      XCTAssertEqual(actualProvider, provider)
      XCTAssertTrue(guidance.contains("could not be verified automatically"))
    }
  }

  func testBinanceClientSignsRequestAndParsesBalances() async throws {
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.url?.path, "/api/v3/account")
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-MBX-APIKEY"), "key")
      XCTAssertTrue(request.url?.query?.contains("timestamp=1700000000000") == true)
      XCTAssertTrue(request.url?.query?.contains("signature=") == true)
      let json = """
        {
          "balances": [
            { "asset": "BTC", "free": "0.25", "locked": "0.25" },
            { "asset": "EMPTY", "free": "0", "locked": "0" }
          ]
        }
        """
      return (Data(json.utf8), httpResponse(for: request))
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    let balance = try await client.fetchBalance(
      provider: .binance,
      credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
    )

    XCTAssertEqual(balance.total["BTC"], 0.5)
    XCTAssertEqual(balance.free["BTC"], 0.25)
    XCTAssertNil(balance.total["EMPTY"])
  }

  func testExchangeClientIgnoresRemoteEndpointConfigForSignedRequests() async throws {
    let config = NativeEndpointConfig(
      exchanges: [
        ExchangeProvider.binance.rawValue: ExchangeEndpointOverride(
          baseURL: URL(string: "https://binance.example")!,
          accountPath: "/api/v4/account"
        )
      ]
    )
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.url?.host, "api.binance.com")
      XCTAssertEqual(request.url?.path, "/api/v3/account")
      return (Data("{\"balances\":[]}".utf8), httpResponse(for: request))
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      endpointConfig: config,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    _ = try await client.fetchBalance(
      provider: .binance,
      credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
    )
  }

  func testExchangeClientReportsHTTPErrorBody() async throws {
    let http = StubHTTPClient { request in
      let json = """
        { "msg": "Invalid API-key, IP, or permissions for action." }
        """
      return (Data(json.utf8), httpResponse(for: request, statusCode: 401))
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    do {
      _ = try await client.fetchBalance(
        provider: .binance,
        credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
      )
      XCTFail("Expected exchange HTTP error.")
    } catch ExchangeClientError.httpError(let statusCode, let message) {
      XCTAssertEqual(statusCode, 401)
      XCTAssertEqual(message, "Invalid API-key, IP, or permissions for action.")
    }
  }

  func testExchangeClientRedactsAndCapsUntrustedErrorBody() async throws {
    let rawSecret = String(repeating: "s", count: 80)
    let http = StubHTTPClient { request in
      let data = try JSONSerialization.data(withJSONObject: [
        "message": "authorization: Bearer \(rawSecret)\n\(String(repeating: "x", count: 1_000))"
      ])
      return (data, httpResponse(for: request, statusCode: 401))
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    do {
      _ = try await client.fetchBalance(
        provider: .binance,
        credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
      )
      XCTFail("Expected exchange HTTP error.")
    } catch ExchangeClientError.httpError(_, let message) {
      XCTAssertFalse(message.contains(rawSecret))
      XCTAssertFalse(message.contains("\n"))
      XCTAssertTrue(message.contains("[redacted]"))
      XCTAssertLessThanOrEqual(
        message.unicodeScalars.count, ProviderErrorSanitizer.maximumScalarCount + 1)
    }
  }

  func testExchangeBalanceNormalizerUsesLiveStablecoinPricesAndExactUSD() async throws {
    // Every non-USD stablecoin must have a CoinGecko identity so the live
    // price can win; the $1.00 fallback below is only for missing prices.
    XCTAssertTrue(
      ExchangeBalanceNormalizer.usdStableSymbols.subtracting(["USD"]).allSatisfy {
        ExchangeBalanceNormalizer.coinGeckoIds[$0] != nil
      }
    )
    let id = UUID()
    let result = try await ExchangeBalanceNormalizer.normalizeWithWarnings(
      balance: ExchangeBalance(total: [
        "BUSD": 100, "DAI": 100, "FDUSD": 100, "TUSD": 100,
        "USD": 100, "USDC": 100, "USDP": 100, "USDT": 100, "XBT": 0.5,
      ]),
      id: id,
      provider: .kraken,
      label: "Kraken main",
      priceProvider: StaticPriceProvider(values: [
        "bitcoin": PricePoint(usd: 100_000, usd24hChange: 1.5),
        "binance-usd": PricePoint(usd: 0.96),
        "first-digital-usd": PricePoint(usd: 0.98),
        "pax-dollar": PricePoint(usd: 1.01),
        "usd-coin": PricePoint(usd: 0.97, usd24hChange: -3),
        "tether": PricePoint(usd: 1.02, usd24hChange: 2),
        "dai": PricePoint(usd: 0.99, usd24hChange: -1),
        "true-usd": PricePoint(usd: 0.95),
      ])
    )
    let holdings = result.holdings

    XCTAssertEqual(
      holdings.map(\.symbol),
      ["BTC", "BUSD", "DAI", "FDUSD", "TUSD", "USD", "USDC", "USDP", "USDT"]
    )
    XCTAssertEqual(holdings.first(where: { $0.symbol == "BTC" })?.valueUsd, 50_000)
    XCTAssertEqual(
      try XCTUnwrap(holdings.first(where: { $0.symbol == "BUSD" })?.valueUsd), 96,
      accuracy: 0.000_001)
    XCTAssertEqual(
      try XCTUnwrap(holdings.first(where: { $0.symbol == "DAI" })?.valueUsd), 99,
      accuracy: 0.000_001)
    XCTAssertEqual(
      try XCTUnwrap(holdings.first(where: { $0.symbol == "FDUSD" })?.valueUsd), 98,
      accuracy: 0.000_001)
    XCTAssertEqual(
      try XCTUnwrap(holdings.first(where: { $0.symbol == "TUSD" })?.valueUsd), 95,
      accuracy: 0.000_001)
    XCTAssertEqual(
      try XCTUnwrap(holdings.first(where: { $0.symbol == "USD" })?.priceUsd), 1, accuracy: 0.000_001
    )
    XCTAssertEqual(
      try XCTUnwrap(holdings.first(where: { $0.symbol == "USDC" })?.valueUsd), 97,
      accuracy: 0.000_001)
    XCTAssertEqual(
      try XCTUnwrap(holdings.first(where: { $0.symbol == "USDP" })?.valueUsd), 101,
      accuracy: 0.000_001)
    XCTAssertEqual(
      try XCTUnwrap(holdings.first(where: { $0.symbol == "USDT" })?.valueUsd), 102,
      accuracy: 0.000_001)
    XCTAssertEqual(holdings.first?.source, .exchange)
    XCTAssertTrue(result.warnings.isEmpty)
  }

  func testExchangeBalanceNormalizerFallsBackToOneDollarOnlyForMissingStablecoinPrices()
    async throws
  {
    // A live CoinGecko price always wins; the exact $1.00 fallback applies
    // only when the response omits a USD stablecoin. Non-stablecoins with a
    // missing price remain visibly unpriced at $0.
    let result = try await ExchangeBalanceNormalizer.normalizeWithWarnings(
      balance: ExchangeBalance(total: ["USDC": 42, "USDT": 10, "USD": 5, "BTC": 1]),
      id: UUID(),
      provider: .binance,
      label: "Binance main",
      priceProvider: StaticPriceProvider(values: ["tether": PricePoint(usd: 0.98)])
    )

    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "USDC" })?.priceUsd, 1)
    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "USDC" })?.valueUsd, 42)
    XCTAssertEqual(
      result.holdings.first(where: { $0.symbol == "USDC" })?.pricingStatus,
      .priced
    )
    XCTAssertEqual(
      try XCTUnwrap(result.holdings.first(where: { $0.symbol == "USDT" })?.valueUsd),
      9.8,
      accuracy: 0.000_001
    )
    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "USD" })?.valueUsd, 5)
    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "BTC" })?.priceUsd, 0)
    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "BTC" })?.valueUsd, 0)
    XCTAssertEqual(
      result.holdings.first(where: { $0.symbol == "BTC" })?.pricingStatus,
      .unpriced
    )
    XCTAssertTrue(
      result.warnings.contains(where: {
        $0.contains("USDC") && $0.contains("$1.00") && !$0.contains("BTC")
      }))
    XCTAssertTrue(
      result.warnings.contains(where: {
        $0.contains("BTC") && $0.contains("shown unpriced") && !$0.contains("USDC")
      }))
  }

  func testNativeExchangeScannerDecryptsCredentialsAndUpdatesConnection() async throws {
    let http = StubHTTPClient { request in
      if request.url?.path == "/sapi/v1/account/apiRestrictions" {
        return (
          Data(
            #"{"enableReading":true,"enableWithdrawals":false,"enableSpotAndMarginTrading":false}"#
              .utf8
          ),
          httpResponse(for: request)
        )
      }
      XCTAssertEqual(request.url?.path, "/api/v3/account")
      let json = """
        {
          "balances": [
            { "asset": "USDC", "free": "10", "locked": "0" }
          ]
        }
        """
      return (Data(json.utf8), httpResponse(for: request))
    }
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let connectionId = UUID()
    let credentials = try ExchangeCredentialVault(crypto: crypto).seal(
      ExchangeCredentials(apiKey: "key", secret: "secret"),
      vaultKey: vaultKey,
      connectionId: connectionId
    )
    let connection = ExchangeConnectionRecord(
      id: connectionId,
      provider: .binance,
      label: "Binance main",
      encryptedCredentials: credentials
    )
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(
        http: http, now: { Date(timeIntervalSince1970: 1_700_000_000) }),
      credentialVault: ExchangeCredentialVault(crypto: crypto),
      priceProvider: StaticPriceProvider(values: ["usd-coin": PricePoint(usd: 1)])
    )

    let result = try await scanner.scanThrowing(connections: [connection], vaultKey: vaultKey)

    XCTAssertEqual(result.holdings.first?.symbol, "USDC")
    XCTAssertEqual(result.holdings.first?.valueUsd, 10)
    XCTAssertEqual(result.connections.first?.status, .ok)
    XCTAssertEqual(result.connections.first?.credentialScopeAssurance, .verifiedReadOnly)
    XCTAssertNil(result.connections.first?.lastError)
    XCTAssertTrue(result.warnings.isEmpty)
  }

  func testBinanceScannerRevalidatesScopeAndClearsStaleAssuranceBeforeBalanceRequest()
    async throws
  {
    let requests = ScannerRequestLog()
    let http = StubHTTPClient { request in
      _ = requests.append(request)
      XCTAssertEqual(request.url?.path, "/sapi/v1/account/apiRestrictions")
      return (
        Data(
          #"{"enableReading":true,"enableWithdrawals":true,"enableSpotAndMarginTrading":false}"#
            .utf8
        ),
        httpResponse(for: request)
      )
    }
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let connectionId = UUID()
    let credentialVault = ExchangeCredentialVault(crypto: crypto)
    let connection = ExchangeConnectionRecord(
      id: connectionId,
      provider: .binance,
      label: "Previously verified Binance",
      encryptedCredentials: try credentialVault.seal(
        ExchangeCredentials(apiKey: "key", secret: "secret"),
        vaultKey: vaultKey,
        connectionId: connectionId
      ),
      credentialScopeAssurance: .verifiedReadOnly
    )
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(http: http),
      credentialVault: credentialVault,
      priceProvider: StaticPriceProvider(values: [:])
    )

    let result = try await scanner.scanThrowing(
      connections: [connection],
      vaultKey: vaultKey
    )

    XCTAssertEqual(requests.snapshot().map(\.url?.path), ["/sapi/v1/account/apiRestrictions"])
    XCTAssertTrue(result.holdings.isEmpty)
    XCTAssertEqual(result.connections.first?.status, .failed)
    XCTAssertNil(result.connections.first?.credentialScopeAssurance)
    XCTAssertTrue(result.connections.first?.lastError?.contains("dangerous permissions") == true)
  }

  func testLiveExchangeReadOnlySmokeWhenConfigured() async throws {
    let credentials = try liveExchangeCredentials()
    let client = NativeExchangeBalanceClient()

    for (provider, credential) in credentials {
      let balance = try await client.fetchBalance(provider: provider, credentials: credential)
      let entries = ExchangeBalanceNormalizer.balanceEntries(balance)
      XCTAssertTrue(
        entries.allSatisfy { _, amount in amount.isFinite && amount > 0 },
        "\(provider.label) returned non-finite balance entries."
      )
    }
  }

  func testLiveInvalidExchangeCredentialsFailCleanlyWhenConfigured() async throws {
    _ = try liveExchangeCredentials()
    let client = NativeExchangeBalanceClient()
    let invalidCredentials: [(ExchangeProvider, ExchangeCredentials)] = [
      (.binance, ExchangeCredentials(apiKey: "invalid", secret: "invalid")),
      (.coinbase, ExchangeCredentials(apiKey: "invalid", secret: "invalid", passphrase: "invalid")),
      (
        .kraken,
        ExchangeCredentials(apiKey: "invalid", secret: Data("invalid".utf8).base64EncodedString())
      ),
    ]

    for (provider, credentials) in invalidCredentials {
      do {
        _ = try await client.fetchBalance(provider: provider, credentials: credentials)
        XCTFail("Expected \(provider.label) invalid credentials to fail.")
      } catch {
        XCTAssertFalse(error.localizedDescription.isEmpty)
      }
    }
  }

  private func liveExchangeCredentials() throws -> [(ExchangeProvider, ExchangeCredentials)] {
    let environment = ProcessInfo.processInfo.environment
    guard environment["ADDRESS_ATLAS_LIVE_EXCHANGE_TESTS"] == "1" else {
      throw XCTSkip("Set ADDRESS_ATLAS_LIVE_EXCHANGE_TESTS=1 to run live exchange smoke tests.")
    }

    var missing: [String] = []
    func require(_ name: String) -> String {
      guard let value = environment[name], !value.isEmpty else {
        missing.append(name)
        return ""
      }
      return value
    }

    let binance = ExchangeCredentials(
      apiKey: require("ADDRESS_ATLAS_BINANCE_API_KEY"),
      secret: require("ADDRESS_ATLAS_BINANCE_SECRET")
    )
    let coinbase = ExchangeCredentials(
      apiKey: require("ADDRESS_ATLAS_COINBASE_API_KEY"),
      secret: require("ADDRESS_ATLAS_COINBASE_SECRET"),
      passphrase: environment["ADDRESS_ATLAS_COINBASE_PASSPHRASE"]
    )
    let kraken = ExchangeCredentials(
      apiKey: require("ADDRESS_ATLAS_KRAKEN_API_KEY"),
      secret: require("ADDRESS_ATLAS_KRAKEN_SECRET")
    )

    guard missing.isEmpty else {
      throw XCTSkip(
        "Missing live exchange smoke credentials: \(missing.sorted().joined(separator: ", ")).")
    }

    return [
      (.binance, binance),
      (.coinbase, coinbase),
      (.kraken, kraken),
    ]
  }
}
