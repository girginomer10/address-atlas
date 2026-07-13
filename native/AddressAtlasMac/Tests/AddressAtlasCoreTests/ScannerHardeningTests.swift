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
    let mismatchedChain = CustomTokenRecord(
      chainKind: .solana,
      chainId: "ethereum",
      address: "11111111111111111111111111111111",
      symbol: "BADCHAIN",
      name: "Bad Chain",
      decimals: 9
    )

    let registries = NativeScanner.tokenRegistries(
      customTokens: [valid, invalidAddress, invalidDecimals, invalidPrice, mismatchedChain]
    )
    let added = registries.evm["ethereum"]?.first(where: { $0.symbol == "TEST" })

    XCTAssertEqual(added?.address, "0x0000000000000000000000000000000000000001")
    XCTAssertEqual(added?.coinGeckoId, "test-token")
    XCTAssertFalse(registries.evm["ethereum"]?.contains(where: { $0.symbol.hasPrefix("BAD") }) ?? true)
    XCTAssertEqual(registries.warnings.count, 4)
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
  func testPriceSanitizationDropsNonFiniteChangeWithoutDiscardingPrice() throws {
    let sanitized = try XCTUnwrap(
      CoinGeckoPriceClient.sanitized(PricePoint(usd: 42, usd24hChange: .infinity))
    )

    XCTAssertEqual(sanitized.usd, 42)
    XCTAssertNil(sanitized.usd24hChange)
    XCTAssertNil(CoinGeckoPriceClient.sanitized(PricePoint(usd: .infinity, usd24hChange: 1)))
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
  func testKrakenNonceGeneratorIsMonotonicPerAPIKeyAcrossConcurrencyAndClockRegression() async {
    let generator = KrakenNonceGenerator()
    let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    let concurrent = await withTaskGroup(of: String.self, returning: [String].self) { group in
      for _ in 0..<16 {
        group.addTask { await generator.next(apiKey: "same-key", at: baseDate) }
      }
      var values: [String] = []
      for await value in group { values.append(value) }
      return values
    }
    let sorted = concurrent.compactMap(Int64.init).sorted()
    let first = Int64(1_700_000_000_000)
    let regressed = await generator.next(apiKey: "same-key", at: baseDate.addingTimeInterval(-60))
    let otherKey = await generator.next(apiKey: "different-key", at: baseDate)

    XCTAssertEqual(sorted, Array(first..<(first + 16)))
    XCTAssertEqual(regressed, String(first + 16))
    XCTAssertEqual(otherKey, String(first))
  }

  func testDefaultKrakenNonceGeneratorIsSharedAcrossClientInstances() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      if request.url?.path == "/0/private/Balance" {
        return scannerResponse(request, #"{"error":[],"result":{}}"#)
      }
      return scannerResponse(request, #"{"error":[],"result":{}}"#)
    }
    let now: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }
    let firstClient = NativeExchangeBalanceClient(http: http, now: now)
    let secondClient = NativeExchangeBalanceClient(http: http, now: now)
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

  func testCoinbasePaginatesAccountsAndSignsEveryPage() async throws {
    let requests = ScannerRequestLog()
    let nonces = ScannerNonceSequence(["page-one", "page-two"])
    let http = ScannerHTTPStub { request in
      let call = requests.append(request)
      if call == 1 {
        return scannerResponse(
          request,
          #"{"accounts":[{"currency":"BTC","available_balance":{"value":"0.25"},"hold":{"value":"0.25"}}],"has_next":true,"cursor":"next-page"}"#
        )
      }
      return scannerResponse(
        request,
        #"{"accounts":[{"currency":"BTC","available_balance":{"value":"0.5"},"hold":{"value":"0"}},{"currency":"USDC","available_balance":{"value":"10"},"hold":{"value":"0"}}],"has_next":false}"#
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

  func testCoinbaseKeepsCompletedPagesWhenLaterPageFails() async throws {
    let requests = ScannerRequestLog()
    let nonces = ScannerNonceSequence(["page-one", "page-two"])
    let http = ScannerHTTPStub { request in
      let call = requests.append(request)
      if call == 1 {
        return scannerResponse(
          request,
          #"{"accounts":[{"currency":"BTC","available_balance":{"value":"0.5"},"hold":{"value":"0"}}],"has_next":true,"cursor":"next-page"}"#
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

  func testKrakenUsesAssetMetadataAndPreservesFiatAsUnpriced() async throws {
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
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
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
}

final class ScannerWorkflowTests: XCTestCase {
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
        ExchangeCredentials(apiKey: "key", secret: "secret"),
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
