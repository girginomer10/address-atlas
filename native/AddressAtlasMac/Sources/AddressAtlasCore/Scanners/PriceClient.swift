import Foundation

public struct PricePoint: Codable, Equatable, Sendable {
  public var usd: Double
  public var usd24hChange: Double?

  enum CodingKeys: String, CodingKey {
    case usd
    case usd24hChange = "usd_24h_change"
  }

  public init(usd: Double, usd24hChange: Double? = nil) {
    self.usd = usd
    self.usd24hChange = usd24hChange
  }
}

public protocol PriceProviding: Sendable {
  func prices(for coinGeckoIds: [String]) async throws -> [String: PricePoint]
  func usdRates(forFiatSymbols symbols: [String]) async throws -> [String: Double]
}

public extension PriceProviding {
  /// Existing price providers remain source-compatible. Returning no rates is
  /// treated as an explicit "unpriced fiat" result by exchange normalization.
  func usdRates(forFiatSymbols symbols: [String]) async throws -> [String: Double] {
    [:]
  }
}

public enum PriceClientError: Error, Equatable, LocalizedError, Sendable {
  case requestFailed(String)

  public var errorDescription: String? {
    switch self {
    case .requestFailed(let message):
      return "Price lookup failed: \(message)"
    }
  }
}

public enum FiatRateError: Error, Equatable, LocalizedError, Sendable {
  case invalidEndpoint
  case invalidResponse

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      return "The CoinGecko exchange-rate endpoint is invalid."
    case .invalidResponse:
      return "CoinGecko returned invalid BTC-relative fiat rates."
    }
  }
}

public struct CoinGeckoPriceClient: PriceProviding {
  private let http: JSONHTTPClient
  private let baseURL: URL

  public init(baseURL: URL = NativeEndpointConfig.bundled.priceBaseURL, http: JSONHTTPClient = JSONHTTPClient()) {
    self.baseURL = baseURL
    self.http = http
  }

  public func prices(for coinGeckoIds: [String]) async throws -> [String: PricePoint] {
    let ids = Array(Set(coinGeckoIds.filter { !$0.isEmpty })).sorted()
    guard !ids.isEmpty else { return [:] }
    var merged: [String: PricePoint] = [:]
    var failures: [String] = []

    // Keep request URLs bounded. If one batch fails, retain successful prices so
    // scanners can still value part of the portfolio and flag only missing assets.
    for start in stride(from: 0, to: ids.count, by: 100) {
      try Task.checkCancellation()
      let batch = Array(ids[start..<min(start + 100, ids.count)])
      do {
        let response: [String: PricePoint] = try await withWorkflowTimeout(seconds: 20) {
          var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
          components.queryItems = [
            URLQueryItem(name: "ids", value: batch.joined(separator: ",")),
            URLQueryItem(name: "vs_currencies", value: "usd"),
            URLQueryItem(name: "include_24hr_change", value: "true")
          ]
          return try await http.get(components.url!, as: [String: PricePoint].self)
        }
        for (id, point) in response where point.usd.isFinite && point.usd >= 0 {
          merged[id] = point
        }
      } catch {
        try throwIfCancellation(error)
        failures.append(error.localizedDescription)
      }
    }

    if merged.isEmpty, let firstFailure = failures.first {
      throw PriceClientError.requestFailed(firstFailure)
    }
    return merged
  }

  public func usdRates(forFiatSymbols symbols: [String]) async throws -> [String: Double] {
    let requested = Set(symbols.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() })
      .subtracting(["USD", ""])
    guard !requested.isEmpty else { return [:] }
    let url = try exchangeRatesURL()
    let response: CoinGeckoExchangeRatesResponse = try await withWorkflowTimeout(seconds: 20) {
      try await http.get(url, as: CoinGeckoExchangeRatesResponse.self)
    }
    guard let usd = response.rates["usd"],
          usd.type.lowercased() == "fiat",
          usd.value.isFinite,
          usd.value > 0
    else {
      throw FiatRateError.invalidResponse
    }

    // CoinGecko reports each value as units of that currency per BTC. Dividing
    // USD-per-BTC by fiat-per-BTC yields USD per one unit of the fiat currency.
    var rates: [String: Double] = [:]
    for symbol in requested {
      guard let fiat = response.rates[symbol.lowercased()],
            fiat.type.lowercased() == "fiat",
            fiat.value.isFinite,
            fiat.value > 0
      else { continue }
      let usdPerUnit = usd.value / fiat.value
      if usdPerUnit.isFinite, usdPerUnit > 0 {
        rates[symbol] = usdPerUnit
      }
    }
    return rates
  }

  private func exchangeRatesURL() throws -> URL {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
          let pinned = URLComponents(url: NativeEndpointConfig.bundled.priceBaseURL, resolvingAgainstBaseURL: false),
          components.scheme?.lowercased() == "https",
          components.scheme?.lowercased() == pinned.scheme?.lowercased(),
          components.host?.lowercased() == pinned.host?.lowercased(),
          (components.port ?? 443) == (pinned.port ?? 443),
          components.user == nil,
          components.password == nil
    else {
      throw FiatRateError.invalidEndpoint
    }
    components.path = "/api/v3/exchange_rates"
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { throw FiatRateError.invalidEndpoint }
    return url
  }
}

public struct StaticPriceProvider: PriceProviding {
  public var values: [String: PricePoint]
  public var fiatUsdRates: [String: Double]

  public init(values: [String: PricePoint], fiatUsdRates: [String: Double] = [:]) {
    self.values = values
    self.fiatUsdRates = fiatUsdRates
  }

  public func prices(for coinGeckoIds: [String]) async throws -> [String: PricePoint] {
    values.filter { coinGeckoIds.contains($0.key) }
  }

  public func usdRates(forFiatSymbols symbols: [String]) async throws -> [String: Double] {
    let requested = Set(symbols.map { $0.uppercased() })
    return fiatUsdRates.reduce(into: [:]) { result, entry in
      let symbol = entry.key.uppercased()
      guard requested.contains(symbol), entry.value.isFinite, entry.value > 0 else { return }
      result[symbol] = entry.value
    }
  }
}

private struct CoinGeckoExchangeRatesResponse: Decodable, Sendable {
  var rates: [String: Rate]

  struct Rate: Decodable, Sendable {
    var value: Double
    var type: String
  }
}
