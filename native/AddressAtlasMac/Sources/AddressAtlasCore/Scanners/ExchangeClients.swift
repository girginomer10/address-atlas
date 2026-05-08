import Foundation

public struct ExchangeBalance: Equatable, Sendable {
  public var total: [String: Double]
  public var free: [String: Double]

  public init(total: [String: Double] = [:], free: [String: Double] = [:]) {
    self.total = total
    self.free = free
  }
}

public struct ExchangeScanResult: Sendable {
  public var holdings: [TrackedAsset]
  public var connections: [ExchangeConnectionRecord]
  public var warnings: [String]

  public init(holdings: [TrackedAsset], connections: [ExchangeConnectionRecord], warnings: [String] = []) {
    self.holdings = holdings
    self.connections = connections
    self.warnings = warnings
  }
}

public enum ExchangeClientError: Error, Equatable, LocalizedError, Sendable {
  case httpError(statusCode: Int, message: String)

  public var errorDescription: String? {
    switch self {
    case .httpError(let statusCode, let message):
      return "Exchange request failed (\(statusCode)): \(message)"
    }
  }
}

public struct NativeExchangeScanner: Sendable {
  private let client: NativeExchangeBalanceClient
  private let credentialVault: ExchangeCredentialVault
  private let priceProvider: PriceProviding

  public init(
    client: NativeExchangeBalanceClient = NativeExchangeBalanceClient(),
    credentialVault: ExchangeCredentialVault = ExchangeCredentialVault(),
    priceProvider: PriceProviding = CoinGeckoPriceClient()
  ) {
    self.client = client
    self.credentialVault = credentialVault
    self.priceProvider = priceProvider
  }

  public func scan(connections: [ExchangeConnectionRecord], vaultKey: Data) async -> ExchangeScanResult {
    var holdings: [TrackedAsset] = []
    var updatedConnections: [ExchangeConnectionRecord] = []
    var warnings: [String] = []

    for var connection in connections {
      do {
        let credentials = try credentialVault.open(connection.encryptedCredentials, vaultKey: vaultKey)
        let balance = try await client.fetchBalance(provider: connection.provider, credentials: credentials)
        let connectionHoldings = try await ExchangeBalanceNormalizer.normalize(
          balance: balance,
          id: connection.id,
          provider: connection.provider,
          label: connection.label,
          priceProvider: priceProvider
        )
        connection.status = .ok
        connection.lastSyncAt = Date()
        connection.lastTestedAt = Date()
        connection.lastError = nil
        connection.updatedAt = Date()
        holdings.append(contentsOf: connectionHoldings)
      } catch {
        connection.status = .failed
        connection.lastTestedAt = Date()
        connection.lastError = error.localizedDescription
        connection.updatedAt = Date()
        warnings.append("\(connection.label): \(error.localizedDescription)")
      }
      updatedConnections.append(connection)
    }

    return ExchangeScanResult(holdings: holdings, connections: updatedConnections, warnings: warnings)
  }
}

public struct NativeExchangeBalanceClient: Sendable {
  private let http: HTTPClient
  private let binanceBaseURL: URL
  private let coinbaseBaseURL: URL
  private let krakenBaseURL: URL
  private let now: @Sendable () -> Date

  public init(
    http: HTTPClient = URLSession.shared,
    endpointConfig: NativeEndpointConfig = .bundled,
    binanceBaseURL: URL? = nil,
    coinbaseBaseURL: URL? = nil,
    krakenBaseURL: URL? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.http = http
    self.binanceBaseURL = binanceBaseURL
      ?? endpointConfig.exchangeBaseURL(for: .binance)
      ?? URL(string: "https://api.binance.com")!
    self.coinbaseBaseURL = coinbaseBaseURL
      ?? endpointConfig.exchangeBaseURL(for: .coinbase)
      ?? URL(string: "https://api.coinbase.com")!
    self.krakenBaseURL = krakenBaseURL
      ?? endpointConfig.exchangeBaseURL(for: .kraken)
      ?? URL(string: "https://api.kraken.com")!
    self.now = now
  }

  public func fetchBalance(provider: ExchangeProvider, credentials: ExchangeCredentials) async throws -> ExchangeBalance {
    switch provider {
    case .binance:
      return try await fetchBinanceBalance(credentials: credentials)
    case .coinbase:
      return try await fetchCoinbaseBalance(credentials: credentials)
    case .kraken:
      return try await fetchKrakenBalance(credentials: credentials)
    }
  }

  private func fetchBinanceBalance(credentials: ExchangeCredentials) async throws -> ExchangeBalance {
    let timestampMs = Int64(now().timeIntervalSince1970 * 1000)
    let signed = ExchangeRequestSigner.binanceAccountRequest(credentials: credentials, timestampMs: timestampMs)
    let data = try await sendSignedRequest(signed, baseURL: binanceBaseURL)
    let response = try JSONDecoder.addressAtlas.decode(BinanceAccountResponse.self, from: data)
    var totals: [String: Double] = [:]
    var free: [String: Double] = [:]
    for balance in response.balances {
      let freeAmount = Double(balance.free) ?? 0
      let lockedAmount = Double(balance.locked) ?? 0
      let total = freeAmount + lockedAmount
      guard total > 0 else { continue }
      totals[ExchangeBalanceNormalizer.normalizeSymbol(balance.asset)] = total
      free[ExchangeBalanceNormalizer.normalizeSymbol(balance.asset)] = freeAmount
    }
    return ExchangeBalance(total: totals, free: free)
  }

  private func fetchCoinbaseBalance(credentials: ExchangeCredentials) async throws -> ExchangeBalance {
    let timestamp = String(format: "%.0f", now().timeIntervalSince1970)
    let signed = ExchangeRequestSigner.coinbaseAccountsRequest(credentials: credentials, timestamp: timestamp)
    let data = try await sendSignedRequest(signed, baseURL: coinbaseBaseURL)
    let response = try JSONDecoder.addressAtlas.decode(CoinbaseAccountsResponse.self, from: data)
    var totals: [String: Double] = [:]
    var free: [String: Double] = [:]
    for account in response.accounts ?? [] {
      let available = Double(account.availableBalance?.value ?? "0") ?? 0
      let hold = Double(account.hold?.value ?? "0") ?? 0
      let total = available + hold
      guard total > 0 else { continue }
      let symbol = ExchangeBalanceNormalizer.normalizeSymbol(account.currency)
      totals[symbol, default: 0] += total
      free[symbol, default: 0] += available
    }
    return ExchangeBalance(total: totals, free: free)
  }

  private func fetchKrakenBalance(credentials: ExchangeCredentials) async throws -> ExchangeBalance {
    let nonce = String(Int64(now().timeIntervalSince1970 * 1000))
    let signed = try ExchangeRequestSigner.krakenBalanceRequest(credentials: credentials, nonce: nonce)
    let data = try await sendSignedRequest(signed, baseURL: krakenBaseURL, contentType: "application/x-www-form-urlencoded")
    let response = try JSONDecoder.addressAtlas.decode(KrakenBalanceResponse.self, from: data)
    guard response.error.isEmpty else {
      throw NSError(
        domain: "AddressAtlas.Exchange.Kraken",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: response.error.joined(separator: ", ")]
      )
    }
    var totals: [String: Double] = [:]
    for (symbol, rawAmount) in response.result ?? [:] {
      let amount = Double(rawAmount) ?? 0
      guard amount > 0 else { continue }
      totals[ExchangeBalanceNormalizer.normalizeSymbol(symbol), default: 0] += amount
    }
    return ExchangeBalance(total: totals)
  }

  private func sendSignedRequest(
    _ signed: SignedExchangeRequest,
    baseURL: URL,
    contentType: String? = nil
  ) async throws -> Data {
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    components?.path = signed.path.hasPrefix("/") ? signed.path : "/\(signed.path)"
    if !signed.query.isEmpty {
      components?.percentEncodedQuery = signed.query
    }
    guard let url = components?.url else {
      throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = signed.method
    request.setValue("application/json", forHTTPHeaderField: "accept")
    if let contentType {
      request.setValue(contentType, forHTTPHeaderField: "content-type")
    }
    for (header, value) in signed.headers {
      request.setValue(value, forHTTPHeaderField: header)
    }
    if !signed.body.isEmpty {
      request.httpBody = Data(signed.body.utf8)
    }

    let (data, response) = try await http.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      throw ExchangeClientError.httpError(
        statusCode: response.statusCode,
        message: Self.responseMessage(from: data, statusCode: response.statusCode)
      )
    }
    return data
  }

  private static func responseMessage(from data: Data, statusCode: Int) -> String {
    let fallback = HTTPURLResponse.localizedString(forStatusCode: statusCode)
    guard !data.isEmpty else {
      return fallback
    }

    if
      let json = try? JSONSerialization.jsonObject(with: data),
      let message = jsonMessage(json)
    {
      return message
    }

    if let text = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
      return text
    }
    return fallback
  }

  private static func jsonMessage(_ value: Any) -> String? {
    if let dictionary = value as? [String: Any] {
      for key in ["msg", "message", "error", "reason", "detail"] {
        if let message = dictionary[key] as? String, !message.isEmpty {
          return message
        }
      }
      if
        let errors = dictionary["errors"] as? [Any],
        let message = errors.compactMap(jsonMessage).first
      {
        return message
      }
    }

    if let array = value as? [Any] {
      return array.compactMap(jsonMessage).first
    }

    return nil
  }
}

public enum ExchangeBalanceNormalizer {
  public static let usdStableSymbols: Set<String> = ["USD", "USDC", "USDT", "BUSD", "FDUSD", "TUSD", "USDP", "DAI"]

  public static let coinGeckoIds: [String: String] = [
    "AAVE": "aave",
    "ADA": "cardano",
    "ATOM": "cosmos",
    "AVAX": "avalanche-2",
    "BCH": "bitcoin-cash",
    "BNB": "binancecoin",
    "BTC": "bitcoin",
    "DAI": "dai",
    "DOGE": "dogecoin",
    "DOT": "polkadot",
    "ETH": "ethereum",
    "EURC": "euro-coin",
    "JUP": "jupiter-exchange-solana",
    "LINK": "chainlink",
    "LTC": "litecoin",
    "MATIC": "matic-network",
    "OP": "optimism",
    "OSMO": "osmosis",
    "POL": "polygon-ecosystem-token",
    "SOL": "solana",
    "STRD": "stride",
    "TIA": "celestia",
    "UNI": "uniswap",
    "USDC": "usd-coin",
    "USDT": "tether",
    "XLM": "stellar",
    "XRP": "ripple"
  ]

  public static func normalize(
    balance: ExchangeBalance,
    id: UUID,
    provider: ExchangeProvider,
    label: String,
    priceProvider: PriceProviding
  ) async throws -> [TrackedAsset] {
    let entries = balanceEntries(balance)
    let ids = entries.compactMap { symbol, _ in
      usdStableSymbols.contains(symbol) ? nil : coinGeckoIds[symbol]
    }
    let prices = try await priceProvider.prices(for: Array(Set(ids)))
    return normalize(balance: balance, id: id, provider: provider, label: label, prices: prices)
  }

  public static func normalize(
    balance: ExchangeBalance,
    id: UUID,
    provider: ExchangeProvider,
    label: String,
    prices: [String: PricePoint]
  ) -> [TrackedAsset] {
    balanceEntries(balance).map { symbol, amount in
      let coinId = coinGeckoIds[symbol]
      let price = pricePoint(symbol: symbol, coinId: coinId, prices: prices)
      return TrackedAsset(
        id: "\(id.uuidString)-\(provider.rawValue)-\(symbol)",
        address: label,
        chainId: provider.rawValue,
        chainName: provider.label,
        family: .exchange,
        symbol: symbol,
        name: symbol,
        amount: amount,
        priceUsd: price.usd,
        valueUsd: amount * price.usd,
        change24h: price.usd24hChange,
        explorerUrl: "",
        source: .exchange,
        walletLabel: label,
        exchangeId: id,
        exchangeProvider: provider
      )
    }
  }

  public static func balanceEntries(_ balance: ExchangeBalance) -> [(String, Double)] {
    let source = balance.total.isEmpty ? balance.free : balance.total
    return source
      .map { (normalizeSymbol($0.key), $0.value) }
      .filter { symbol, amount in
        !symbol.isEmpty && amount.isFinite && amount > 0
      }
      .sorted { $0.0 < $1.0 }
  }

  public static func normalizeSymbol(_ symbol: String) -> String {
    symbol
      .replacingOccurrences(of: "XXBT", with: "BTC", options: [.caseInsensitive])
      .replacingOccurrences(of: "XBT", with: "BTC", options: [.caseInsensitive])
      .replacingOccurrences(of: "ZEUR", with: "EUR", options: [.caseInsensitive])
      .replacingOccurrences(of: "ZUSD", with: "USD", options: [.caseInsensitive])
      .uppercased()
  }

  private static func pricePoint(symbol: String, coinId: String?, prices: [String: PricePoint]) -> PricePoint {
    if usdStableSymbols.contains(symbol) {
      return PricePoint(usd: 1, usd24hChange: 0)
    }
    if let coinId, let price = prices[coinId] {
      return price
    }
    return PricePoint(usd: 0)
  }
}

private struct BinanceAccountResponse: Decodable {
  var balances: [Balance]

  struct Balance: Decodable {
    var asset: String
    var free: String
    var locked: String
  }
}

private struct CoinbaseAccountsResponse: Decodable {
  var accounts: [Account]?

  struct Account: Decodable {
    var currency: String
    var availableBalance: Money?
    var hold: Money?

    enum CodingKeys: String, CodingKey {
      case currency
      case availableBalance = "available_balance"
      case hold
    }
  }

  struct Money: Decodable {
    var value: String
  }
}

private struct KrakenBalanceResponse: Decodable {
  var error: [String]
  var result: [String: String]?
}
