import Foundation

public struct NativeEndpointConfig: Codable, Equatable, Sendable {
  public static let minimumRefreshAfterSeconds = 300
  public static let maximumRefreshAfterSeconds = 86_400
  public static let maximumAppVersionComponent = 2_000_000_000
  private static let minimumAppVersionComponents = 2
  private static let maximumAppVersionComponents = 4
  private static let maximumAppVersionComponentDigits = 10

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
    configVersion: 3,
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
    switch provider {
    case .binance: URL(string: "https://api.binance.com")
    case .coinbase: URL(string: "https://api.coinbase.com")
    case .kraken: URL(string: "https://api.kraken.com")
    }
  }

  public func exchangeAccountPath(for provider: ExchangeProvider) -> String? {
    switch provider {
    case .binance: "/api/v3/account"
    case .coinbase: "/api/v3/brokerage/accounts"
    case .kraken: "/0/private/Balance"
    }
  }

  public func validated() throws -> NativeEndpointConfig {
    guard (Self.minimumRefreshAfterSeconds...Self.maximumRefreshAfterSeconds).contains(refreshAfterSeconds) else {
      throw NativeEndpointConfigError.invalidRefreshInterval
    }
    if let minSupportedAppVersion,
       Self.appVersionComponents(minSupportedAppVersion) == nil {
      throw NativeEndpointConfigError.invalidMinimumAppVersion
    }
    try Self.validateRemoteURL(
      priceBaseURL,
      matching: Self.bundled.priceBaseURL,
      field: "priceBaseUrl",
      requiresExactPath: true
    )
    for (chainId, override) in chains {
      guard let bundled = Self.bundled.chains[chainId] else {
        throw NativeEndpointConfigError.invalidEndpoint(chainId)
      }
      try Self.validateRemoteURL(
        override.rpcURL,
        matching: bundled.rpcURL,
        field: "\(chainId).rpcUrl"
      )
      try Self.validateRemoteURL(
        override.restURL,
        matching: bundled.restURL,
        field: "\(chainId).restUrl"
      )
      try Self.validateRemoteURL(
        override.explorerURL,
        matching: bundled.explorerURL,
        field: "\(chainId).explorerUrl"
      )
    }
    // Exchange requests carry live API credentials/signatures. Their host,
    // method and path are a local trust boundary and can never be delegated to
    // a remotely supplied config document.
    guard exchanges.isEmpty else {
      throw NativeEndpointConfigError.invalidEndpoint("exchanges")
    }
    return self
  }

  /// Bounded dotted-numeric grammar shared with the sync server. Returning nil
  /// is security-significant: callers enforcing a minimum version fail closed.
  public static func appVersionComponents(_ version: String) -> [Int]? {
    let components = version.split(separator: ".", omittingEmptySubsequences: false)
    guard (minimumAppVersionComponents...maximumAppVersionComponents).contains(components.count) else {
      return nil
    }

    var parsed: [Int] = []
    parsed.reserveCapacity(components.count)
    for component in components {
      guard !component.isEmpty,
            component.count <= maximumAppVersionComponentDigits,
            component.utf8.allSatisfy({ (48...57).contains($0) }),
            let value = Int(component),
            (0...maximumAppVersionComponent).contains(value)
      else {
        return nil
      }
      parsed.append(value)
    }
    return parsed
  }

  private static func validateRemoteURL(
    _ url: URL?,
    matching bundledURL: URL?,
    field: String,
    requiresExactPath: Bool = false
  ) throws {
    guard let url else { return }
    guard let bundledURL,
          let scheme = url.scheme?.lowercased(), scheme == "https",
          let host = url.host?.lowercased(), !host.isEmpty,
          scheme == bundledURL.scheme?.lowercased(),
          host == bundledURL.host?.lowercased(),
          effectivePort(for: url) == effectivePort(for: bundledURL),
          url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
          !requiresExactPath || normalizedPath(url) == normalizedPath(bundledURL)
    else {
      throw NativeEndpointConfigError.invalidEndpoint(field)
    }
  }

  private static func effectivePort(for url: URL) -> Int? {
    if let port = url.port { return port }
    switch url.scheme?.lowercased() {
    case "https": return 443
    case "http": return 80
    default: return nil
    }
  }

  private static func normalizedPath(_ url: URL) -> String {
    let path = url.path.isEmpty ? "/" : url.path
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }

  private static func validateHTTPURL(_ url: URL?, field: String) throws {
    guard let url else { return }
    let scheme = url.scheme?.lowercased()
    guard let host = url.host?.lowercased(), !host.isEmpty,
          url.user == nil, url.password == nil, url.fragment == nil
    else {
      throw NativeEndpointConfigError.invalidEndpoint(field)
    }
    if scheme == "https" { return }
    // Permit plaintext http only for a local node; remote endpoints must be https.
    if scheme == "http",
       host == "localhost" || host == "127.0.0.1" || host == "::1" {
      return
    }
    throw NativeEndpointConfigError.invalidEndpoint(field)
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
  case invalidRefreshInterval
  case invalidMinimumAppVersion
  case invalidEndpoint(String)
  case requestFailed(Int, String)

  public var errorDescription: String? {
    switch self {
    case .invalidSchema:
      return "Endpoint config is not supported by this app version."
    case .invalidRefreshInterval:
      return "Endpoint config contains an invalid refresh interval."
    case .invalidMinimumAppVersion:
      return "Endpoint config contains an invalid minimum app version."
    case .invalidEndpoint(let field):
      return "Endpoint config contains an invalid URL or path: \(field)."
    case .requestFailed(_, let message):
      return message
    }
  }
}

public struct NativeEndpointConfigClient: Sendable {
  private let http: HTTPClient

  public init(http: HTTPClient? = nil) {
    self.http = http ?? BoundedURLSessionHTTPClient(maxResponseBytes: 1_000_000)
  }

  public func fetch(from serverURL: URL) async throws -> NativeEndpointConfig {
    try NativeEndpointConfig.validateServerURL(serverURL)
    var request = URLRequest(url: serverURL.appending(path: "config/native"))
    request.timeoutInterval = 20
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

extension NativeEndpointConfig {
  fileprivate static func validateServerURL(_ url: URL) throws {
    try validateHTTPURL(url, field: "serverUrl")
  }
}
