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
    configVersion: 2,
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
      "gnosis": ChainEndpointOverride(rpcURL: URL(string: "https://rpc.gnosischain.com")),
      "linea": ChainEndpointOverride(rpcURL: URL(string: "https://rpc.linea.build")),
      "mantle": ChainEndpointOverride(rpcURL: URL(string: "https://rpc.mantle.xyz")),
      "scroll": ChainEndpointOverride(rpcURL: URL(string: "https://rpc.scroll.io")),
      "zksync-era": ChainEndpointOverride(rpcURL: URL(string: "https://mainnet.era.zksync.io")),
      "cosmoshub": ChainEndpointOverride(restURL: URL(string: "https://cosmos-api.polkachu.com")),
      "osmosis": ChainEndpointOverride(restURL: URL(string: "https://lcd.osmosis.zone")),
      "celestia": ChainEndpointOverride(restURL: URL(string: "https://celestia-api.polkachu.com")),
      "stargaze": ChainEndpointOverride(restURL: URL(string: "https://rest.stargaze-apis.com")),
      "stride": ChainEndpointOverride(restURL: URL(string: "https://stride-api.polkachu.com"))
    ],
    exchanges: [
      ExchangeProvider.binance.rawValue: ExchangeEndpointOverride(baseURL: URL(string: "https://api.binance.com")!, accountPath: "/api/v3/account"),
      ExchangeProvider.coinbase.rawValue: ExchangeEndpointOverride(baseURL: URL(string: "https://api.coinbase.com")!, accountPath: "/api/v3/brokerage/accounts"),
      ExchangeProvider.kraken.rawValue: ExchangeEndpointOverride(baseURL: URL(string: "https://api.kraken.com")!, accountPath: "/0/private/Balance")
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

  public func exchangeAccountPath(for provider: ExchangeProvider) -> String? {
    exchanges[provider.rawValue]?.accountPath
  }

  public func validated() throws -> NativeEndpointConfig {
    try Self.validateHTTPURL(priceBaseURL, field: "priceBaseUrl")
    for (chainId, override) in chains {
      try Self.validateHTTPURL(override.rpcURL, field: "\(chainId).rpcUrl")
      try Self.validateHTTPURL(override.restURL, field: "\(chainId).restUrl")
      try Self.validateHTTPURL(override.explorerURL, field: "\(chainId).explorerUrl")
    }
    for (provider, override) in exchanges {
      try Self.validateHTTPSURL(override.baseURL, field: "\(provider).baseUrl")
      try Self.validatePath(override.accountPath, field: "\(provider).accountPath")
    }
    return self
  }

  private static func validateHTTPURL(_ url: URL?, field: String) throws {
    guard let url else { return }
    let scheme = url.scheme?.lowercased()
    guard scheme == "https" || scheme == "http" else {
      throw NativeEndpointConfigError.invalidEndpoint(field)
    }
  }

  private static func validateHTTPSURL(_ url: URL?, field: String) throws {
    guard let url else { return }
    guard url.scheme?.lowercased() == "https" else {
      throw NativeEndpointConfigError.invalidEndpoint(field)
    }
  }

  private static func validatePath(_ path: String?, field: String) throws {
    guard let path else { return }
    guard path.hasPrefix("/"), !path.contains("://") else {
      throw NativeEndpointConfigError.invalidEndpoint(field)
    }
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
  public var accountPath: String?

  enum CodingKeys: String, CodingKey {
    case baseURL = "baseUrl"
    case accountPath
  }

  public init(baseURL: URL, accountPath: String? = nil) {
    self.baseURL = baseURL
    self.accountPath = accountPath
  }
}

public enum NativeEndpointConfigError: Error, Equatable, LocalizedError {
  case invalidSchema
  case invalidEndpoint(String)
  case requestFailed(Int, String)

  public var errorDescription: String? {
    switch self {
    case .invalidSchema:
      return "Endpoint config is not supported by this app version."
    case .invalidEndpoint(let field):
      return "Endpoint config contains an invalid URL or path: \(field)."
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
    return try config.validated()
  }
}
