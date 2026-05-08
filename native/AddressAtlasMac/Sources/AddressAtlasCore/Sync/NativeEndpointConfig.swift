import Foundation

public struct NativeEndpointConfig: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var configVersion: Int
  public var updatedAt: Date?
  public var refreshAfterSeconds: Int
  public var minSupportedAppVersion: String?
  public var message: String?
  public var priceBaseURL: URL
  public var chains: [String: ChainEndpointOverride]
  public var exchanges: [String: ExchangeEndpointOverride]

  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case configVersion
    case updatedAt
    case refreshAfterSeconds
    case minSupportedAppVersion
    case message
    case priceBaseURL = "priceBaseUrl"
    case chains
    case exchanges
  }

  public init(
    schemaVersion: Int = 1,
    configVersion: Int = 1,
    updatedAt: Date? = nil,
    refreshAfterSeconds: Int = 21_600,
    minSupportedAppVersion: String? = nil,
    message: String? = nil,
    priceBaseURL: URL = URL(string: "https://api.coingecko.com/api/v3/simple/price")!,
    chains: [String: ChainEndpointOverride] = [:],
    exchanges: [String: ExchangeEndpointOverride] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.configVersion = configVersion
    self.updatedAt = updatedAt
    self.refreshAfterSeconds = refreshAfterSeconds
    self.minSupportedAppVersion = minSupportedAppVersion
    self.message = message
    self.priceBaseURL = priceBaseURL
    self.chains = chains
    self.exchanges = exchanges
  }

  public static let bundled = NativeEndpointConfig(
    chains: [
      "bitcoin": ChainEndpointOverride(restURL: URL(string: "https://blockstream.info/api")),
      "solana": ChainEndpointOverride(rpcURL: URL(string: "https://api.mainnet-beta.solana.com")),
      "tron": ChainEndpointOverride(restURL: URL(string: "https://api.trongrid.io")),
      "xrp": ChainEndpointOverride(rpcURL: URL(string: "https://s1.ripple.com:51234/")),
      "ethereum": ChainEndpointOverride(rpcURL: URL(string: "https://eth.llamarpc.com")),
      "base": ChainEndpointOverride(rpcURL: URL(string: "https://mainnet.base.org")),
      "arbitrum": ChainEndpointOverride(rpcURL: URL(string: "https://arb1.arbitrum.io/rpc")),
      "optimism": ChainEndpointOverride(rpcURL: URL(string: "https://mainnet.optimism.io")),
      "polygon": ChainEndpointOverride(rpcURL: URL(string: "https://polygon-rpc.com")),
      "bsc": ChainEndpointOverride(rpcURL: URL(string: "https://bsc-dataseed.binance.org")),
      "avalanche": ChainEndpointOverride(rpcURL: URL(string: "https://api.avax.network/ext/bc/C/rpc")),
      "cosmoshub": ChainEndpointOverride(restURL: URL(string: "https://cosmos-api.polkachu.com")),
      "osmosis": ChainEndpointOverride(restURL: URL(string: "https://lcd.osmosis.zone")),
      "celestia": ChainEndpointOverride(restURL: URL(string: "https://celestia-api.polkachu.com")),
      "stargaze": ChainEndpointOverride(restURL: URL(string: "https://rest.stargaze-apis.com")),
      "stride": ChainEndpointOverride(restURL: URL(string: "https://stride-api.polkachu.com"))
    ],
    exchanges: [
      ExchangeProvider.binance.rawValue: ExchangeEndpointOverride(baseURL: URL(string: "https://api.binance.com")!),
      ExchangeProvider.coinbase.rawValue: ExchangeEndpointOverride(baseURL: URL(string: "https://api.coinbase.com")!),
      ExchangeProvider.kraken.rawValue: ExchangeEndpointOverride(baseURL: URL(string: "https://api.kraken.com")!)
    ]
  )

  public func applying(to chain: ChainConfig) -> ChainConfig {
    guard let override = chains[chain.id] else { return chain }
    var updated = chain
    updated.rpcUrl = override.rpcURL ?? chain.rpcUrl
    updated.restUrl = override.restURL ?? chain.restUrl
    updated.explorerUrl = override.explorerURL ?? chain.explorerUrl
    return updated
  }

  public func exchangeBaseURL(for provider: ExchangeProvider) -> URL? {
    exchanges[provider.rawValue]?.baseURL
  }
}

public struct ChainEndpointOverride: Codable, Equatable, Sendable {
  public var rpcURL: URL?
  public var restURL: URL?
  public var explorerURL: URL?

  enum CodingKeys: String, CodingKey {
    case rpcURL = "rpcUrl"
    case restURL = "restUrl"
    case explorerURL = "explorerUrl"
  }

  public init(rpcURL: URL? = nil, restURL: URL? = nil, explorerURL: URL? = nil) {
    self.rpcURL = rpcURL
    self.restURL = restURL
    self.explorerURL = explorerURL
  }
}

public struct ExchangeEndpointOverride: Codable, Equatable, Sendable {
  public var baseURL: URL

  enum CodingKeys: String, CodingKey {
    case baseURL = "baseUrl"
  }

  public init(baseURL: URL) {
    self.baseURL = baseURL
  }
}

public enum NativeEndpointConfigError: Error, Equatable, LocalizedError {
  case invalidSchema
  case requestFailed(Int, String)

  public var errorDescription: String? {
    switch self {
    case .invalidSchema:
      return "Endpoint config is not supported by this app version."
    case .requestFailed(_, let message):
      return message
    }
  }
}

public struct NativeEndpointConfigClient: Sendable {
  private let http: HTTPClient

  public init(http: HTTPClient = URLSession.shared) {
    self.http = http
  }

  public func fetch(from serverURL: URL) async throws -> NativeEndpointConfig {
    var request = URLRequest(url: serverURL.appending(path: "config/native"))
    request.setValue("application/json", forHTTPHeaderField: "accept")
    let (data, response) = try await http.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      throw NativeEndpointConfigError.requestFailed(
        response.statusCode,
        HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
      )
    }
    let config = try JSONDecoder.addressAtlas.decode(NativeEndpointConfig.self, from: data)
    guard config.schemaVersion == 1 else {
      throw NativeEndpointConfigError.invalidSchema
    }
    return config
  }
}
