import Foundation

public struct ExchangeBalance: Equatable, Sendable {
  public var total: [String: Double]
  public var free: [String: Double]
  public var warnings: [String]

  public init(total: [String: Double] = [:], free: [String: Double] = [:], warnings: [String] = []) {
    self.total = total
    self.free = free
    self.warnings = warnings
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
  case invalidResponse(String)
  case paginationLimit(provider: String, pages: Int)

  public var errorDescription: String? {
    switch self {
    case .httpError(let statusCode, let message):
      return "Exchange request failed (\(statusCode)): \(message)"
    case .invalidResponse(let message):
      return "Exchange returned invalid data: \(message)"
    case .paginationLimit(let provider, let pages):
      return "\(provider) pagination exceeded the \(pages)-page safety limit."
    }
  }
}

public struct NativeExchangeScanner: Sendable {
  private let client: NativeExchangeBalanceClient
  private let credentialVault: ExchangeCredentialVault
  private let priceProvider: PriceProviding
  private let maxConcurrentConnections: Int
  private let connectionDeadline: TimeInterval
  private let workflowDeadline: TimeInterval

  public init(
    client: NativeExchangeBalanceClient = NativeExchangeBalanceClient(),
    credentialVault: ExchangeCredentialVault = ExchangeCredentialVault(),
    priceProvider: PriceProviding = CoinGeckoPriceClient(),
    maxConcurrentConnections: Int = 3,
    connectionDeadline: TimeInterval = 45,
    workflowDeadline: TimeInterval = 120
  ) {
    self.client = client
    self.credentialVault = credentialVault
    self.priceProvider = priceProvider
    self.maxConcurrentConnections = max(1, maxConcurrentConnections)
    self.connectionDeadline = connectionDeadline.isFinite && connectionDeadline > 0 ? connectionDeadline : 45
    self.workflowDeadline = workflowDeadline.isFinite && workflowDeadline > 0 ? workflowDeadline : 120
  }

  /// Compatibility wrapper. New call sites should use `scanThrowing` so task
  /// cancellation reaches the caller rather than becoming a user-facing warning.
  public func scan(connections: [ExchangeConnectionRecord], vaultKey: Data) async -> ExchangeScanResult {
    do {
      return try await scanThrowing(connections: connections, vaultKey: vaultKey)
    } catch {
      return ExchangeScanResult(
        holdings: [],
        connections: connections,
        warnings: [error is CancellationError ? "Exchange scan cancelled." : error.localizedDescription]
      )
    }
  }

  public func scanThrowing(connections: [ExchangeConnectionRecord], vaultKey: Data) async throws -> ExchangeScanResult {
    let jobs = connections.enumerated().map { ExchangeConnectionJob(index: $0.offset, connection: $0.element) }
    guard !jobs.isEmpty else { return ExchangeScanResult(holdings: [], connections: []) }
    let collector = CompletedWorkCollector<IndexedExchangeConnectionOutcome>()
    let completed: [IndexedExchangeConnectionOutcome]
    var globalWarnings: [String] = []
    do {
      completed = try await withWorkflowTimeout(seconds: workflowDeadline) {
        try await boundedConcurrentMap(jobs, maxConcurrent: maxConcurrentConnections) { job in
          let outcome: ExchangeConnectionOutcome
          do {
            outcome = try await withWorkflowTimeout(seconds: connectionDeadline) {
              try await scanConnection(job.connection, vaultKey: vaultKey)
            }
          } catch {
            try throwIfCancellation(error)
            let safeError = ProviderErrorSanitizer.sanitize(error.localizedDescription)
            var failed = job.connection
            failed.status = .failed
            failed.lastTestedAt = Date()
            failed.lastError = safeError
            failed.updatedAt = Date()
            outcome = ExchangeConnectionOutcome(
              connection: failed,
              warnings: [ProviderErrorSanitizer.sanitize("\(job.connection.label): \(safeError)")]
            )
          }
          let indexed = IndexedExchangeConnectionOutcome(index: job.index, outcome: outcome)
          await collector.append(indexed)
          return indexed
        }
      }
    } catch is WorkflowTimeoutError {
      completed = await collector.snapshot()
      let skipped = max(0, jobs.count - completed.count)
      globalWarnings.append(
        "The overall exchange scan reached its \(Int(workflowDeadline))-second deadline; \(skipped) unfinished connections were skipped and completed results were kept."
      )
    } catch {
      try throwIfCancellation(error)
      throw error
    }

    let completedByIndex = Dictionary(uniqueKeysWithValues: completed.map { ($0.index, $0.outcome) })
    let outcomes = jobs.map { job -> ExchangeConnectionOutcome in
      if let completed = completedByIndex[job.index] { return completed }
      return ExchangeConnectionOutcome(
        connection: job.connection,
        warnings: ["\(job.connection.label): not scanned before the overall deadline."]
      )
    }

    return ExchangeScanResult(
      holdings: outcomes.flatMap(\.holdings),
      connections: outcomes.map(\.connection),
      warnings: globalWarnings + outcomes.flatMap(\.warnings)
    )
  }

  private func scanConnection(
    _ original: ExchangeConnectionRecord,
    vaultKey: Data
  ) async throws -> ExchangeConnectionOutcome {
    var connection = original
    let credentials = try credentialVault.open(connection.encryptedCredentials, vaultKey: vaultKey)
    let balance = try await client.fetchBalance(provider: connection.provider, credentials: credentials)
    let normalized = try await ExchangeBalanceNormalizer.normalizeWithWarnings(
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
    return ExchangeConnectionOutcome(
      connection: connection,
      holdings: normalized.holdings,
      warnings: normalized.warnings.map {
        ProviderErrorSanitizer.sanitize("\(connection.label): \($0)")
      }
    )
  }
}

private struct ExchangeConnectionOutcome: Sendable {
  var connection: ExchangeConnectionRecord
  var holdings: [TrackedAsset] = []
  var warnings: [String] = []
}

private struct ExchangeConnectionJob: Sendable {
  var index: Int
  var connection: ExchangeConnectionRecord
}

private struct IndexedExchangeConnectionOutcome: Sendable {
  var index: Int
  var outcome: ExchangeConnectionOutcome
}

public actor KrakenNonceGenerator {
  public static let shared = KrakenNonceGenerator()
  private var lastNonceByAPIKey: [String: Int64] = [:]

  public init() {}

  func next(apiKey: String, at date: Date) -> String {
    let rawMilliseconds = date.timeIntervalSince1970 * 1_000
    let currentMilliseconds: Int64
    if !rawMilliseconds.isFinite || rawMilliseconds <= 0 {
      currentMilliseconds = 0
    } else if rawMilliseconds >= Double(Int64.max) {
      currentMilliseconds = Int64.max
    } else {
      currentMilliseconds = Int64(rawMilliseconds.rounded(.down))
    }

    let next: Int64
    if let previous = lastNonceByAPIKey[apiKey], previous >= currentMilliseconds {
      next = previous == Int64.max ? Int64.max : previous + 1
    } else {
      next = currentMilliseconds
    }
    lastNonceByAPIKey[apiKey] = next
    return String(next)
  }
}

public struct NativeExchangeBalanceClient: Sendable {
  private let http: HTTPClient
  private let binanceBaseURL: URL
  private let coinbaseBaseURL: URL
  private let krakenBaseURL: URL
  private let binanceAccountPath: String
  private let coinbaseAccountsPath: String
  private let krakenBalancePath: String
  private let now: @Sendable () -> Date
  private let jwtNonce: @Sendable () -> String
  private let maxCoinbasePages: Int
  private let krakenNonceGenerator: KrakenNonceGenerator

  public init(
    http: HTTPClient? = nil,
    endpointConfig: NativeEndpointConfig = .bundled,
    binanceBaseURL: URL? = nil,
    coinbaseBaseURL: URL? = nil,
    krakenBaseURL: URL? = nil,
    binanceAccountPath: String? = nil,
    coinbaseAccountsPath: String? = nil,
    krakenBalancePath: String? = nil,
    now: @escaping @Sendable () -> Date = { Date() },
    jwtNonce: @escaping @Sendable () -> String = { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() },
    maxCoinbasePages: Int = 20,
    krakenNonceGenerator: KrakenNonceGenerator = .shared
  ) {
    self.http = http ?? BoundedURLSessionHTTPClient(maxResponseBytes: 8_000_000)
    self.binanceBaseURL = binanceBaseURL
      ?? endpointConfig.exchangeBaseURL(for: .binance)
      ?? URL(string: "https://api.binance.com")!
    self.coinbaseBaseURL = coinbaseBaseURL
      ?? endpointConfig.exchangeBaseURL(for: .coinbase)
      ?? URL(string: "https://api.coinbase.com")!
    self.krakenBaseURL = krakenBaseURL
      ?? endpointConfig.exchangeBaseURL(for: .kraken)
      ?? URL(string: "https://api.kraken.com")!
    self.binanceAccountPath = binanceAccountPath
      ?? endpointConfig.exchangeAccountPath(for: .binance)
      ?? "/api/v3/account"
    self.coinbaseAccountsPath = coinbaseAccountsPath
      ?? endpointConfig.exchangeAccountPath(for: .coinbase)
      ?? "/api/v3/brokerage/accounts"
    self.krakenBalancePath = krakenBalancePath
      ?? endpointConfig.exchangeAccountPath(for: .kraken)
      ?? "/0/private/Balance"
    self.now = now
    self.jwtNonce = jwtNonce
    self.maxCoinbasePages = max(1, maxCoinbasePages)
    self.krakenNonceGenerator = krakenNonceGenerator
  }

  public func fetchBalance(provider: ExchangeProvider, credentials: ExchangeCredentials) async throws -> ExchangeBalance {
    try Task.checkCancellation()
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
    let signed = ExchangeRequestSigner.binanceAccountRequest(
      credentials: credentials,
      timestampMs: timestampMs,
      path: binanceAccountPath
    )
    let data = try await sendSignedRequest(signed, baseURL: binanceBaseURL)
    let response = try JSONDecoder.addressAtlas.decode(BinanceAccountResponse.self, from: data)
    var totals: [String: Double] = [:]
    var free: [String: Double] = [:]
    var warnings: [String] = []
    for balance in response.balances {
      guard let freeAmount = Self.parseAmount(balance.free), let lockedAmount = Self.parseAmount(balance.locked) else {
        warnings.append("\(balance.asset) contained a non-numeric balance and was skipped.")
        continue
      }
      let total = freeAmount + lockedAmount
      guard total > 0 else { continue }
      let symbol = ExchangeBalanceNormalizer.normalizeSymbol(balance.asset)
      guard !symbol.isEmpty else {
        warnings.append("Binance returned an empty asset code and it was skipped.")
        continue
      }
      totals[symbol, default: 0] += total
      free[symbol, default: 0] += freeAmount
    }
    return ExchangeBalance(total: totals, free: free, warnings: warnings)
  }

  private func fetchCoinbaseBalance(credentials: ExchangeCredentials) async throws -> ExchangeBalance {
    guard let host = Self.jwtHost(coinbaseBaseURL) else {
      throw ExchangeClientError.invalidResponse("Coinbase endpoint has no host.")
    }
    var totals: [String: Double] = [:]
    var free: [String: Double] = [:]
    var warnings: [String] = []
    var cursor: String?
    var seenCursors = Set<String>()
    var page = 0

    while true {
      try Task.checkCancellation()
      page += 1
      var queryItems = [URLQueryItem(name: "limit", value: "250")]
      if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
      let query = Self.percentEncodedQuery(queryItems)
      let response: CoinbaseAccountsResponse
      do {
        let signed = try ExchangeRequestSigner.coinbaseAccountsRequest(
          credentials: credentials,
          timestamp: Int64(now().timeIntervalSince1970),
          nonce: jwtNonce(),
          host: host,
          path: coinbaseAccountsPath,
          query: query
        )
        let data = try await sendSignedRequest(signed, baseURL: coinbaseBaseURL)
        response = try JSONDecoder.addressAtlas.decode(CoinbaseAccountsResponse.self, from: data)
      } catch {
        try throwIfCancellation(error)
        guard page > 1 else { throw error }
        warnings.append("Later Coinbase account pages could not be read; balances from completed pages were kept.")
        break
      }
      for account in response.accounts {
        guard let available = Self.parseAmount(account.availableBalance?.value ?? "0"),
              let hold = Self.parseAmount(account.hold?.value ?? "0")
        else {
          warnings.append("\(account.currency) contained a non-numeric balance and was skipped.")
          continue
        }
        let total = available + hold
        guard total > 0 else { continue }
        let symbol = ExchangeBalanceNormalizer.normalizeSymbol(account.currency)
        guard !symbol.isEmpty else {
          warnings.append("Coinbase returned an empty asset code and it was skipped.")
          continue
        }
        totals[symbol, default: 0] += total
        free[symbol, default: 0] += available
      }

      guard response.hasNext else { break }
      guard page < maxCoinbasePages else {
        warnings.append(ExchangeClientError.paginationLimit(provider: "Coinbase", pages: maxCoinbasePages).localizedDescription)
        break
      }
      let next = response.cursor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !next.isEmpty, seenCursors.insert(next).inserted else {
        warnings.append("Coinbase returned a missing or repeated pagination cursor; balances from completed pages were kept.")
        break
      }
      cursor = next
    }
    return ExchangeBalance(total: totals, free: free, warnings: warnings)
  }

  private func fetchKrakenBalance(credentials: ExchangeCredentials) async throws -> ExchangeBalance {
    let nonce = await krakenNonceGenerator.next(apiKey: credentials.apiKey, at: now())
    let signed = try ExchangeRequestSigner.krakenBalanceRequest(
      credentials: credentials,
      nonce: nonce,
      path: krakenBalancePath
    )
    let data = try await sendSignedRequest(signed, baseURL: krakenBaseURL, contentType: "application/x-www-form-urlencoded")
    let response = try JSONDecoder.addressAtlas.decode(KrakenBalanceResponse.self, from: data)
    guard response.error.isEmpty else {
      throw ExchangeClientError.invalidResponse(
        ProviderErrorSanitizer.sanitize(response.error.joined(separator: ", "))
      )
    }
    guard let rawBalances = response.result else {
      throw ExchangeClientError.invalidResponse("Kraken balance response was missing its result object.")
    }

    var warnings: [String] = []
    let aliases: [String: String]
    do {
      aliases = try await fetchKrakenAssetAliases()
    } catch {
      try throwIfCancellation(error)
      aliases = [:]
      warnings.append("Kraken asset metadata was unavailable; legacy symbol fallbacks were used.")
    }

    var totals: [String: Double] = [:]
    for (rawSymbol, rawAmount) in rawBalances {
      guard let amount = Self.parseAmount(rawAmount) else {
        warnings.append("\(rawSymbol) contained a non-numeric balance and was skipped.")
        continue
      }
      guard amount > 0 else { continue }
      let symbol = Self.normalizedKrakenSymbol(rawSymbol, aliases: aliases)
      guard !symbol.isEmpty else {
        warnings.append("Kraken returned an empty asset code for \(rawSymbol).")
        continue
      }
      totals[symbol, default: 0] += amount
    }
    return ExchangeBalance(total: totals, warnings: warnings)
  }

  private func fetchKrakenAssetAliases() async throws -> [String: String] {
    var components = URLComponents(url: krakenBaseURL, resolvingAgainstBaseURL: false)
    components?.path = "/0/public/Assets"
    guard let url = components?.url else { throw URLError(.badURL) }
    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "accept")
    let (data, response) = try await http.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      throw ExchangeClientError.httpError(
        statusCode: response.statusCode,
        message: Self.responseMessage(from: data, statusCode: response.statusCode)
      )
    }
    let decoded = try JSONDecoder.addressAtlas.decode(KrakenAssetsResponse.self, from: data)
    guard decoded.error.isEmpty else {
      throw ExchangeClientError.invalidResponse(
        ProviderErrorSanitizer.sanitize(decoded.error.joined(separator: ", "))
      )
    }
    return Dictionary(uniqueKeysWithValues: decoded.result.map { key, asset in
      (key.uppercased(), asset.altname)
    })
  }

  private func sendSignedRequest(
    _ signed: SignedExchangeRequest,
    baseURL: URL,
    contentType: String? = nil
  ) async throws -> Data {
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    components?.path = signed.path.hasPrefix("/") ? signed.path : "/\(signed.path)"
    if !signed.query.isEmpty { components?.percentEncodedQuery = signed.query }
    guard let url = components?.url else { throw URLError(.badURL) }

    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.httpMethod = signed.method
    request.setValue("application/json", forHTTPHeaderField: "accept")
    if let contentType { request.setValue(contentType, forHTTPHeaderField: "content-type") }
    for (header, value) in signed.headers { request.setValue(value, forHTTPHeaderField: header) }
    if !signed.body.isEmpty { request.httpBody = Data(signed.body.utf8) }

    let (data, response) = try await http.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      throw ExchangeClientError.httpError(
        statusCode: response.statusCode,
        message: Self.responseMessage(from: data, statusCode: response.statusCode)
      )
    }
    return data
  }

  private static func parseAmount(_ raw: String) -> Double? {
    guard let amount = Double(raw), amount.isFinite, amount >= 0 else { return nil }
    return amount
  }

  private static func normalizedKrakenSymbol(_ raw: String, aliases: [String: String]) -> String {
    let uppercase = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let base = ExchangeBalanceNormalizer.strippingKrakenBalanceSuffix(uppercase)
    let alias = aliases[uppercase] ?? aliases[base] ?? base
    return ExchangeBalanceNormalizer.normalizeSymbol(alias)
  }

  private static func jwtHost(_ url: URL) -> String? {
    guard let host = url.host else { return nil }
    if let port = url.port { return "\(host):\(port)" }
    return host
  }

  private static func percentEncodedQuery(_ items: [URLQueryItem]) -> String {
    var components = URLComponents()
    components.queryItems = items
    return components.percentEncodedQuery ?? ""
  }

  private static func responseMessage(from data: Data, statusCode: Int) -> String {
    let fallback = HTTPURLResponse.localizedString(forStatusCode: statusCode)
    guard !data.isEmpty else { return fallback }
    let cappedData = Data(data.prefix(16_384))
    if let json = try? JSONSerialization.jsonObject(with: cappedData), let message = jsonMessage(json) {
      return ProviderErrorSanitizer.sanitize(message, fallback: fallback)
    }
    if let text = String(data: cappedData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
      return ProviderErrorSanitizer.sanitize(text, fallback: fallback)
    }
    return fallback
  }

  private static func jsonMessage(_ value: Any) -> String? {
    if let dictionary = value as? [String: Any] {
      for key in ["msg", "message", "error", "reason", "detail"] {
        if let message = dictionary[key] as? String, !message.isEmpty { return message }
      }
      if let errors = dictionary["errors"] as? [Any], let message = errors.compactMap(jsonMessage).first {
        return message
      }
    }
    if let array = value as? [Any] { return array.compactMap(jsonMessage).first }
    return nil
  }
}

public struct ExchangeNormalizationResult: Sendable {
  public var holdings: [TrackedAsset]
  public var warnings: [String]

  public init(holdings: [TrackedAsset], warnings: [String] = []) {
    self.holdings = holdings
    self.warnings = warnings
  }
}

private enum ExchangeMarketDataResult: Sendable {
  case cryptoPrices([String: PricePoint])
  case fiatRates([String: Double])
  case cryptoFailure
  case fiatFailure
}

public enum ExchangeBalanceNormalizer {
  public static let usdStableSymbols: Set<String> = ["USD", "USDC", "USDT", "BUSD", "FDUSD", "TUSD", "USDP", "DAI"]
  public static let fiatSymbols: Set<String> = ["USD", "EUR", "GBP", "JPY", "CAD", "AUD", "CHF"]

  public static let coinGeckoIds: [String: String] = [
    "AAVE": "aave", "ADA": "cardano", "AERO": "aerodrome-finance", "ARB": "arbitrum",
    "ATOM": "cosmos", "AVAX": "avalanche-2", "BCH": "bitcoin-cash", "BNB": "binancecoin",
    "BONK": "bonk", "BTC": "bitcoin", "BUSD": "binance-usd", "CRV": "curve-dao-token", "DAI": "dai",
    "DOGE": "dogecoin", "DOT": "polkadot", "ETH": "ethereum", "EURC": "euro-coin",
    "GNO": "gnosis", "JUP": "jupiter-exchange-solana", "LINK": "chainlink", "LDO": "lido-dao",
    "FDUSD": "first-digital-usd", "LTC": "litecoin", "MATIC": "polygon-ecosystem-token", "MNT": "mantle", "MORPHO": "morpho",
    "MSOL": "msol", "OP": "optimism", "ORCA": "orca", "OSMO": "osmosis", "PEPE": "pepe",
    "POL": "polygon-ecosystem-token", "PYTH": "pyth-network", "RAY": "raydium", "SCR": "scroll",
    "SHIB": "shiba-inu", "SOL": "solana", "STETH": "staked-ether", "STRD": "stride",
    "TIA": "celestia", "TUSD": "true-usd", "UNI": "uniswap", "USDC": "usd-coin", "USDP": "pax-dollar", "USDT": "tether",
    "WBTC": "wrapped-bitcoin", "WETH": "weth", "WIF": "dogwifcoin", "XLM": "stellar",
    "XRP": "ripple", "XDAI": "xdai", "ZK": "zksync"
  ]

  public static func normalizeWithWarnings(
    balance: ExchangeBalance,
    id: UUID,
    provider: ExchangeProvider,
    label: String,
    priceProvider: PriceProviding
  ) async throws -> ExchangeNormalizationResult {
    let entries = balanceEntries(balance)
    let ids = Array(Set(entries.compactMap { symbol, _ in
      fiatSymbols.contains(symbol) ? nil : coinGeckoIds[symbol]
    }))
    let requestedFiatSymbols = Array(Set(entries.compactMap { symbol, _ in
      fiatSymbols.contains(symbol) && symbol != "USD" ? symbol : nil
    }))
    var warnings = balance.warnings
    var prices: [String: PricePoint] = [:]
    var fiatUsdRates: [String: Double] = [:]
    var priceRequestFailed = false
    var fiatRateRequestFailed = false

    try await withThrowingTaskGroup(of: ExchangeMarketDataResult.self) { group in
      if !ids.isEmpty {
        group.addTask {
          do {
            return .cryptoPrices(try await priceProvider.prices(for: ids))
          } catch {
            try throwIfCancellation(error)
            return .cryptoFailure
          }
        }
      }
      if !requestedFiatSymbols.isEmpty {
        group.addTask {
          do {
            return .fiatRates(try await priceProvider.usdRates(forFiatSymbols: requestedFiatSymbols))
          } catch {
            try throwIfCancellation(error)
            return .fiatFailure
          }
        }
      }

      for try await result in group {
        switch result {
        case .cryptoPrices(let fetched):
          prices = fetched.filter { $0.value.usd.isFinite && $0.value.usd >= 0 }
        case .fiatRates(let fetched):
          fiatUsdRates = fetched.reduce(into: [:]) { valid, entry in
            let symbol = entry.key.uppercased()
            guard requestedFiatSymbols.contains(symbol), entry.value.isFinite, entry.value > 0 else { return }
            valid[symbol] = entry.value
          }
        case .cryptoFailure:
          priceRequestFailed = true
        case .fiatFailure:
          fiatRateRequestFailed = true
        }
      }
    }

    if priceRequestFailed {
      warnings.append("USD crypto prices are temporarily unavailable; affected balances are shown unpriced.")
    }
    if fiatRateRequestFailed {
      warnings.append(
        "Fiat-to-USD rates are temporarily unavailable for \(formattedSymbols(requestedFiatSymbols)); those balances are shown unpriced."
      )
    }

    if !priceRequestFailed {
      let missing = entries.compactMap { symbol, _ -> String? in
        if fiatSymbols.contains(symbol) { return nil }
        guard let id = coinGeckoIds[symbol] else { return symbol }
        guard let point = prices[id], point.usd.isFinite, point.usd >= 0 else { return symbol }
        return nil
      }
      if !missing.isEmpty {
        warnings.append("No USD price was available for \(formattedSymbols(missing)); those balances are shown unpriced.")
      }
    }
    if !fiatRateRequestFailed {
      let missingFiat = requestedFiatSymbols.filter { symbol in
        guard let rate = fiatUsdRates[symbol] else { return true }
        return !rate.isFinite || rate <= 0
      }
      if !missingFiat.isEmpty {
        warnings.append(
          "No USD conversion rate was available for \(formattedSymbols(missingFiat)); those fiat balances are shown unpriced."
        )
      }
    }
    return ExchangeNormalizationResult(
      holdings: normalize(
        balance: balance,
        id: id,
        provider: provider,
        label: label,
        prices: prices,
        fiatUsdRates: fiatUsdRates
      ),
      warnings: warnings
    )
  }

  public static func normalize(
    balance: ExchangeBalance,
    id: UUID,
    provider: ExchangeProvider,
    label: String,
    priceProvider: PriceProviding
  ) async throws -> [TrackedAsset] {
    try await normalizeWithWarnings(
      balance: balance,
      id: id,
      provider: provider,
      label: label,
      priceProvider: priceProvider
    ).holdings
  }

  public static func normalize(
    balance: ExchangeBalance,
    id: UUID,
    provider: ExchangeProvider,
    label: String,
    prices: [String: PricePoint],
    fiatUsdRates: [String: Double] = [:]
  ) -> [TrackedAsset] {
    balanceEntries(balance).map { symbol, amount in
      let coinId = coinGeckoIds[symbol]
      let price = pricePoint(symbol: symbol, coinId: coinId, prices: prices, fiatUsdRates: fiatUsdRates)
      let unitPrice = price.usd.isFinite && price.usd >= 0 ? price.usd : 0
      return TrackedAsset(
        id: "\(id.uuidString)-\(provider.rawValue)-\(symbol)",
        address: label,
        chainId: provider.rawValue,
        chainName: provider.label,
        family: .exchange,
        symbol: symbol,
        name: symbol,
        amount: amount,
        priceUsd: unitPrice,
        valueUsd: amount * unitPrice,
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
    var aggregated: [String: Double] = [:]
    for (rawSymbol, amount) in source where amount.isFinite && amount > 0 {
      let symbol = normalizeSymbol(rawSymbol)
      guard !symbol.isEmpty else { continue }
      aggregated[symbol, default: 0] += amount
    }
    return aggregated.sorted { $0.key < $1.key }
  }

  public static func normalizeSymbol(_ symbol: String) -> String {
    let base = strippingKrakenBalanceSuffix(symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    switch base {
    case "XBT", "XXBT": return "BTC"
    case "XDG", "XXDG": return "DOGE"
    case "XETH", "ETH2": return "ETH"
    case "ZEUR": return "EUR"
    case "ZUSD": return "USD"
    case "ZGBP": return "GBP"
    case "ZJPY": return "JPY"
    case "ZCAD": return "CAD"
    case "ZAUD": return "AUD"
    case "ZCHF": return "CHF"
    default: return base
    }
  }

  static func strippingKrakenBalanceSuffix(_ symbol: String) -> String {
    let components = symbol.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count > 1, let suffix = components.last, ["B", "F", "M", "S", "T"].contains(String(suffix)) else {
      return symbol
    }
    return components.dropLast().joined(separator: ".")
  }

  private static func pricePoint(
    symbol: String,
    coinId: String?,
    prices: [String: PricePoint],
    fiatUsdRates: [String: Double]
  ) -> PricePoint {
    if symbol == "USD" { return PricePoint(usd: 1, usd24hChange: 0) }
    if fiatSymbols.contains(symbol), let rate = fiatUsdRates[symbol], rate.isFinite, rate > 0 {
      return PricePoint(usd: rate)
    }
    if let coinId, let price = prices[coinId], price.usd.isFinite, price.usd >= 0 { return price }
    return PricePoint(usd: 0)
  }

  private static func formattedSymbols(_ symbols: [String]) -> String {
    let unique = Array(Set(symbols)).sorted()
    guard unique.count > 5 else { return unique.joined(separator: ", ") }
    return "\(unique.prefix(5).joined(separator: ", ")) and \(unique.count - 5) more"
  }
}

private struct BinanceAccountResponse: Decodable {
  var balances: [Balance]
  struct Balance: Decodable { var asset: String; var free: String; var locked: String }
}

private struct CoinbaseAccountsResponse: Decodable {
  var accounts: [Account]
  var hasNext: Bool
  var cursor: String?

  enum CodingKeys: String, CodingKey {
    case accounts
    case hasNext = "has_next"
    case cursor
  }

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

  struct Money: Decodable { var value: String }
}

private struct KrakenBalanceResponse: Decodable {
  var error: [String]
  var result: [String: String]?
}

private struct KrakenAssetsResponse: Decodable {
  var error: [String]
  var result: [String: Asset]
  struct Asset: Decodable { var altname: String }
}
