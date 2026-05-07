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
}

public struct CoinGeckoPriceClient: PriceProviding {
  private let http: JSONHTTPClient

  public init(http: JSONHTTPClient = JSONHTTPClient()) {
    self.http = http
  }

  public func prices(for coinGeckoIds: [String]) async throws -> [String: PricePoint] {
    let ids = Array(Set(coinGeckoIds.filter { !$0.isEmpty })).sorted()
    guard !ids.isEmpty else { return [:] }
    var components = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
    components.queryItems = [
      URLQueryItem(name: "ids", value: ids.joined(separator: ",")),
      URLQueryItem(name: "vs_currencies", value: "usd"),
      URLQueryItem(name: "include_24hr_change", value: "true")
    ]
    return try await http.get(components.url!, as: [String: PricePoint].self)
  }
}

public struct StaticPriceProvider: PriceProviding {
  public var values: [String: PricePoint]

  public init(values: [String: PricePoint]) {
    self.values = values
  }

  public func prices(for coinGeckoIds: [String]) async throws -> [String: PricePoint] {
    values.filter { coinGeckoIds.contains($0.key) }
  }
}
