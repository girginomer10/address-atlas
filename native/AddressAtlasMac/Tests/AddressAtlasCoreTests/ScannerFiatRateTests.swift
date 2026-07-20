import CryptoKit
import Foundation
import XCTest

@testable import AddressAtlasCore

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

  func testExchangeAdditionAndValuationOverflowFailClosedWithoutNonFinitePersistence() async throws
  {
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
    XCTAssertNoThrow(
      try JSONEncoder.addressAtlas.encode(
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
    XCTAssertFalse(
      result.warnings.contains(where: {
        $0.lowercased().contains("fiat") || $0.contains("conversion rate")
      }))
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
    XCTAssertTrue(
      result.warnings.contains(where: { $0.contains("Fiat-to-USD rates") && $0.contains("EUR") }))
  }
}
