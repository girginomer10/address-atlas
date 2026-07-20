import CryptoKit
import Foundation
import XCTest
@testable import AddressAtlasCore

final class ScannerAddressValidationTests: XCTestCase {
  func testEvmMixedCaseAddressesRequireAValidEIP55Checksum() {
    let officialValid = [
      "0x52908400098527886E0F7030069857D2E4169EE7",
      "0x8617E340B3D01FA5F11F306F4090FD50E238070D",
      "0xde709f2102306220921060314715629080e2fb77",
      "0x27b1fdb04752bbc536007a920d24acb045561c26",
      "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
      "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
      "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
      "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb"
    ]
    for address in officialValid {
      XCTAssertFalse(AddressDetection.detectChains(for: address).isEmpty, address)
    }

    for valid in officialValid where valid.dropFirst(2).contains(where: { $0.isLowercase })
      && valid.dropFirst(2).contains(where: { $0.isUppercase }) {
      var characters = Array(valid)
      let index = characters[2...].firstIndex(where: { $0.isLetter })!
      characters[index] = characters[index].isUppercase
        ? Character(characters[index].lowercased())
        : Character(characters[index].uppercased())
      let invalid = String(characters)
      XCTAssertTrue(AddressDetection.detectChains(for: invalid).isEmpty, invalid)
    }
  }

  func testCosmosValidationAcceptsLegacyAnd32ByteAccountAddresses() {
    let modern = "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"

    XCTAssertEqual(AddressDetection.detectChains(for: modern).map(\.id), ["cosmoshub"])
    XCTAssertEqual(AddressDetection.canonicalAddress(modern, family: .cosmos), modern)
  }

  func testRetiredStargazeRemainsCanonicalForPersistedRecordsButIsNotScannable() {
    let address = "stars1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqspal9j"

    XCTAssertEqual(AddressDetection.retiredCosmosNetworkName(for: address), "Stargaze")
    XCTAssertEqual(AddressDetection.canonicalAddress(address, family: .cosmos), address)
    XCTAssertTrue(AddressDetection.detectChains(for: address).isEmpty)
    XCTAssertFalse(ChainRegistry.allChains.contains(where: { $0.id == "stargaze" }))
  }

  func testRegistryUsesCurrentPolygonRPCAndOptimismUSDTContract() {
    XCTAssertEqual(
      ChainRegistry.evmChains.first(where: { $0.id == "polygon" })?.rpcUrl?.absoluteString,
      "https://polygon.drpc.org"
    )
    XCTAssertEqual(
      ChainRegistry.commonErc20Tokens["optimism"]?.first(where: { $0.symbol == "USDT" })?.address,
      "0x94b008aA00579c1307B0EF2c499aD98a8ce58e58"
    )
  }

  func testChainSpecificValidationDoesNotMisclassifySolanaAsBitcoin() {
    XCTAssertEqual(
      AddressDetection.detectChains(for: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT").map(\.family),
      [.bitcoin]
    )
    XCTAssertEqual(
      AddressDetection.detectChains(for: "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh").map(\.family),
      [.bitcoin]
    )
    XCTAssertEqual(
      AddressDetection.detectChains(for: "11111111111111111111111111111111").map(\.family),
      [.solana]
    )
    XCTAssertTrue(AddressDetection.detectChains(for: "1BoatSLRHtKNngkdXEeobR76b53LETtpyU").isEmpty)
    XCTAssertTrue(AddressDetection.detectChains(for: String(repeating: "2", count: 10_000)).isEmpty)
  }

  func testCustomTokenCanonicalizationAndScannerBoundaryValidation() {
    let valid = CustomTokenRecord(
      chainKind: .evm,
      chainId: "ethereum",
      address: " 0x0000000000000000000000000000000000000001 ",
      symbol: " TEST ",
      name: " Test Token ",
      decimals: 18,
      coinGeckoId: " Test-Token ",
      priceUsd: 2
    )
    let invalidAddress = CustomTokenRecord(
      chainKind: .evm,
      chainId: "ethereum",
      address: "not-a-contract",
      symbol: "BADADDR",
      name: "Bad Address",
      decimals: 18
    )
    let invalidDecimals = CustomTokenRecord(
      chainKind: .evm,
      chainId: "ethereum",
      address: "0x0000000000000000000000000000000000000002",
      symbol: "BADDEC",
      name: "Bad Decimals",
      decimals: 37
    )
    let invalidPrice = CustomTokenRecord(
      chainKind: .evm,
      chainId: "ethereum",
      address: "0x0000000000000000000000000000000000000003",
      symbol: "BADPRICE",
      name: "Bad Price",
      decimals: 18,
      priceUsd: .infinity
    )
    let invalidCoinGeckoId = CustomTokenRecord(
      chainKind: .evm,
      chainId: "ethereum",
      address: "0x0000000000000000000000000000000000000004",
      symbol: "BADID",
      name: "Bad CoinGecko ID",
      decimals: 18,
      coinGeckoId: "tökén"
    )
    let mismatchedChain = CustomTokenRecord(
      chainKind: .solana,
      chainId: "ethereum",
      address: "11111111111111111111111111111111",
      symbol: "BADCHAIN",
      name: "Bad Chain",
      decimals: 9
    )

    let registries = NativeScanner.tokenRegistries(
      customTokens: [valid, invalidAddress, invalidDecimals, invalidPrice, invalidCoinGeckoId, mismatchedChain]
    )
    let added = registries.evm["ethereum"]?.first(where: { $0.symbol == "TEST" })
    let legacyInvalidID = registries.evm["ethereum"]?.first(where: { $0.symbol == "BADID" })

    XCTAssertEqual(added?.address, "0x0000000000000000000000000000000000000001")
    XCTAssertEqual(added?.coinGeckoId, "test-token")
    XCTAssertEqual(legacyInvalidID?.address, "0x0000000000000000000000000000000000000004")
    XCTAssertNil(legacyInvalidID?.coinGeckoId)
    XCTAssertFalse(registries.evm["ethereum"]?.contains(where: {
      ["BADADDR", "BADDEC", "BADPRICE", "BADCHAIN"].contains($0.symbol)
    }) ?? true)
    XCTAssertEqual(registries.warnings.count, 5)
    XCTAssertTrue(registries.warnings.contains(where: {
      $0.contains("BADID") && $0.contains("CoinGecko pricing was disabled")
    }))
    XCTAssertTrue(AddressDetection.isValidCustomTokenAddress(valid.address, family: .evm))
    XCTAssertEqual(AddressDetection.canonicalAddress(valid.address, family: .evm), added?.address)
  }

  func testRegistryUsesPOLAndDoesNotMislabelSolanaSoBTC() throws {
    let polygon = try XCTUnwrap(ChainRegistry.evmChains.first(where: { $0.id == "polygon" }))
    XCTAssertEqual(polygon.symbol, "POL")
    XCTAssertEqual(polygon.coinGeckoId, "polygon-ecosystem-token")
    XCTAssertEqual(ExchangeBalanceNormalizer.coinGeckoIds["MATIC"], "polygon-ecosystem-token")
    XCTAssertFalse(ChainRegistry.commonSplTokens["solana"]?.contains(where: {
      $0.address == "9n4nbM75f5Ui33ZbPYXn59EwSgE8CGsHtAeTH5YFeJ9E" || $0.symbol == "WBTC"
    }) ?? true)
  }

  func testExplorerURLBuilderSupportsFragmentAndPathBasedExplorers() {
    let tronAddress = "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
    let bitcoinAddress = "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"

    XCTAssertEqual(
      ChainRegistry.tron.explorerURL(for: tronAddress).absoluteString,
      "https://tronscan.org/#/address/\(tronAddress)"
    )
    XCTAssertEqual(
      ChainRegistry.bitcoin.explorerURL(for: bitcoinAddress).absoluteString,
      "https://blockstream.info/address/\(bitcoinAddress)"
    )
  }

  func testAddressParsingReportsTruncation() {
    let input = (1...3)
      .map { String(format: "0x%040llx", UInt64($0)) }
      .joined(separator: " ")

    let parsed = AddressDetection.parseWithMetadata(input, maxCount: 2)

    XCTAssertEqual(parsed.addresses.count, 2)
    XCTAssertTrue(parsed.wasTruncated)
  }

  func testExistingVaultCustomTokensAreCappedAtOneHundred() {
    let tokens = (0..<101).map { index in
      CustomTokenRecord(
        chainKind: .evm,
        chainId: "ethereum",
        address: String(format: "0x%040llx", UInt64(index + 1_000)),
        symbol: "CAP\(index)",
        name: "Capped Token \(index)",
        decimals: 18
      )
    }

    let registries = NativeScanner.tokenRegistries(customTokens: tokens)
    let customSymbols = registries.evm["ethereum"]?.filter { $0.symbol.hasPrefix("CAP") }.map(\.symbol) ?? []

    XCTAssertEqual(customSymbols.count, 100)
    XCTAssertFalse(customSymbols.contains("CAP100"))
    XCTAssertTrue(registries.warnings.contains(where: { $0.contains("first 100") }))
  }
}

final class ScannerFiatRateTests: XCTestCase {
  func testUSDT0UsesItsOwnCoinGeckoIdentityAndLiveStablecoinPrice() async throws {
    XCTAssertTrue(ExchangeBalanceNormalizer.usdStableSymbols.contains("USDT0"))
    XCTAssertEqual(ExchangeBalanceNormalizer.coinGeckoIds["USDT0"], "usdt0")

    let result = try await ExchangeBalanceNormalizer.normalizeWithWarnings(
      balance: ExchangeBalance(total: ["USDT0": 250]),
      id: UUID(),
      provider: .coinbase,
      label: "USDT0 account",
      priceProvider: ScannerStaticPriceProvider(
        values: ["usdt0": PricePoint(usd: 0.997, usd24hChange: -0.1)]
      )
    )

    let holding = try XCTUnwrap(result.holdings.first)
    XCTAssertEqual(holding.symbol, "USDT0")
    XCTAssertEqual(holding.priceUsd, 0.997, accuracy: 0.000_001)
    XCTAssertEqual(holding.valueUsd, 249.25, accuracy: 0.000_001)
    XCTAssertFalse(result.warnings.contains { $0.contains("No USD price") })

    // Without a live price the stablecoin falls back to exactly $1.00 instead
    // of rendering the balance as $0.
    let fallback = try await ExchangeBalanceNormalizer.normalizeWithWarnings(
      balance: ExchangeBalance(total: ["USDT0": 250]),
      id: UUID(),
      provider: .coinbase,
      label: "USDT0 account",
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )
    let fallbackHolding = try XCTUnwrap(fallback.holdings.first)
    XCTAssertEqual(fallbackHolding.priceUsd, 1)
    XCTAssertEqual(fallbackHolding.valueUsd, 250)
    XCTAssertTrue(fallback.warnings.contains { $0.contains("USDT0") && $0.contains("$1.00") })
  }

  func testPriceSanitizationDropsNonFiniteChangeWithoutDiscardingPrice() throws {
    let sanitized = try XCTUnwrap(
      CoinGeckoPriceClient.sanitized(PricePoint(usd: 42, usd24hChange: .infinity))
    )

    XCTAssertEqual(sanitized.usd, 42)
    XCTAssertNil(sanitized.usd24hChange)
    XCTAssertNil(CoinGeckoPriceClient.sanitized(PricePoint(usd: .infinity, usd24hChange: 1)))
  }

  func testExchangeAdditionAndValuationOverflowFailClosedWithoutNonFinitePersistence() async throws {
    let aliasOverflow = try await ExchangeBalanceNormalizer.normalizeWithWarnings(
      balance: ExchangeBalance(total: ["BTC": 1e308, "XXBT": 1e308]),
      id: UUID(),
      provider: .kraken,
      label: "Overflow aliases",
      priceProvider: ScannerStaticPriceProvider(values: ["bitcoin": PricePoint(usd: 1)])
    )

    XCTAssertTrue(aliasOverflow.holdings.isEmpty)
    XCTAssertTrue(aliasOverflow.warnings.contains { $0.contains("supported numeric range") })
    XCTAssertNil(FiniteValueMath.addingNonnegative(1e308, 1e308))
    XCTAssertNil(FiniteValueMath.sumNonnegative([1e308, 1e308]))

    let valuationOverflow = try await ExchangeBalanceNormalizer.normalizeWithWarnings(
      balance: ExchangeBalance(total: ["BTC": 1e308]),
      id: UUID(),
      provider: .coinbase,
      label: "Overflow valuation",
      priceProvider: ScannerStaticPriceProvider(
        values: ["bitcoin": PricePoint(usd: 1e308, usd24hChange: .infinity)]
      )
    )
    let holding = try XCTUnwrap(valuationOverflow.holdings.first)

    XCTAssertEqual(holding.amount, 1e308)
    XCTAssertEqual(holding.priceUsd, 1e308)
    XCTAssertEqual(holding.valueUsd, 0)
    XCTAssertNil(holding.change24h)
    XCTAssertTrue(holding.valueUsd.isFinite)
    XCTAssertTrue(valuationOverflow.warnings.contains { $0.contains("USD valuation exceeded") })
    XCTAssertNoThrow(try JSONEncoder.addressAtlas.encode(
      ScanRunRecord(
        totalUsd: 0,
        inputCount: 1,
        holdings: valuationOverflow.holdings,
        warnings: valuationOverflow.warnings
      )
    ))
  }

  func testCoinGeckoBTCRelativeRatesConvertToUSDPerFiatUnit() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      return scannerResponse(
        request,
        #"{"rates":{"usd":{"value":100000,"type":"fiat"},"eur":{"value":90000,"type":"fiat"},"gbp":{"value":80000,"type":"fiat"}}}"#
      )
    }
    let client = CoinGeckoPriceClient(http: JSONHTTPClient(http: http))

    let rates = try await client.usdRates(forFiatSymbols: ["EUR", "GBP"])

    XCTAssertEqual(try XCTUnwrap(rates["EUR"]), 100_000.0 / 90_000.0, accuracy: 0.000_000_1)
    XCTAssertEqual(try XCTUnwrap(rates["GBP"]), 1.25, accuracy: 0.000_000_1)
    XCTAssertEqual(requests.snapshot().first?.url?.path, "/api/v3/exchange_rates")
    XCTAssertEqual(requests.snapshot().first?.url?.host, "api.coingecko.com")
  }

  func testStaticFiatRatesValueEURAndGBPBalances() async throws {
    let result = try await ExchangeBalanceNormalizer.normalizeWithWarnings(
      balance: ExchangeBalance(total: ["ZEUR": 90, "ZGBP": 80]),
      id: UUID(),
      provider: .kraken,
      label: "Kraken",
      priceProvider: StaticPriceProvider(
        values: [:],
        fiatUsdRates: ["EUR": 100.0 / 90.0, "GBP": 1.25]
      )
    )
    let eur = try XCTUnwrap(result.holdings.first(where: { $0.symbol == "EUR" }))
    let gbp = try XCTUnwrap(result.holdings.first(where: { $0.symbol == "GBP" }))

    XCTAssertEqual(eur.valueUsd, 100, accuracy: 0.000_001)
    XCTAssertEqual(gbp.valueUsd, 100, accuracy: 0.000_001)
    XCTAssertEqual(result.holdings.reduce(0) { $0 + $1.valueUsd }, 200, accuracy: 0.000_001)
    XCTAssertFalse(result.warnings.contains(where: { $0.lowercased().contains("fiat") || $0.contains("conversion rate") }))
  }

  func testFiatRateFailureKeepsCryptoAndFiatBalances() async throws {
    let http = ScannerHTTPStub { request in
      if request.url?.path == "/api/v3/exchange_rates" {
        return scannerResponse(request, #"{"error":"temporary"}"#, statusCode: 503)
      }
      return scannerResponse(request, #"{"bitcoin":{"usd":100000}}"#)
    }
    let provider = CoinGeckoPriceClient(http: JSONHTTPClient(http: http))

    let result = try await ExchangeBalanceNormalizer.normalizeWithWarnings(
      balance: ExchangeBalance(total: ["XXBT": 0.5, "ZEUR": 10]),
      id: UUID(),
      provider: .kraken,
      label: "Kraken",
      priceProvider: provider
    )

    XCTAssertEqual(result.holdings.count, 2)
    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "BTC" })?.valueUsd, 50_000)
    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "EUR" })?.valueUsd, 0)
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("Fiat-to-USD rates") && $0.contains("EUR") }))
  }
}

final class JSONHTTPClientHardeningTests: XCTestCase {
  func testFinalWarningPolicyCapsUniqueCountAndProviderControlledLength() {
    let warnings = (0..<1_000).map { index in
      "warning \(index): " + String(repeating: "x", count: 2_000)
    }

    let bounded = ScanWarningPolicy.bounded(warnings)

    XCTAssertEqual(bounded.count, ScanWarningPolicy.maximumCount)
    XCTAssertTrue(bounded.last?.contains("additional unique scan warnings were omitted") == true)
    XCTAssertTrue(bounded.allSatisfy {
      $0.unicodeScalars.count <= ScanWarningPolicy.maximumScalarCount
    })
  }

  func testRetriesOneRateLimitedRequestUsingBoundedRetryAfter() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      let call = requests.append(request)
      if call == 1 {
        return scannerResponse(
          request,
          #"{"error":"slow down"}"#,
          statusCode: 429,
          headerFields: ["Retry-After": "0"]
        )
      }
      return scannerResponse(request, #"{"ok":1}"#)
    }
    let client = JSONHTTPClient(http: http, maxRateLimitRetries: 1)

    let result = try await client.get(URL(string: "https://rpc.example/data")!, as: [String: Int].self)

    XCTAssertEqual(result["ok"], 1)
    XCTAssertEqual(requests.snapshot().count, 2)
  }

  func testRejectsSuccessfulResponseAboveConfiguredSizeLimit() async throws {
    let http = ScannerHTTPStub { request in
      scannerResponse(request, #"{"payload":"too-large"}"#)
    }
    let client = JSONHTTPClient(http: http, maxResponseBytes: 8)

    do {
      _ = try await client.get(URL(string: "https://rpc.example/data")!, as: [String: String].self)
      XCTFail("Expected a response-size failure.")
    } catch let error as JSONHTTPClientError {
      XCTAssertEqual(error, .responseTooLarge)
    }
  }

  func testBoundedURLSessionClientAbortsAnUnknownLengthStreamAtTheLimit() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScannerOversizedURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = BoundedURLSessionHTTPClient(session: session, maxResponseBytes: 8)
    let request = URLRequest(url: URL(string: "https://stream.example/oversized")!)

    do {
      _ = try await client.data(for: request)
      XCTFail("Expected the stream to be aborted at its byte limit.")
    } catch let error as JSONHTTPClientError {
      XCTAssertEqual(error, .responseTooLarge)
    }
  }

  func testBoundedURLSessionClientDoesNotFollowRedirects() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScannerRedirectURLProtocol.self]
    let session = URLSession(
      configuration: configuration,
      delegate: NonRedirectingSessionDelegate(),
      delegateQueue: nil
    )
    defer { session.invalidateAndCancel() }
    let client = BoundedURLSessionHTTPClient(session: session)
    let request = URLRequest(url: URL(string: "https://redirect-origin.example/start")!)

    do {
      _ = try await client.data(for: request)
      XCTFail("Expected the refused redirect to fail the request.")
    } catch {
      XCTAssertTrue(error is URLError)
    }
    XCTAssertEqual(ScannerRedirectURLProtocol.destinationRequestCount, 0)
  }

  func testBoundedURLSessionClientEnforcesAbsoluteDeadlineAndCancelsSlowDrip() async throws {
    ScannerSlowDripURLProtocol.probe.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScannerSlowDripURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = BoundedURLSessionHTTPClient(session: session, resourceTimeout: 0.08)
    var request = URLRequest(url: URL(string: "https://stream.example/slow-drip-deadline")!)
    request.timeoutInterval = 10
    let startedAt = Date()

    do {
      _ = try await client.data(for: request)
      XCTFail("Expected the absolute resource deadline to abort the slow stream.")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .timedOut)
    }

    let elapsed = Date().timeIntervalSince(startedAt)
    XCTAssertGreaterThanOrEqual(elapsed, 0.06)
    // Leave CI scheduling headroom while still proving that the 10-second
    // request timeout is not what ended the slow-drip transfer.
    XCTAssertLessThan(elapsed, 1.5)
    XCTAssertTrue(ScannerSlowDripURLProtocol.probe.waitForStop(timeout: 1))
  }

  func testBoundedURLSessionClientPreservesCallerCancellationAndCancelsSlowDrip() async throws {
    ScannerSlowDripURLProtocol.probe.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScannerSlowDripURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = BoundedURLSessionHTTPClient(session: session, resourceTimeout: 5)
    let request = URLRequest(url: URL(string: "https://stream.example/slow-drip-cancel")!)
    let task = Task { try await client.data(for: request) }
    XCTAssertTrue(ScannerSlowDripURLProtocol.probe.waitForStart(timeout: 1))

    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected caller cancellation to propagate.")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Expected CancellationError, got \(error).")
    }
    XCTAssertTrue(ScannerSlowDripURLProtocol.probe.waitForStop(timeout: 1))
  }

  func testProviderErrorSanitizerRedactsSecretsFlattensControlsAndCapsLength() {
    let rawSecret = String(repeating: "s", count: 80)
    let sanitized = ProviderErrorSanitizer.sanitize(
      "authorization: Bearer \(rawSecret)\napi_key=\(rawSecret) \(String(repeating: "x", count: 500))"
    )

    XCTAssertFalse(sanitized.contains(rawSecret))
    XCTAssertFalse(sanitized.contains("\n"))
    XCTAssertTrue(sanitized.contains("[redacted]"))
    XCTAssertLessThanOrEqual(sanitized.unicodeScalars.count, ProviderErrorSanitizer.maximumScalarCount + 1)
  }
}

final class ScannerCoinbaseAndKrakenTests: XCTestCase {
  func testKrakenNonceGeneratorIsMonotonicAcrossIndependentInstancesAndClockRegression() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let firstGenerator = fixture.makeGenerator()
    let secondGenerator = fixture.makeGenerator()
    let deviceIdentifier = try await firstGenerator.deviceIdentifier()
    let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    let apiKey = "same-key-that-must-not-appear-in-local-state"
    let concurrent = try await withThrowingTaskGroup(of: String.self, returning: [String].self) { group in
      for index in 0..<16 {
        let generator = index.isMultiple(of: 2) ? firstGenerator : secondGenerator
        group.addTask {
          try await generator.next(
            apiKey: apiKey,
            at: baseDate,
            expectedDeviceIdentifier: deviceIdentifier
          )
        }
      }
      var values: [String] = []
      for try await value in group { values.append(value) }
      return values
    }
    let sorted = concurrent.compactMap(Int64.init).sorted()
    let first = Int64(1_700_000_000_000)
    let regressed = try await secondGenerator.next(
      apiKey: apiKey,
      at: baseDate.addingTimeInterval(-60),
      expectedDeviceIdentifier: deviceIdentifier
    )
    let otherKey = try await firstGenerator.next(
      apiKey: "different-key",
      at: baseDate,
      expectedDeviceIdentifier: deviceIdentifier
    )

    XCTAssertEqual(sorted, Array(first..<(first + 16)))
    XCTAssertEqual(regressed, String(first + 16))
    XCTAssertEqual(otherKey, String(first))
    let stateText = try String(contentsOf: fixture.stateURL, encoding: .utf8)
    XCTAssertFalse(stateText.contains(apiKey))
    let statePermissions = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: fixture.stateURL.path)[.posixPermissions] as? NSNumber
    ).intValue & 0o777
    let directoryPermissions = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: fixture.directory.path)[.posixPermissions] as? NSNumber
    ).intValue & 0o777
    XCTAssertEqual(statePermissions, 0o600)
    XCTAssertEqual(directoryPermissions, 0o700)
  }

  func testKrakenNonceGeneratorCoordinatesAcrossClientInstances() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      if request.url?.path == "/0/private/Balance" {
        return scannerResponse(request, #"{"error":[],"result":{}}"#)
      }
      return scannerResponse(request, #"{"error":[],"result":{}}"#)
    }
    let now: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }
    let firstClient = NativeExchangeBalanceClient(
      http: http,
      now: now,
      krakenNonceGenerator: fixture.makeGenerator()
    )
    let secondClient = NativeExchangeBalanceClient(
      http: http,
      now: now,
      krakenNonceGenerator: fixture.makeGenerator()
    )
    let credentials = ExchangeCredentials(
      apiKey: "nonce-test-\(UUID().uuidString)",
      secret: Data("secret".utf8).base64EncodedString()
    )

    async let firstBalance = firstClient.fetchBalance(provider: .kraken, credentials: credentials)
    async let secondBalance = secondClient.fetchBalance(provider: .kraken, credentials: credentials)
    _ = try await (firstBalance, secondBalance)

    let nonces = requests.snapshot().compactMap { request -> Int64? in
      guard request.url?.path == "/0/private/Balance",
            let body = request.httpBody.flatMap({ String(data: $0, encoding: .utf8) }),
            body.hasPrefix("nonce=")
      else { return nil }
      return Int64(body.dropFirst("nonce=".count))
    }.sorted()
    XCTAssertEqual(nonces.count, 2)
    XCTAssertEqual(nonces[1], nonces[0] + 1)
  }

  func testCopiedKrakenStateRotatesLocallyButCannotAuthorizeSourceInstallation() async throws {
    let apiKey = "copied-state-api-key"
    let credentials = ExchangeCredentials(
      apiKey: apiKey,
      secret: Data("secret".utf8).base64EncodedString()
    )
    let source = try krakenStateFixture(secret: Data(repeating: 0x11, count: 32))
    defer { try? FileManager.default.removeItem(at: source.directory) }
    let sourceGenerator = source.makeGenerator()
    let sourceIdentifier = try await sourceGenerator.deviceIdentifier()
    _ = try await sourceGenerator.next(
      apiKey: apiKey,
      at: Date(timeIntervalSince1970: 1_700_000_000),
      expectedDeviceIdentifier: sourceIdentifier
    )
    let copiedBytes = try Data(contentsOf: source.stateURL)
    let copiedText = String(decoding: copiedBytes, as: UTF8.self)
    XCTAssertFalse(copiedText.contains(apiKey))
    XCTAssertFalse(copiedText.contains("credentialIdentifierKey"))
    XCTAssertFalse(copiedText.contains(Data(repeating: 0x11, count: 32).base64EncodedString()))

    // Cover both a fresh Mac with no Keychain item and an established Mac with
    // a different device-only item. Each replaces the unusable copied file,
    // but neither can adopt its identity or send under its old binding.
    let destinationSecrets: [Data?] = [nil, Data(repeating: 0x22, count: 32)]
    for destinationSecret in destinationSecrets {
      let destination = try krakenStateFixture(secret: destinationSecret)
      defer { try? FileManager.default.removeItem(at: destination.directory) }
      try copiedBytes.write(to: destination.stateURL, options: .withoutOverwriting)
      let requests = ScannerRequestLog()
      let client = NativeExchangeBalanceClient(
        http: ScannerHTTPStub { request in
          _ = requests.append(request)
          return scannerResponse(request, #"{"error":[],"result":{}}"#)
        },
        now: { Date(timeIntervalSince1970: 1_699_999_000) },
        krakenNonceGenerator: destination.makeGenerator()
      )

      do {
        _ = try await client.fetchBalance(
          provider: .kraken,
          credentials: credentials,
          krakenDeviceIdentifier: sourceIdentifier
        )
        XCTFail("A copied JSON state must not authorize its source device binding.")
      } catch {
        XCTAssertEqual(error as? KrakenNonceError, .localStateChanged)
      }

      XCTAssertEqual(requests.snapshot().count, 0)
      let replacementBytes = try Data(contentsOf: destination.stateURL)
      XCTAssertNotEqual(replacementBytes, copiedBytes)
      let replacement = try XCTUnwrap(
        JSONSerialization.jsonObject(with: replacementBytes) as? [String: Any]
      )
      let replacementIdentifier = try XCTUnwrap(replacement["deviceIdentifier"] as? String)
      XCTAssertNotEqual(replacementIdentifier, sourceIdentifier)
      XCTAssertEqual(replacement["version"] as? Int, 2)
      XCTAssertEqual((replacement["lastNonceByCredential"] as? [String: String])?.count, 0)
      if let destinationSecret {
        XCTAssertEqual(destination.secretStore.snapshotSecret(), destinationSecret)
      } else {
        XCTAssertEqual(destination.secretStore.snapshotSecret()?.count, 32)
      }
      let persistedReplacementIdentifier = try await destination.makeGenerator().deviceIdentifier()
      XCTAssertEqual(persistedReplacementIdentifier, replacementIdentifier)

      _ = try await client.fetchBalance(
        provider: .kraken,
        credentials: ExchangeCredentials(
          apiKey: "replacement-key-\(destinationSecret == nil ? "fresh" : "established")",
          secret: Data("replacement-secret".utf8).base64EncodedString()
        ),
        krakenDeviceIdentifier: replacementIdentifier
      )
      XCTAssertEqual(requests.snapshot().count, 2)
    }
  }

  func testKrakenInstallationSecretStoreFailuresFailClosedBeforeHTTP() async throws {
    for failureMode in [
      ScannerKrakenInstallationSecretStore.FailureMode.load,
      .save
    ] {
      let fixture = try krakenStateFixture()
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      fixture.secretStore.setFailureMode(failureMode)
      let requests = ScannerRequestLog()
      let client = NativeExchangeBalanceClient(
        http: ScannerHTTPStub { request in
          _ = requests.append(request)
          return scannerResponse(request, #"{"error":[],"result":{}}"#)
        },
        krakenNonceGenerator: fixture.makeGenerator()
      )

      do {
        _ = try await client.fetchBalance(
          provider: .kraken,
          credentials: ExchangeCredentials(
            apiKey: "keychain-failure-key",
            secret: Data("secret".utf8).base64EncodedString()
          ),
          krakenDeviceIdentifier: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        )
        XCTFail("Keychain failures must prevent Kraken request generation.")
      } catch {
        XCTAssertEqual(error as? KrakenNonceError, .localStateUnavailable)
      }

      XCTAssertEqual(requests.snapshot().count, 0)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stateURL.path))
      XCTAssertNil(fixture.secretStore.snapshotSecret())
    }

    let existing = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: existing.directory) }
    let generator = existing.makeGenerator()
    let identifier = try await generator.deviceIdentifier()
    let originalState = try Data(contentsOf: existing.stateURL)
    existing.secretStore.setFailureMode(.load)
    do {
      _ = try await generator.next(
        apiKey: "existing-state-key",
        at: Date(timeIntervalSince1970: 1_700_000_000),
        expectedDeviceIdentifier: identifier
      )
      XCTFail("An existing v2 state must not bypass a Keychain load failure.")
    } catch {
      XCTAssertEqual(error as? KrakenNonceError, .localStateUnavailable)
    }
    XCTAssertEqual(try Data(contentsOf: existing.stateURL), originalState)
  }

  func testMissingKrakenInstallationSecretRotatesBeforeRejectingOldBindingAndRecovers() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let generator = fixture.makeGenerator()
    let originalIdentifier = try await generator.deviceIdentifier()
    _ = try await generator.next(
      apiKey: "old-api-key",
      at: Date(timeIntervalSince1970: 1_700_000_000),
      expectedDeviceIdentifier: originalIdentifier
    )
    fixture.secretStore.removeSecret()

    let requests = ScannerRequestLog()
    let client = NativeExchangeBalanceClient(
      http: ScannerHTTPStub { request in
        _ = requests.append(request)
        return scannerResponse(request, #"{"error":[],"result":{}}"#)
      },
      now: { Date(timeIntervalSince1970: 1_699_999_000) },
      krakenNonceGenerator: generator
    )

    do {
      _ = try await client.fetchBalance(
        provider: .kraken,
        credentials: ExchangeCredentials(
          apiKey: "old-api-key",
          secret: Data("old-secret".utf8).base64EncodedString()
        ),
        krakenDeviceIdentifier: originalIdentifier
      )
      XCTFail("A saved connection must not send after its installation secret disappears.")
    } catch {
      XCTAssertEqual(error as? KrakenNonceError, .localStateChanged)
    }

    XCTAssertEqual(requests.snapshot().count, 0)
    XCTAssertEqual(fixture.secretStore.snapshotSecret()?.count, 32)
    let replacementIdentifier = try await generator.deviceIdentifier()
    XCTAssertNotEqual(replacementIdentifier, originalIdentifier)

    _ = try await client.fetchBalance(
      provider: .kraken,
      credentials: ExchangeCredentials(
        apiKey: "new-read-only-api-key",
        secret: Data("new-secret".utf8).base64EncodedString()
      ),
      krakenDeviceIdentifier: replacementIdentifier
    )
    XCTAssertEqual(requests.snapshot().count, 2)
  }

  func testMalformedOwnedKrakenStateRotatesBeforeRejectingOldBinding() async throws {
    let installationSecret = Data(repeating: 0x55, count: 32)
    let fixture = try krakenStateFixture(secret: installationSecret)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let oldIdentifier = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    try Data(#"{"deviceIdentifier":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}"#.utf8)
      .write(to: fixture.stateURL)
    let requests = ScannerRequestLog()
    let client = NativeExchangeBalanceClient(
      http: ScannerHTTPStub { request in
        _ = requests.append(request)
        return scannerResponse(request, #"{"error":[],"result":{}}"#)
      },
      krakenNonceGenerator: fixture.makeGenerator()
    )

    do {
      _ = try await client.fetchBalance(
        provider: .kraken,
        credentials: ExchangeCredentials(
          apiKey: "old-key",
          secret: Data("secret".utf8).base64EncodedString()
        ),
        krakenDeviceIdentifier: oldIdentifier
      )
      XCTFail("Malformed local state must not authorize a saved old connection.")
    } catch {
      XCTAssertEqual(error as? KrakenNonceError, .localStateChanged)
    }

    XCTAssertEqual(requests.snapshot().count, 0)
    XCTAssertEqual(fixture.secretStore.snapshotSecret(), installationSecret)
    let replacement = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixture.stateURL)) as? [String: Any]
    )
    XCTAssertEqual(replacement["version"] as? Int, 2)
    XCTAssertNotEqual(replacement["deviceIdentifier"] as? String, oldIdentifier)
  }

  func testLegacyCloneableKrakenStateMigratesByRotatingIdentityAndDiscardingNonceMaterial() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let legacyIdentifier = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let legacyCredentialID = String(repeating: "b", count: 64)
    let legacy: [String: Any] = [
      "version": 1,
      "deviceIdentifier": legacyIdentifier,
      "credentialIdentifierKey": Data(repeating: 0x44, count: 32).base64EncodedString(),
      "lastNonceByCredential": [legacyCredentialID: "1700000000000"]
    ]
    try JSONSerialization.data(withJSONObject: legacy).write(to: fixture.stateURL)
    let generator = fixture.makeGenerator()

    do {
      _ = try await generator.next(
        apiKey: "legacy-key",
        at: Date(timeIntervalSince1970: 1_699_999_000),
        expectedDeviceIdentifier: legacyIdentifier
      )
      XCTFail("A legacy cloneable identity must never be carried into v2.")
    } catch {
      XCTAssertEqual(error as? KrakenNonceError, .localStateChanged)
    }

    let migratedData = try Data(contentsOf: fixture.stateURL)
    let migrated = try XCTUnwrap(
      JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
    )
    XCTAssertEqual(migrated["version"] as? Int, 2)
    XCTAssertNotEqual(migrated["deviceIdentifier"] as? String, legacyIdentifier)
    XCTAssertNil(migrated["credentialIdentifierKey"])
    XCTAssertEqual((migrated["lastNonceByCredential"] as? [String: String])?.count, 0)
    XCTAssertNotNil(migrated["installationBinding"] as? String)
    XCTAssertNotNil(fixture.secretStore.snapshotSecret())
    let currentIdentifier = try await generator.deviceIdentifier()
    XCTAssertEqual(currentIdentifier, migrated["deviceIdentifier"] as? String)
  }

  func testDeletingKrakenStateInvalidatesExistingDeviceBindingBeforeNonceReuse() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let generator = fixture.makeGenerator()
    let originalIdentifier = try await generator.deviceIdentifier()
    _ = try await generator.next(
      apiKey: "bound-key",
      at: Date(timeIntervalSince1970: 1_700_000_000),
      expectedDeviceIdentifier: originalIdentifier
    )

    try FileManager.default.removeItem(at: fixture.stateURL)

    do {
      _ = try await generator.next(
        apiKey: "bound-key",
        at: Date(timeIntervalSince1970: 1_699_999_000),
        expectedDeviceIdentifier: originalIdentifier
      )
      XCTFail("Deleted state must invalidate the old device binding before sending a lower nonce.")
    } catch {
      XCTAssertEqual(error as? KrakenNonceError, .localStateChanged)
    }
    let replacementIdentifier = try await generator.deviceIdentifier()
    XCTAssertNotEqual(replacementIdentifier, originalIdentifier)
  }

  func testKrakenStateRejectsSymlinkedLockSymlinkedStateAndOversizedState() throws {
    for symlinkTarget in ["state", "lock"] {
      let fixture = try krakenStateFixture()
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      let protectedTarget = fixture.directory.appending(path: "protected-\(symlinkTarget).txt")
      try Data("do-not-touch".utf8).write(to: protectedTarget)
      let link = symlinkTarget == "state"
        ? fixture.stateURL
        : fixture.stateURL.appendingPathExtension("lock")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: protectedTarget)

      XCTAssertThrowsError(try KrakenDeviceIdentity.currentIdentifier(
        storageURL: fixture.stateURL,
        installationSecretStore: fixture.secretStore
      )) { error in
        XCTAssertEqual(error as? KrakenNonceError, .localStateUnavailable)
      }
      XCTAssertEqual(try String(contentsOf: protectedTarget, encoding: .utf8), "do-not-touch")
    }

    let oversized = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: oversized.directory) }
    try Data(repeating: 0x61, count: 256 * 1_024 + 1).write(to: oversized.stateURL)
    XCTAssertThrowsError(try KrakenDeviceIdentity.currentIdentifier(
      storageURL: oversized.stateURL,
      installationSecretStore: oversized.secretStore
    )) { error in
      XCTAssertEqual(error as? KrakenNonceError, .localStateUnavailable)
    }

    let hardLinked = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: hardLinked.directory) }
    _ = try KrakenDeviceIdentity.currentIdentifier(
      storageURL: hardLinked.stateURL,
      installationSecretStore: hardLinked.secretStore
    )
    let originalState = try Data(contentsOf: hardLinked.stateURL)
    let originalSecret = hardLinked.secretStore.snapshotSecret()
    let secondLink = hardLinked.directory.appending(path: "second-state-link.json")
    try FileManager.default.linkItem(at: hardLinked.stateURL, to: secondLink)

    XCTAssertThrowsError(try KrakenDeviceIdentity.currentIdentifier(
      storageURL: hardLinked.stateURL,
      installationSecretStore: hardLinked.secretStore
    )) { error in
      XCTAssertEqual(error as? KrakenNonceError, .localStateUnavailable)
    }
    XCTAssertEqual(try Data(contentsOf: hardLinked.stateURL), originalState)
    XCTAssertEqual(try Data(contentsOf: secondLink), originalState)
    XCTAssertEqual(hardLinked.secretStore.snapshotSecret(), originalSecret)

    let futureVersion = try krakenStateFixture(secret: Data(repeating: 0x66, count: 32))
    defer { try? FileManager.default.removeItem(at: futureVersion.directory) }
    let futureBytes = Data(#"{"version":3,"future":"do-not-replace"}"#.utf8)
    try futureBytes.write(to: futureVersion.stateURL)
    XCTAssertThrowsError(try KrakenDeviceIdentity.currentIdentifier(
      storageURL: futureVersion.stateURL,
      installationSecretStore: futureVersion.secretStore
    )) { error in
      XCTAssertEqual(error as? KrakenNonceError, .localStateUnavailable)
    }
    XCTAssertEqual(try Data(contentsOf: futureVersion.stateURL), futureBytes)
  }

  func testLegacyUnboundKrakenConnectionDecodesButNeverSendsARequest() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      return scannerResponse(request, #"{"error":[],"result":{}}"#)
    }
    let vaultKey = try VaultCrypto().generateVaultKey()
    let credentialVault = ExchangeCredentialVault()
    let connectionID = UUID()
    let envelope = try credentialVault.seal(
      ExchangeCredentials(
        apiKey: "legacy-key",
        secret: Data("secret".utf8).base64EncodedString()
      ),
      vaultKey: vaultKey,
      connectionId: connectionID
    )
    let legacy = ExchangeConnectionRecord(
      id: connectionID,
      provider: .kraken,
      label: "Legacy Kraken",
      encryptedCredentials: envelope
    )
    let encodedLegacy = try JSONEncoder.addressAtlas.encode(legacy)
    XCTAssertFalse(String(decoding: encodedLegacy, as: UTF8.self).contains("krakenDeviceIdentifier"))
    let decodedLegacy = try JSONDecoder.addressAtlas.decode(
      ExchangeConnectionRecord.self,
      from: encodedLegacy
    )
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(
        http: http,
        krakenNonceGenerator: fixture.makeGenerator()
      ),
      krakenDeviceIdentifier: { "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" }
    )

    let result = try await scanner.scanThrowing(connections: [decodedLegacy], vaultKey: vaultKey)

    XCTAssertEqual(requests.snapshot().count, 0)
    XCTAssertEqual(result.connections.first?.status, .failed)
    XCTAssertTrue(result.connections.first?.lastError?.contains("different Kraken API key") == true)
    XCTAssertTrue(result.connections.first?.lastError?.contains("every device") == true)
  }

  func testSyncedDuplicateBinanceAndCoinbaseKeysFailAllBeforeHTTPOrDoubleCounting() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      return scannerResponse(request, #"{"balances":[]}"#)
    }
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let credentialVault = ExchangeCredentialVault(crypto: crypto)
    var records: [ExchangeConnectionRecord] = []
    for provider in [ExchangeProvider.binance, .coinbase] {
      for apiKey in [" synced-shared-key ", "synced-shared-key"] {
        let id = UUID()
        records.append(ExchangeConnectionRecord(
          id: id,
          provider: provider,
          label: "\(provider.label) duplicate",
          encryptedCredentials: try credentialVault.seal(
            ExchangeCredentials(apiKey: apiKey, secret: "not-used"),
            vaultKey: vaultKey,
            connectionId: id
          )
        ))
      }
    }
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(http: http),
      credentialVault: credentialVault,
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scanThrowing(connections: records, vaultKey: vaultKey)

    XCTAssertEqual(requests.snapshot().count, 0)
    XCTAssertTrue(result.holdings.isEmpty)
    XCTAssertEqual(result.connections.map(\.status), [.failed, .failed, .failed, .failed])
    XCTAssertTrue(result.connections.prefix(2).allSatisfy {
      $0.lastError?.contains("same Binance API key") == true
    })
    XCTAssertTrue(result.connections.suffix(2).allSatisfy {
      $0.lastError?.contains("same Coinbase API key") == true
    })
  }

  func testConvergedDuplicateKrakenKeyAcrossDeviceBindingsFailsAllBeforeHTTP() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      return scannerResponse(request, #"{"error":[],"result":{}}"#)
    }
    let vaultKey = try VaultCrypto().generateVaultKey()
    let credentialVault = ExchangeCredentialVault()
    let deviceA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let deviceB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let records = try [(deviceA, " shared-key "), (deviceB, "shared-key")].map { device, apiKey in
      let id = UUID()
      return ExchangeConnectionRecord(
        id: id,
        provider: .kraken,
        label: "Kraken \(device)",
        encryptedCredentials: try credentialVault.seal(
          ExchangeCredentials(
            apiKey: apiKey,
            secret: Data("secret".utf8).base64EncodedString()
          ),
          vaultKey: vaultKey,
          connectionId: id
        ),
        krakenDeviceIdentifier: device
      )
    }
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(
        http: http,
        krakenNonceGenerator: fixture.makeGenerator()
      ),
      krakenDeviceIdentifier: { deviceA }
    )

    let result = try await scanner.scanThrowing(connections: records, vaultKey: vaultKey)

    XCTAssertEqual(requests.snapshot().count, 0)
    XCTAssertEqual(result.connections.map(\.status), [.failed, .failed])
    XCTAssertTrue(result.connections.allSatisfy {
      $0.lastError?.contains("more than one saved connection") == true
    })
  }

  func testDuplicateKrakenKeyOnSameDeviceFailsAllBeforeHTTPOrDoubleCounting() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      return scannerResponse(request, #"{"error":[],"result":{"XXBT":"1"}}"#)
    }
    let vaultKey = try VaultCrypto().generateVaultKey()
    let credentialVault = ExchangeCredentialVault()
    let localDevice = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let records = try ["same-key", " same-key "].map { apiKey in
      let id = UUID()
      return ExchangeConnectionRecord(
        id: id,
        provider: .kraken,
        label: "Duplicate Kraken",
        encryptedCredentials: try credentialVault.seal(
          ExchangeCredentials(
            apiKey: apiKey,
            secret: Data("secret".utf8).base64EncodedString()
          ),
          vaultKey: vaultKey,
          connectionId: id
        ),
        krakenDeviceIdentifier: localDevice
      )
    }
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(
        http: http,
        krakenNonceGenerator: fixture.makeGenerator()
      ),
      credentialVault: credentialVault,
      priceProvider: ScannerStaticPriceProvider(values: [:]),
      krakenDeviceIdentifier: { localDevice }
    )

    let result = try await scanner.scanThrowing(connections: records, vaultKey: vaultKey)

    XCTAssertEqual(requests.snapshot().count, 0)
    XCTAssertTrue(result.holdings.isEmpty)
    XCTAssertEqual(result.connections.map(\.status), [.failed, .failed])
    XCTAssertTrue(result.connections.allSatisfy {
      $0.lastError?.contains("more than one saved connection") == true
    })
  }

  func testBoundKrakenKeyConflictingWithLegacyOrInvalidBindingFailsAllBeforeHTTP() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      return scannerResponse(request, #"{"error":[],"result":{}}"#)
    }
    let vaultKey = try VaultCrypto().generateVaultKey()
    let credentialVault = ExchangeCredentialVault()
    let localDevice = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    func connection(label: String, deviceIdentifier: String?) throws -> ExchangeConnectionRecord {
      let id = UUID()
      return ExchangeConnectionRecord(
        id: id,
        provider: .kraken,
        label: label,
        encryptedCredentials: try credentialVault.seal(
          ExchangeCredentials(
            apiKey: " shared-key ",
            secret: Data("secret".utf8).base64EncodedString()
          ),
          vaultKey: vaultKey,
          connectionId: id
        ),
        krakenDeviceIdentifier: deviceIdentifier
      )
    }

    let records = try [
      connection(label: "Bound Kraken", deviceIdentifier: localDevice),
      connection(label: "Legacy Kraken", deviceIdentifier: nil),
      connection(label: "Invalid Kraken", deviceIdentifier: "not-a-device-uuid")
    ]
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(
        http: http,
        krakenNonceGenerator: fixture.makeGenerator()
      ),
      credentialVault: credentialVault,
      krakenDeviceIdentifier: { localDevice }
    )

    let result = try await scanner.scanThrowing(connections: records, vaultKey: vaultKey)

    XCTAssertEqual(requests.snapshot().count, 0)
    XCTAssertEqual(result.connections.map(\.status), [.failed, .failed, .failed])
    XCTAssertTrue(result.connections.allSatisfy {
      $0.lastError?.contains("more than one saved connection") == true
    })
  }

  func testForeignDeviceKrakenRecordIsSkippedWithoutMutatingSharedVaultState() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let generator = fixture.makeGenerator()
    let localDevice = try await generator.deviceIdentifier()
    let foreignDevice = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    XCTAssertNotEqual(localDevice, foreignDevice)

    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      if request.url?.path == "/0/private/Balance" {
        return scannerResponse(request, #"{"error":[],"result":{}}"#)
      }
      return scannerResponse(request, #"{"error":[],"result":{}}"#)
    }
    let vaultKey = try VaultCrypto().generateVaultKey()
    let credentialVault = ExchangeCredentialVault()

    func connection(
      label: String,
      apiKey: String,
      deviceIdentifier: String,
      status: ScanStatus,
      updatedAt: Date
    ) throws -> ExchangeConnectionRecord {
      let id = UUID()
      return ExchangeConnectionRecord(
        id: id,
        provider: .kraken,
        label: label,
        encryptedCredentials: try credentialVault.seal(
          ExchangeCredentials(
            apiKey: apiKey,
            secret: Data("secret".utf8).base64EncodedString()
          ),
          vaultKey: vaultKey,
          connectionId: id
        ),
        krakenDeviceIdentifier: deviceIdentifier,
        status: status,
        lastTestedAt: Date(timeIntervalSince1970: 100),
        lastSyncAt: Date(timeIntervalSince1970: 90),
        lastError: status == .failed ? "foreign-device-owned status" : nil,
        createdAt: Date(timeIntervalSince1970: 10),
        updatedAt: updatedAt
      )
    }

    let local = try connection(
      label: "Local Kraken",
      apiKey: "local-key",
      deviceIdentifier: localDevice,
      status: .empty,
      updatedAt: Date(timeIntervalSince1970: 200)
    )
    let foreign = try connection(
      label: "Foreign Kraken",
      apiKey: "foreign-key",
      deviceIdentifier: foreignDevice,
      status: .failed,
      updatedAt: Date(timeIntervalSince1970: 300)
    )
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(
        http: http,
        now: { Date(timeIntervalSince1970: 1_700_000_000) },
        krakenNonceGenerator: generator
      ),
      credentialVault: credentialVault,
      priceProvider: ScannerStaticPriceProvider(values: [:]),
      krakenDeviceIdentifier: { localDevice }
    )

    let result = try await scanner.scanThrowing(
      connections: [local, foreign],
      vaultKey: vaultKey
    )

    XCTAssertEqual(result.connections[0].status, .ok)
    XCTAssertEqual(result.connections[1], foreign)
    XCTAssertEqual(
      requests.snapshot().filter { $0.url?.path == "/0/private/Balance" }.count,
      1
    )
    XCTAssertTrue(result.warnings.contains {
      $0.contains("Foreign Kraken") && $0.contains("skipped on this Mac")
    })
  }

  func testKrakenScannerCanonicalizesTheLocalDeviceIdentityBeforeComparing() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let generator = fixture.makeGenerator()
    let localDevice = try await generator.deviceIdentifier()
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      return scannerResponse(request, #"{"error":[],"result":{}}"#)
    }
    let vaultKey = try VaultCrypto().generateVaultKey()
    let credentialVault = ExchangeCredentialVault()
    let connectionID = UUID()
    let connection = ExchangeConnectionRecord(
      id: connectionID,
      provider: .kraken,
      label: "Local Kraken",
      encryptedCredentials: try credentialVault.seal(
        ExchangeCredentials(
          apiKey: "local-key",
          secret: Data("secret".utf8).base64EncodedString()
        ),
        vaultKey: vaultKey,
        connectionId: connectionID
      ),
      krakenDeviceIdentifier: localDevice
    )
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(
        http: http,
        krakenNonceGenerator: generator
      ),
      credentialVault: credentialVault,
      priceProvider: ScannerStaticPriceProvider(values: [:]),
      krakenDeviceIdentifier: { "  \(localDevice.uppercased())  " }
    )

    let result = try await scanner.scanThrowing(connections: [connection], vaultKey: vaultKey)

    XCTAssertEqual(result.connections.first?.status, .ok)
    XCTAssertEqual(requests.snapshot().filter { $0.url?.path == "/0/private/Balance" }.count, 1)
  }

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
    XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
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

  func testCoinbasePaginatesAccountsAndSignsEveryPage() async throws {
    let requests = ScannerRequestLog()
    let nonces = ScannerNonceSequence(["page-one", "page-two"])
    let http = ScannerHTTPStub { request in
      let call = requests.append(request)
      if call == 1 {
        return scannerResponse(
          request,
          #"{"accounts":[{"uuid":"11111111-1111-4111-8111-111111111111","currency":"BTC","available_balance":{"value":"0.25"},"hold":{"value":"0.25"}}],"has_next":true,"cursor":"next-page"}"#
        )
      }
      return scannerResponse(
        request,
        #"{"accounts":[{"uuid":"22222222-2222-4222-8222-222222222222","currency":"BTC","available_balance":{"value":"0.5"},"hold":{"value":"0"}},{"uuid":"33333333-3333-4333-8333-333333333333","currency":"USDC","available_balance":{"value":"10"},"hold":{"value":"0"}}],"has_next":false}"#
      )
    }
    let key = try scannerPrivateKey()
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      jwtNonce: { nonces.next() }
    )

    let balance = try await client.fetchBalance(
      provider: .coinbase,
      credentials: ExchangeCredentials(
        apiKey: "organizations/test/apiKeys/key-id",
        secret: key.pemRepresentation
      )
    )
    let recorded = requests.snapshot()

    XCTAssertEqual(balance.total["BTC"], 1)
    XCTAssertEqual(balance.total["USDC"], 10)
    XCTAssertEqual(recorded.count, 2)
    XCTAssertNil(URLComponents(url: recorded[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cursor" }))
    XCTAssertEqual(
      URLComponents(url: recorded[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cursor" })?.value,
      "next-page"
    )
    XCTAssertNotEqual(
      recorded[0].value(forHTTPHeaderField: "Authorization"),
      recorded[1].value(forHTTPHeaderField: "Authorization")
    )
  }

  func testCoinbaseDeduplicatesRepeatedAccountUUIDAcrossPages() async throws {
    let requests = ScannerRequestLog()
    let nonces = ScannerNonceSequence(["page-one", "page-two"])
    let http = ScannerHTTPStub { request in
      let call = requests.append(request)
      if call == 1 {
        return scannerResponse(
          request,
          #"{"accounts":[{"uuid":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","currency":"BTC","available_balance":{"value":"0.25"},"hold":{"value":"0.25"}}],"has_next":true,"cursor":"next-page"}"#
        )
      }
      return scannerResponse(
        request,
        #"{"accounts":[{"uuid":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","currency":"BTC","available_balance":{"value":"0.25"},"hold":{"value":"0.25"}},{"uuid":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","currency":"USDC","available_balance":{"value":"10"},"hold":{"value":"0"}}],"has_next":false}"#
      )
    }
    let key = try scannerPrivateKey()
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      jwtNonce: { nonces.next() }
    )

    let balance = try await client.fetchBalance(
      provider: .coinbase,
      credentials: ExchangeCredentials(
        apiKey: "organizations/test/apiKeys/key-id",
        secret: key.pemRepresentation
      )
    )

    XCTAssertEqual(balance.total["BTC"], 0.5)
    XCTAssertEqual(balance.free["BTC"], 0.25)
    XCTAssertEqual(balance.total["USDC"], 10)
    XCTAssertEqual(requests.snapshot().count, 2)
    XCTAssertTrue(balance.warnings.contains {
      $0.contains("repeated 1 identical account record") && $0.contains("double-counting")
    })
  }

  func testCoinbaseExcludesEveryConflictingVersionOfRepeatedAccountUUID() async throws {
    let requests = ScannerRequestLog()
    let nonces = ScannerNonceSequence(["page-one", "page-two"])
    let http = ScannerHTTPStub { request in
      let call = requests.append(request)
      if call == 1 {
        return scannerResponse(
          request,
          #"{"accounts":[{"uuid":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","currency":"BTC","available_balance":{"value":"0.5"},"hold":{"value":"0"}}],"has_next":true,"cursor":"next-page"}"#
        )
      }
      return scannerResponse(
        request,
        #"{"accounts":[{"uuid":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","currency":"BTC","available_balance":{"value":"500"},"hold":{"value":"0"}},{"uuid":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","currency":"USDC","available_balance":{"value":"10"},"hold":{"value":"0"}}],"has_next":false}"#
      )
    }
    let key = try scannerPrivateKey()
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      jwtNonce: { nonces.next() }
    )

    let balance = try await client.fetchBalance(
      provider: .coinbase,
      credentials: ExchangeCredentials(
        apiKey: "organizations/test/apiKeys/key-id",
        secret: key.pemRepresentation
      )
    )

    XCTAssertNil(balance.total["BTC"])
    XCTAssertNil(balance.free["BTC"])
    XCTAssertEqual(balance.total["USDC"], 10)
    XCTAssertEqual(requests.snapshot().count, 2)
    XCTAssertTrue(balance.warnings.contains {
      $0.contains("conflicting data for 1 repeated account UUID")
        && $0.contains("every version")
        && $0.contains("deterministic")
    })
  }

  func testCoinbaseSkipsMissingOrMalformedAccountUUIDsWithWarning() async throws {
    let http = ScannerHTTPStub { request in
      scannerResponse(
        request,
        #"{"accounts":[{"uuid":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","currency":"BTC","available_balance":{"value":"1"},"hold":{"value":"0"}},{"currency":"ETH","available_balance":{"value":"2"},"hold":{"value":"0"}},{"uuid":"not-a-uuid","currency":"SOL","available_balance":{"value":"3"},"hold":{"value":"0"}},{"uuid":42,"currency":"DOGE","available_balance":{"value":"4"},"hold":{"value":"0"}},{"uuid":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","currency":"USDC","available_balance":{"value":"5"},"hold":{"value":"0"}}],"has_next":false}"#
      )
    }
    let key = try scannerPrivateKey()
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      jwtNonce: { "one-page" }
    )

    let balance = try await client.fetchBalance(
      provider: .coinbase,
      credentials: ExchangeCredentials(
        apiKey: "organizations/test/apiKeys/key-id",
        secret: key.pemRepresentation
      )
    )

    XCTAssertEqual(balance.total, ["BTC": 1, "USDC": 5])
    XCTAssertEqual(balance.free, ["BTC": 1, "USDC": 5])
    XCTAssertTrue(balance.warnings.contains {
      $0.contains("3 account record") && $0.contains("missing or malformed UUID")
    })
  }

  func testCoinbaseKeepsCompletedPagesWhenLaterPageFails() async throws {
    let requests = ScannerRequestLog()
    let nonces = ScannerNonceSequence(["page-one", "page-two"])
    let http = ScannerHTTPStub { request in
      let call = requests.append(request)
      if call == 1 {
        return scannerResponse(
          request,
          #"{"accounts":[{"uuid":"11111111-1111-4111-8111-111111111111","currency":"BTC","available_balance":{"value":"0.5"},"hold":{"value":"0"}}],"has_next":true,"cursor":"next-page"}"#
        )
      }
      return scannerResponse(request, #"{"error":"temporary"}"#, statusCode: 503)
    }
    let key = try scannerPrivateKey()
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      jwtNonce: { nonces.next() }
    )

    let balance = try await client.fetchBalance(
      provider: .coinbase,
      credentials: ExchangeCredentials(
        apiKey: "organizations/test/apiKeys/key-id",
        secret: key.pemRepresentation
      )
    )

    XCTAssertEqual(balance.total["BTC"], 0.5)
    XCTAssertTrue(balance.warnings.contains(where: { $0.contains("completed pages") }))
  }

  func testBinanceRejectsOversizedAndControlCharacterAssetCodesBeforeAggregation() async throws {
    let oversizedSymbol = String(repeating: "A", count: 65)
    let controlSymbol = "BTC\nINJECTED"
    let http = ScannerHTTPStub { request in
      let payload: [String: Any] = [
        "balances": [
          ["asset": oversizedSymbol, "free": "1", "locked": "0"],
          ["asset": controlSymbol, "free": "2", "locked": "0"],
          ["asset": "eth", "free": "3", "locked": "0"]
        ]
      ]
      return (
        try JSONSerialization.data(withJSONObject: payload),
        scannerHTTPResponse(request)
      )
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    let balance = try await client.fetchBalance(
      provider: .binance,
      credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
    )

    XCTAssertEqual(balance.total, ["ETH": 3])
    XCTAssertEqual(balance.free, ["ETH": 3])
    XCTAssertTrue(balance.warnings.contains { $0.contains("2 account balance record") })
    XCTAssertFalse(balance.warnings.joined().contains(oversizedSymbol))
    XCTAssertFalse(balance.warnings.joined().contains("\n"))
  }

  func testBinanceAggregatesThousandsOfInvalidRecordsAndRejectsFiniteAdditionOverflow() async throws {
    var recordBuilder = Array(
      repeating: ["asset": "BTC", "free": "not-a-number", "locked": "0"],
      count: 5_000
    )
    recordBuilder.append(["asset": "ETH", "free": "1e308", "locked": "1e308"])
    let records = recordBuilder
    let http = ScannerHTTPStub { request in
      (
        try JSONSerialization.data(withJSONObject: ["balances": records]),
        scannerHTTPResponse(request)
      )
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    let balance = try await client.fetchBalance(
      provider: .binance,
      credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
    )

    XCTAssertTrue(balance.total.isEmpty)
    XCTAssertTrue(balance.free.isEmpty)
    XCTAssertEqual(balance.warnings.count, 2)
    XCTAssertTrue(balance.warnings.contains { $0.contains("5000 account balance record") })
    XCTAssertTrue(balance.warnings.contains { $0.contains("ETH") && $0.contains("numeric range") })
    XCTAssertTrue(balance.warnings.allSatisfy {
      $0.unicodeScalars.count <= ScanWarningPolicy.maximumScalarCount
    })
  }

  func testCoinbaseRejectsOversizedAndControlCharacterCurrenciesBeforeAggregation() async throws {
    let oversizedSymbol = String(repeating: "A", count: 65)
    let controlSymbol = "BTC\rINJECTED"
    let http = ScannerHTTPStub { request in
      let payload: [String: Any] = [
        "accounts": [
          [
            "uuid": "11111111-1111-4111-8111-111111111111",
            "currency": oversizedSymbol,
            "available_balance": ["value": "1"],
            "hold": ["value": "0"]
          ],
          [
            "uuid": "22222222-2222-4222-8222-222222222222",
            "currency": controlSymbol,
            "available_balance": ["value": "2"],
            "hold": ["value": "0"]
          ],
          [
            "uuid": "33333333-3333-4333-8333-333333333333",
            "currency": "usdc",
            "available_balance": ["value": "3"],
            "hold": ["value": "0"]
          ]
        ],
        "has_next": false
      ]
      return (
        try JSONSerialization.data(withJSONObject: payload),
        scannerHTTPResponse(request)
      )
    }
    let key = try scannerPrivateKey()
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      jwtNonce: { "symbol-validation" }
    )

    let balance = try await client.fetchBalance(
      provider: .coinbase,
      credentials: ExchangeCredentials(
        apiKey: "organizations/test/apiKeys/key-id",
        secret: key.pemRepresentation
      )
    )

    XCTAssertEqual(balance.total, ["USDC": 3])
    XCTAssertEqual(balance.free, ["USDC": 3])
    XCTAssertTrue(balance.warnings.contains { $0.contains("2 account record") && $0.contains("invalid asset code") })
    XCTAssertFalse(balance.warnings.joined().contains(oversizedSymbol))
    XCTAssertFalse(balance.warnings.joined().contains("\r"))
  }

  func testKrakenRejectsInvalidBalanceCodesAndMetadataAliasesButPreservesKnownSuffixes() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let oversizedSymbol = String(repeating: "A", count: 65)
    let controlSymbol = "BTC\nINJECTED"
    let http = ScannerHTTPStub { request in
      let payload: [String: Any]
      if request.url?.path == "/0/private/Balance" {
        payload = [
          "error": [],
          "result": [oversizedSymbol: "1", controlSymbol: "2", "XETH.S": "3"]
        ]
      } else {
        payload = [
          "error": [],
          "result": ["XETH": ["altname": "ETH\nINJECTED"]]
        ]
      }
      return (
        try JSONSerialization.data(withJSONObject: payload),
        scannerHTTPResponse(request)
      )
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      krakenNonceGenerator: fixture.makeGenerator()
    )

    let balance = try await client.fetchBalance(
      provider: .kraken,
      credentials: ExchangeCredentials(
        apiKey: "symbol-validation-key",
        secret: Data("secret".utf8).base64EncodedString()
      )
    )

    XCTAssertEqual(balance.total, ["ETH": 3])
    XCTAssertTrue(balance.warnings.contains { $0.contains("metadata was unavailable") })
    XCTAssertTrue(balance.warnings.contains { $0.contains("2 balance record") && $0.contains("invalid asset code") })
    XCTAssertFalse(balance.warnings.joined().contains(oversizedSymbol))
    XCTAssertFalse(balance.warnings.joined().contains("\n"))
  }

  func testKrakenUsesAssetMetadataAndPreservesFiatAsUnpriced() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      if request.url?.path == "/0/private/Balance" {
        return scannerResponse(
          request,
          #"{"error":[],"result":{"XXBT":"0.5","XXLM":"2","XETH.S":"3","ZUSD":"4","ZEUR":"5","USD.M":"6"}}"#
        )
      }
      return scannerResponse(
        request,
        #"{"error":[],"result":{"XXBT":{"altname":"XBT"},"XXLM":{"altname":"XLM"},"XETH":{"altname":"ETH"},"ZUSD":{"altname":"USD"},"ZEUR":{"altname":"EUR"}}}"#
      )
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      krakenNonceGenerator: fixture.makeGenerator()
    )
    let balance = try await client.fetchBalance(
      provider: .kraken,
      credentials: ExchangeCredentials(
        apiKey: "key",
        secret: Data("secret".utf8).base64EncodedString()
      )
    )
    let normalized = try await ExchangeBalanceNormalizer.normalizeWithWarnings(
      balance: balance,
      id: UUID(),
      provider: .kraken,
      label: "Kraken",
      priceProvider: ScannerStaticPriceProvider(values: [
        "bitcoin": PricePoint(usd: 100_000),
        "ethereum": PricePoint(usd: 3_000),
        "stellar": PricePoint(usd: 0.1)
      ])
    )

    XCTAssertEqual(balance.total["BTC"], 0.5)
    XCTAssertEqual(balance.total["XLM"], 2)
    XCTAssertEqual(balance.total["ETH"], 3)
    XCTAssertEqual(balance.total["USD"], 10)
    XCTAssertEqual(balance.total["EUR"], 5)
    XCTAssertEqual(normalized.holdings.first(where: { $0.symbol == "EUR" })?.priceUsd, 0)
    XCTAssertTrue(normalized.warnings.contains(where: { $0.contains("EUR") }))
    XCTAssertEqual(Set(requests.snapshot().compactMap { $0.url?.path }), ["/0/private/Balance", "/0/public/Assets"])
  }

  func testKrakenRejectsCaseFoldedAssetAliasCollisionsWithoutTrapOrIncorrectAlias() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      if request.url?.path == "/0/private/Balance" {
        return scannerResponse(request, #"{"error":[],"result":{"FOO":"1"}}"#)
      }
      return scannerResponse(
        request,
        #"{"error":[],"result":{"foo":{"altname":"BTC"},"FOO":{"altname":"DOGE"}}}"#
      )
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      krakenNonceGenerator: fixture.makeGenerator()
    )

    let balance = try await client.fetchBalance(
      provider: .kraken,
      credentials: ExchangeCredentials(
        apiKey: "alias-collision-key",
        secret: Data("secret".utf8).base64EncodedString()
      )
    )

    XCTAssertEqual(balance.total, ["FOO": 1])
    XCTAssertNil(balance.total["BTC"])
    XCTAssertNil(balance.total["DOGE"])
    XCTAssertTrue(balance.warnings.contains { $0.contains("metadata was unavailable") })
    XCTAssertEqual(
      Set(requests.snapshot().compactMap { $0.url?.path }),
      ["/0/private/Balance", "/0/public/Assets"]
    )
  }

  private func krakenStateFixture(
    secret: Data? = nil
  ) throws -> ScannerKrakenStateFixture {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "address-atlas-kraken-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return ScannerKrakenStateFixture(
      directory: directory,
      stateURL: directory.appending(path: "state.json"),
      secretStore: ScannerKrakenInstallationSecretStore(secret: secret)
    )
  }
}

final class ScannerWorkflowTests: XCTestCase {
  func testNativeValuationOverflowRemainsFiniteAndDropsNonFinitePriceChange() async throws {
    let http = ScannerHTTPStub { request in
      scannerResponse(
        request,
        #"{"chain_stats":{"funded_txo_sum":1e308,"spent_txo_sum":0},"mempool_stats":{"funded_txo_sum":0,"spent_txo_sum":0}}"#
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(
        values: ["bitcoin": PricePoint(usd: 1e308, usd24hChange: .infinity)]
      )
    )

    let result = try await scanner.scan(addresses: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT")
    let holding = try XCTUnwrap(result.holdings.first)

    XCTAssertTrue(holding.amount.isFinite)
    XCTAssertEqual(holding.priceUsd, 1e308)
    XCTAssertEqual(holding.valueUsd, 0)
    XCTAssertNil(holding.change24h)
    XCTAssertEqual(result.totalUsd, 0)
    XCTAssertTrue(result.warnings.contains { $0.contains("USD valuation exceeded") })
    XCTAssertNoThrow(try JSONEncoder.addressAtlas.encode(result))
  }

  func testSPLAggregationRejectsTwoFiniteAmountsWhoseSumOverflows() async throws {
    let usdcMint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    let http = ScannerHTTPStub { request in
      let body = try scannerJSONObject(request.httpBody ?? Data())
      if body["method"] as? String == "getBalance" {
        return scannerResponse(request, #"{"result":{"value":0}}"#)
      }
      let payload: [String: Any] = [
        "result": [
          "value": [[
            "account": [
              "data": [
                "parsed": [
                  "info": [
                    "mint": usdcMint,
                    "tokenAmount": ["amount": "1e308", "decimals": 0]
                  ]
                ]
              ]
            ]
          ]]
        ]
      ]
      return (
        try JSONSerialization.data(withJSONObject: payload),
        scannerHTTPResponse(request)
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: ["usd-coin": PricePoint(usd: 1)])
    )

    let result = try await scanner.scan(addresses: "11111111111111111111111111111111")

    XCTAssertFalse(result.holdings.contains { $0.symbol == "USDC" })
    XCTAssertTrue(result.warnings.contains {
      $0.contains("SPL balances exceeded") && $0.contains("USDC")
    })
    XCTAssertTrue(result.totalUsd.isFinite)
  }

  func testPersistedStargazeRecordsDecodeAndWarnWithoutBlockingSupportedWallets() async throws {
    let stargazeAddress = "stars1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqspal9j"
    let bitcoinAddress = "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
    let document = VaultDocument(
      schemaVersion: 1,
      wallets: [
        WalletRecord(label: "Legacy Stargaze", address: stargazeAddress, chainKind: .cosmos),
        WalletRecord(label: "Bitcoin", address: bitcoinAddress, chainKind: .bitcoin)
      ],
      customTokens: [
        CustomTokenRecord(
          chainKind: .cosmos,
          chainId: "stargaze",
          address: stargazeAddress,
          symbol: "STARS",
          name: "Legacy Stargaze record",
          decimals: 6
        )
      ]
    )
    let decoded = try JSONDecoder.addressAtlas.decode(
      VaultDocument.self,
      from: JSONEncoder.addressAtlas.encode(document)
    )
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      return scannerResponse(
        request,
        #"{"chain_stats":{"funded_txo_sum":100000000,"spent_txo_sum":0},"mempool_stats":{"funded_txo_sum":0,"spent_txo_sum":0}}"#
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: ["bitcoin": PricePoint(usd: 1)])
    )

    let result = try await scanner.scan(
      addresses: decoded.wallets.map(\.address).joined(separator: "\n"),
      customTokens: decoded.customTokens
    )

    XCTAssertEqual(decoded.schemaVersion, VaultDocument.currentSchemaVersion)
    XCTAssertEqual(decoded.wallets.count, 2)
    XCTAssertEqual(decoded.customTokens.map(\.chainId), ["stargaze"])
    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "BTC" })?.amount, 1)
    XCTAssertEqual(requests.snapshot().count, 1)
    XCTAssertTrue(result.warnings.contains(where: {
      $0.contains("Stargaze is retired") && $0.contains("saved address was kept but not scanned")
    }))
    XCTAssertTrue(result.warnings.contains(where: {
      $0.contains("references retired Stargaze") && $0.contains("saved record was kept but not scanned")
    }))
  }

  func testRateLimitedErc20BatchDoesNotFanOutIntoIndividualCalls() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      if body.contains("\"eth_getBalance\"") {
        return scannerResponse(request, #"{"result":"0x0"}"#)
      }
      if body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
        return scannerResponse(
          request,
          #"{"error":"rate limited"}"#,
          statusCode: 429,
          headerFields: ["Retry-After": "0"]
        )
      }
      XCTFail("Unexpected individual ERC-20 request after a rate-limited batch: \(body)")
      return scannerResponse(request, #"{"result":"0x0"}"#)
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http, maxRateLimitRetries: 0),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(addresses: "0x0000000000000000000000000000000000000001")
    let bodies = requests.snapshot().compactMap { request in
      request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
    }

    XCTAssertTrue(bodies.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") }))
    XCTAssertFalse(bodies.contains(where: {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") && $0.contains("\"eth_call\"")
    }))
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("rate-limited") && $0.contains("individual retries") }))
  }

  func testMalformedSolanaTokenAmountProducesVisibleWarning() async throws {
    let http = ScannerHTTPStub { request in
      let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      if body.contains("getBalance") {
        return scannerResponse(request, #"{"result":{"value":-1}}"#)
      }
      return scannerResponse(
        request,
        #"{"result":{"value":[{"account":{"data":{"parsed":{"info":{"mint":"EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v","tokenAmount":{"amount":"not-a-number","decimals":6}}}}}}]}}"#
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(addresses: "11111111111111111111111111111111")

    XCTAssertFalse(result.holdings.contains(where: { $0.symbol == "USDC" }))
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("Native SOL") && $0.contains("invalid") }))
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("USDC") && $0.contains("invalid") }))
  }

  func testNegativeBitcoinProviderStatisticsProduceVisibleWarning() async throws {
    let http = ScannerHTTPStub { request in
      scannerResponse(
        request,
        #"{"chain_stats":{"funded_txo_sum":-1,"spent_txo_sum":0},"mempool_stats":{"funded_txo_sum":0,"spent_txo_sum":0}}"#
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(addresses: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT")

    XCTAssertFalse(result.holdings.contains(where: { $0.symbol == "BTC" }))
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("invalid statistics") }))
  }

  func testMalformedCosmosAmountProducesVisibleWarning() async throws {
    let http = ScannerHTTPStub { request in
      switch request.url?.path {
      case let path? where path.contains("/cosmos/bank/"):
        return scannerResponse(request, #"{"balances":[{"denom":"uatom","amount":"not-a-number"}]}"#)
      case let path? where path.contains("/cosmos/staking/"):
        return scannerResponse(request, #"{"delegation_responses":[]}"#)
      default:
        return scannerResponse(request, #"{"total":[]}"#)
      }
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(
      addresses: "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"
    )

    XCTAssertFalse(result.holdings.contains(where: { $0.symbol == "ATOM" }))
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("Liquid balance could not be read") }))
  }

  func testCosmosPaginationFollowsNextKeysAndCombinesAllPages() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let nextKey = query.first(where: { $0.name == "pagination.key" })?.value
      switch request.url?.path {
      case let path? where path.contains("/cosmos/bank/"):
        if nextKey == nil {
          return scannerResponse(
            request,
            #"{"balances":[{"denom":"uother","amount":"9"}],"pagination":{"next_key":"bank+/="}}"#
          )
        }
        XCTAssertEqual(nextKey, "bank+/=")
        return scannerResponse(
          request,
          #"{"balances":[{"denom":"uatom","amount":"1200000"}],"pagination":{"next_key":null}}"#
        )
      case let path? where path.contains("/cosmos/staking/"):
        if nextKey == nil {
          return scannerResponse(
            request,
            #"{"delegation_responses":[{"balance":{"denom":"uatom","amount":"1000000"}}],"pagination":{"next_key":"stake-key"}}"#
          )
        }
        XCTAssertEqual(nextKey, "stake-key")
        return scannerResponse(
          request,
          #"{"delegation_responses":[{"balance":{"denom":"uatom","amount":"1500000"}}],"pagination":{"next_key":""}}"#
        )
      default:
        return scannerResponse(request, #"{"total":[]}"#)
      }
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(
      addresses: "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"
    )

    XCTAssertEqual(result.holdings.first(where: { $0.source == .native })?.amount, 1.2)
    XCTAssertEqual(result.holdings.first(where: { $0.source == .staked })?.amount, 2.5)
    let paginated = requests.snapshot().filter {
      $0.url?.path.contains("/cosmos/bank/") == true || $0.url?.path.contains("/cosmos/staking/") == true
    }
    XCTAssertEqual(paginated.count, 4)
    XCTAssertTrue(paginated.allSatisfy { request in
      URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
        .contains(where: { $0.name == "pagination.limit" && $0.value == "500" }) == true
    })
    let encodedQueries = paginated.compactMap {
      URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.percentEncodedQuery
    }
    XCTAssertTrue(encodedQueries.contains(where: {
      $0.contains("pagination.key=bank%2B%2F%3D")
    }))
    XCTAssertFalse(encodedQueries.contains(where: { $0.contains("pagination.key=bank+") }))
  }

  func testCosmosPaginationStopsOnRepeatedKeysWithAWarning() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      switch request.url?.path {
      case let path? where path.contains("/cosmos/bank/"):
        _ = requests.append(request)
        return scannerResponse(
          request,
          #"{"balances":[{"denom":"uatom","amount":"1000000"}],"pagination":{"next_key":"repeat"}}"#
        )
      case let path? where path.contains("/cosmos/staking/"):
        return scannerResponse(request, #"{"delegation_responses":[]}"#)
      default:
        return scannerResponse(request, #"{"total":[]}"#)
      }
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:]),
      maxCosmosPages: 5
    )

    let result = try await scanner.scan(
      addresses: "cosmos1qqqtduhx4t2xvgcxrqfmrz0heq00vlvjqhuz93nwt6d2y0quqlqqxxec22"
    )

    XCTAssertEqual(requests.snapshot().count, 2)
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("repeated key") }))
  }

  func testMalformedTronTokenAmountProducesVisibleWarning() async throws {
    let http = ScannerHTTPStub { request in
      scannerResponse(
        request,
        #"{"data":[{"balance":-1,"trc20":[{"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t":"not-a-number"}]}]}"#
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scan(addresses: "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7")

    XCTAssertFalse(result.holdings.contains(where: { $0.symbol == "USDT" }))
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("Native TRX") && $0.contains("invalid") }))
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("USDT") && $0.contains("invalid") }))
  }

  func testTronScanPublishesFragmentBasedExplorerURL() async throws {
    let address = "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
    let http = ScannerHTTPStub { request in
      scannerResponse(request, #"{"data":[{"balance":1000000,"trc20":[]}]}"#)
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: ["tron": PricePoint(usd: 1)])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertEqual(
      result.holdings.first(where: { $0.symbol == "TRX" })?.explorerUrl,
      "https://tronscan.org/#/address/\(address)"
    )
  }

  func testPriceOutagePreservesSuccessfulNativeBalance() async throws {
    let http = ScannerHTTPStub { request in
      scannerResponse(
        request,
        #"{"chain_stats":{"funded_txo_sum":150000000,"spent_txo_sum":0},"mempool_stats":{"funded_txo_sum":0,"spent_txo_sum":0}}"#
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerFailingPriceProvider()
    )

    let result = try await scanner.scan(addresses: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT")

    XCTAssertEqual(result.holdings.first?.symbol, "BTC")
    XCTAssertEqual(result.holdings.first?.amount, 1.5)
    XCTAssertEqual(result.holdings.first?.priceUsd, 0)
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("pricing is temporarily unavailable") }))
  }

  func testXrpAccountLinesMarkerPaginationPreservesAllPages() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      let body = try scannerJSONObject(request.httpBody ?? Data())
      let method = body["method"] as? String
      if method == "account_info" {
        return scannerResponse(request, #"{"result":{"status":"success","account_data":{"Balance":"1000000"}}}"#)
      }
      let page = requests.append(request)
      if page == 1 {
        return scannerResponse(
          request,
          #"{"result":{"status":"success","lines":[{"account":"rIssuerOne","balance":"2","currency":"USD"}],"marker":{"ledger":123,"seq":1}}}"#
        )
      }
      return scannerResponse(
        request,
        #"{"result":{"status":"success","lines":[{"account":"rIssuerTwo","balance":"3","currency":"EUR"}]}}"#
      )
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: ["ripple": PricePoint(usd: 1)])
    )

    let result = try await scanner.scan(addresses: "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn")
    let issued = result.holdings.filter { $0.source == .issued }
    let secondBody = try scannerJSONObject(requests.snapshot()[1].httpBody ?? Data())
    let params = (secondBody["params"] as? [[String: Any]])?.first

    XCTAssertEqual(Set(issued.map(\.symbol)), ["USD", "EUR"])
    XCTAssertEqual(requests.snapshot().count, 2)
    XCTAssertNotNil(params?["marker"] as? [String: Any])
    XCTAssertFalse(result.warnings.contains(where: { $0.contains("trustline") }))
  }

  func testNativeGlobalDeadlineKeepsCompletedChainsAndSkipsRemainder() async throws {
    let http = ScannerHTTPStub { request in
      if request.url?.path.contains("/address/") == true {
        return scannerResponse(
          request,
          #"{"chain_stats":{"funded_txo_sum":100000000,"spent_txo_sum":0},"mempool_stats":{"funded_txo_sum":0,"spent_txo_sum":0}}"#
        )
      }
      try await Task.sleep(nanoseconds: 5_000_000_000)
      return scannerResponse(request, "{}")
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [
        "bitcoin": PricePoint(usd: 100_000),
        "ripple": PricePoint(usd: 1)
      ]),
      maxConcurrentChainScans: 1,
      chainDeadline: 10,
      workflowDeadline: 0.05
    )

    let result = try await scanner.scan(
      addresses: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn"
    )

    XCTAssertEqual(result.holdings.map(\.symbol), ["BTC"])
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("overall scan") && $0.contains("completed results") }))
  }

  func testNativeScannerWarnsWhenMoreThanTwentyFourInputsAreSupplied() async throws {
    let input = (1...25)
      .map { String(format: "0x%040llx", UInt64($0)) }
      .joined(separator: " ")
    let http = ScannerHTTPStub { request in
      try await Task.sleep(nanoseconds: 5_000_000_000)
      return scannerResponse(request, "{}")
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:]),
      maxConcurrentChainScans: 1,
      chainDeadline: 10,
      workflowDeadline: 0.03
    )

    let result = try await scanner.scan(addresses: input)

    XCTAssertEqual(result.inputCount, 24)
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("first 24") }))
  }

  func testExchangeGlobalDeadlineKeepsCompletedConnectionAndAllRecords() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      let call = requests.append(request)
      if call == 1 {
        return scannerResponse(
          request,
          #"{"balances":[{"asset":"USDC","free":"1","locked":"0"}]}"#
        )
      }
      try await Task.sleep(nanoseconds: 5_000_000_000)
      return scannerResponse(request, "{}")
    }
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let credentialVault = ExchangeCredentialVault(crypto: crypto)
    let connections = try (0..<2).map { index -> ExchangeConnectionRecord in
      let id = UUID()
      let envelope = try credentialVault.seal(
        ExchangeCredentials(apiKey: "key-\(index)", secret: "secret"),
        vaultKey: vaultKey,
        connectionId: id
      )
      return ExchangeConnectionRecord(
        id: id,
        provider: .binance,
        label: "Binance \(index)",
        encryptedCredentials: envelope
      )
    }
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(
        http: http,
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
      ),
      credentialVault: credentialVault,
      priceProvider: ScannerStaticPriceProvider(values: [:]),
      maxConcurrentConnections: 1,
      connectionDeadline: 10,
      workflowDeadline: 0.05
    )

    let result = try await scanner.scanThrowing(connections: connections, vaultKey: vaultKey)

    XCTAssertEqual(result.holdings.map(\.symbol), ["USDC"])
    XCTAssertEqual(result.connections.count, 2)
    XCTAssertEqual(result.connections[0].status, .ok)
    XCTAssertEqual(result.connections[1].status, .empty)
    XCTAssertTrue(result.warnings.contains(where: { $0.contains("overall exchange scan") }))
  }

  func testBoundedMapPreservesOrderAndConcurrencyLimit() async throws {
    let probe = ScannerConcurrencyProbe()
    let values = try await boundedConcurrentMap(Array(0..<8), maxConcurrent: 2) { value in
      await probe.enter()
      try await Task.sleep(nanoseconds: 20_000_000)
      await probe.leave()
      return value * 2
    }

    XCTAssertEqual(values, Array(0..<8).map { $0 * 2 })
    let maximum = await probe.maximum()
    XCTAssertEqual(maximum, 2)
  }

  func testWorkflowDeadlineAndCancellationPropagate() async throws {
    do {
      _ = try await withWorkflowTimeout(seconds: .greatestFiniteMagnitude) { 1 }
      XCTFail("An unrepresentable timeout must fail without trapping.")
    } catch let error as WorkflowTimeoutError {
      XCTAssertEqual(error.seconds, .greatestFiniteMagnitude)
      XCTAssertFalse(error.localizedDescription.isEmpty)
    }

    let hugeDeadlineScanner = NativeScanner(
      priceProvider: ScannerStaticPriceProvider(values: [:]),
      workflowDeadline: .greatestFiniteMagnitude
    )
    let hugeDeadlineResult = try await hugeDeadlineScanner.scan(
      addresses: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
    )
    XCTAssertTrue(hugeDeadlineResult.warnings.contains { $0.contains("overall scan reached") })

    do {
      _ = try await withWorkflowTimeout(seconds: 0.02) {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return 1
      }
      XCTFail("Expected deadline.")
    } catch let error as WorkflowTimeoutError {
      XCTAssertEqual(error.seconds, 0.02)
    }

    let scanner = NativeScanner(priceProvider: ScannerSleepingPriceProvider())
    let task = Task {
      try await scanner.scan(addresses: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT")
    }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation.")
    } catch is CancellationError {
      // Expected.
    }
  }

  func testCoinGeckoBatchesRequestsAndKeepsSuccessfulBatches() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      let call = requests.append(request)
      if call == 2 { return scannerResponse(request, #"{"error":"temporary"}"#, statusCode: 503) }
      let ids = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "ids" })?.value?.split(separator: ",").map(String.init) ?? []
      let object = Dictionary(uniqueKeysWithValues: ids.map { ($0, ["usd": 1.0]) })
      let data = try JSONSerialization.data(withJSONObject: object)
      return (data, scannerHTTPResponse(request))
    }
    let client = CoinGeckoPriceClient(http: JSONHTTPClient(http: http))

    let prices = try await client.prices(for: (0..<205).map { "coin-\($0)" })

    XCTAssertEqual(requests.snapshot().count, 3)
    XCTAssertEqual(prices.count, 105)
  }

  func testScannerRequestsHitExpectedProductionEndpointsForEveryChain() async throws {
    let bitcoinAddress = "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
    let evmAddress = "0x0000000000000000000000000000000000000001"
    let solanaAddress = "11111111111111111111111111111111"
    let tronAddress = "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
    let xrpAddress = "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn"
    let cosmosAddress = "cosmos1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5lzv7xu"
    let osmosisAddress = "osmo1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5helwsw"
    let celestiaAddress = "celestia1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5wgawu3"
    let strideAddress = "stride1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5ufvzjs"

    // Chain id -> expected production origin and path of that chain's first
    // balance request. Pinned as literals so a drifted host or path in
    // ChainRegistry (or the bundled endpoint config that overrides it) fails
    // this test even though the HTTP stub happily answers any URL.
    let expectations: [String: (host: String, port: Int?, path: String)] = [
      "bitcoin": ("blockstream.info", nil, "/api/address/\(bitcoinAddress)"),
      "ethereum": ("ethereum-rpc.publicnode.com", nil, ""),
      "base": ("mainnet.base.org", nil, ""),
      "arbitrum": ("arb1.arbitrum.io", nil, "/rpc"),
      "optimism": ("mainnet.optimism.io", nil, ""),
      "polygon": ("polygon.drpc.org", nil, ""),
      "bsc": ("bsc-dataseed.binance.org", nil, ""),
      "avalanche": ("api.avax.network", nil, "/ext/bc/C/rpc"),
      "gnosis": ("rpc.gnosischain.com", nil, ""),
      "linea": ("rpc.linea.build", nil, ""),
      "mantle": ("rpc.mantle.xyz", nil, ""),
      "scroll": ("rpc.scroll.io", nil, ""),
      "zksync-era": ("mainnet.era.zksync.io", nil, ""),
      "solana": ("api.mainnet-beta.solana.com", nil, ""),
      "tron": ("api.trongrid.io", nil, "/v1/accounts/\(tronAddress)"),
      "xrp": ("s1.ripple.com", 51234, "/"),
      "cosmoshub": ("cosmos-api.polkachu.com", nil, "/cosmos/bank/v1beta1/balances/\(cosmosAddress)"),
      "osmosis": ("lcd.osmosis.zone", nil, "/cosmos/bank/v1beta1/balances/\(osmosisAddress)"),
      "celestia": ("celestia-api.polkachu.com", nil, "/cosmos/bank/v1beta1/balances/\(celestiaAddress)"),
      "stride": ("stride-api.polkachu.com", nil, "/cosmos/bank/v1beta1/balances/\(strideAddress)")
    ]
    // Every registered chain must have an expectation, so adding a chain
    // without extending this test fails loudly.
    XCTAssertEqual(Set(expectations.keys), Set(ChainRegistry.allChains.map(\.id)))

    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      requests.append(request)
      // JSON-RPC batch bodies are arrays and must decode as arrays; every
      // other response model either tolerates an empty object or fails into a
      // per-chain warning after the request has already been captured.
      if let body = request.httpBody, body.first == UInt8(ascii: "[") {
        return scannerResponse(request, "[]")
      }
      return scannerResponse(request, "{}")
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    _ = try await scanner.scan(addresses: [
      bitcoinAddress, evmAddress, solanaAddress, tronAddress, xrpAddress,
      cosmosAddress, osmosisAddress, celestiaAddress, strideAddress
    ].joined(separator: "\n"))

    let captured = requests.snapshot().compactMap(\.url)
    XCTAssertFalse(captured.isEmpty)
    for chain in ChainRegistry.allChains {
      let expected = try XCTUnwrap(expectations[chain.id], chain.id)
      XCTAssertTrue(
        captured.contains { url in
          url.scheme == "https"
            && url.host == expected.host
            && url.port == expected.port
            && url.path == expected.path
        },
        "No captured request matched https://\(expected.host)\(expected.path) for \(chain.id)."
      )
    }
    let allowedHosts = Set(expectations.values.map(\.host))
    for url in captured {
      XCTAssertTrue(
        allowedHosts.contains(url.host ?? ""),
        "Unexpected request host: \(url.absoluteString)"
      )
    }
  }
}

private struct ScannerHTTPStub: HTTPClient, @unchecked Sendable {
  let handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try await handler(request)
  }
}

private struct ScannerStaticPriceProvider: PriceProviding {
  var values: [String: PricePoint]
  func prices(for coinGeckoIds: [String]) async throws -> [String: PricePoint] { values }
}

private struct ScannerFailingPriceProvider: PriceProviding {
  func prices(for coinGeckoIds: [String]) async throws -> [String: PricePoint] {
    throw URLError(.cannotConnectToHost)
  }
}

private struct ScannerSleepingPriceProvider: PriceProviding {
  func prices(for coinGeckoIds: [String]) async throws -> [String: PricePoint] {
    try await Task.sleep(nanoseconds: 5_000_000_000)
    return [:]
  }
}

private final class ScannerRequestLog: @unchecked Sendable {
  private let lock = NSLock()
  private var requests: [URLRequest] = []

  @discardableResult
  func append(_ request: URLRequest) -> Int {
    lock.lock()
    defer { lock.unlock() }
    requests.append(request)
    return requests.count
  }

  func snapshot() -> [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
}

private struct ScannerKrakenStateFixture {
  let directory: URL
  let stateURL: URL
  let secretStore: ScannerKrakenInstallationSecretStore

  func makeGenerator() -> KrakenNonceGenerator {
    KrakenNonceGenerator(
      storageURL: stateURL,
      installationSecretStore: secretStore
    )
  }
}

private enum ScannerKrakenSecretStoreFailure: Error {
  case unavailable
}

private final class ScannerKrakenInstallationSecretStore:
  KrakenInstallationSecretStore,
  @unchecked Sendable
{
  enum FailureMode: Equatable {
    case none
    case load
    case save
  }

  private let lock = NSLock()
  private var secret: Data?
  private var failureMode: FailureMode = .none

  init(secret: Data? = nil) {
    self.secret = secret
  }

  func loadSecret() throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    guard failureMode != .load else { throw ScannerKrakenSecretStoreFailure.unavailable }
    return secret
  }

  func saveSecretIfAbsent(_ candidate: Data) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard failureMode != .save else { throw ScannerKrakenSecretStoreFailure.unavailable }
    if let secret { return secret }
    secret = candidate
    return candidate
  }

  func setFailureMode(_ mode: FailureMode) {
    lock.lock()
    failureMode = mode
    lock.unlock()
  }

  func removeSecret() {
    lock.lock()
    secret = nil
    lock.unlock()
  }

  func snapshotSecret() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return secret
  }
}

private final class ScannerNonceSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String]

  init(_ values: [String]) { self.values = values }

  func next() -> String {
    lock.lock()
    defer { lock.unlock() }
    return values.isEmpty ? "fallback" : values.removeFirst()
  }
}

private actor ScannerConcurrencyProbe {
  private var active = 0
  private var highWaterMark = 0

  func enter() {
    active += 1
    highWaterMark = max(highWaterMark, active)
  }

  func leave() { active -= 1 }
  func maximum() -> Int { highWaterMark }
}

private final class ScannerSlowDripProbe: @unchecked Sendable {
  private let condition = NSCondition()
  private var started = false
  private var stopped = false

  func reset() {
    condition.lock()
    started = false
    stopped = false
    condition.unlock()
  }

  func markStarted() {
    condition.lock()
    started = true
    condition.broadcast()
    condition.unlock()
  }

  func markStopped() {
    condition.lock()
    stopped = true
    condition.broadcast()
    condition.unlock()
  }

  func waitForStart(timeout: TimeInterval) -> Bool {
    wait(timeout: timeout) { started }
  }

  func waitForStop(timeout: TimeInterval) -> Bool {
    wait(timeout: timeout) { stopped }
  }

  private func wait(timeout: TimeInterval, predicate: () -> Bool) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() {
      guard condition.wait(until: deadline) else { return predicate() }
    }
    return true
  }
}

private final class ScannerSlowDripURLProtocol: URLProtocol, @unchecked Sendable {
  static let probe = ScannerSlowDripProbe()

  private let stateLock = NSLock()
  private var stopped = false

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.probe.markStarted()
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["content-type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

    DispatchQueue.global().async { [weak self] in
      guard let self else { return }
      for _ in 0..<250 {
        Thread.sleep(forTimeInterval: 0.02)
        guard !self.isStopped else { return }
        self.client?.urlProtocol(self, didLoad: Data([0x20]))
      }
      guard !self.isStopped else { return }
      self.client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {
    stateLock.lock()
    stopped = true
    stateLock.unlock()
    Self.probe.markStopped()
  }

  private var isStopped: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return stopped
  }
}

private final class ScannerOversizedURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["content-type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(repeating: 0x61, count: 4))
    client?.urlProtocol(self, didLoad: Data(repeating: 0x62, count: 4))
    client?.urlProtocol(self, didLoad: Data(repeating: 0x63, count: 4))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class ScannerRedirectURLProtocol: URLProtocol, @unchecked Sendable {
  private static let destinationRequests = ScannerRequestLog()
  static var destinationRequestCount: Int { destinationRequests.snapshot().count }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    if request.url?.host == "redirect-origin.example" {
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 302,
        httpVersion: "HTTP/1.1",
        headerFields: ["location": "https://redirect-destination.example/secret"]
      )!
      let redirected = URLRequest(url: URL(string: "https://redirect-destination.example/secret")!)
      client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
      client?.urlProtocolDidFinishLoading(self)
      return
    }

    _ = Self.destinationRequests.append(request)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["content-type": "text/plain"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("redirect followed".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private func scannerPrivateKey() throws -> P256.Signing.PrivateKey {
  try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
}

private func scannerJSONObject(_ data: Data) throws -> [String: Any] {
  try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func scannerResponse(
  _ request: URLRequest,
  _ json: String,
  statusCode: Int = 200,
  headerFields: [String: String] = [:]
) -> (Data, HTTPURLResponse) {
  (Data(json.utf8), scannerHTTPResponse(request, statusCode: statusCode, headerFields: headerFields))
}

private func scannerHTTPResponse(
  _ request: URLRequest,
  statusCode: Int = 200,
  headerFields: [String: String] = [:]
) -> HTTPURLResponse {
  var headers = ["content-type": "application/json"]
  headers.merge(headerFields) { _, new in new }
  return HTTPURLResponse(
    url: request.url ?? URL(string: "https://example.com")!,
    statusCode: statusCode,
    httpVersion: "HTTP/1.1",
    headerFields: headers
  )!
}
