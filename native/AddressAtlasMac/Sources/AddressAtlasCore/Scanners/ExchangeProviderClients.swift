import Foundation

/// The provider APIs have different pagination, identity, and symbol rules,
/// but share one numeric invariant: once any row makes a symbol overflow, the
/// complete symbol is discarded and no later row may resurrect a partial sum.
/// Keep only that invariant here; provider-specific validation stays at each
/// wire boundary.
private struct ExchangeBalanceAccumulator {
  private(set) var total: [String: ExchangeAmount] = [:]
  private(set) var free: [String: ExchangeAmount] = [:]
  private(set) var overflowedSymbols = Set<String>()
  private var invalidSymbols = Set<String>()

  mutating func addAvailable(
    _ available: ExchangeAmount,
    restricted: ExchangeAmount,
    for symbol: String
  ) {
    guard !overflowedSymbols.contains(symbol), !invalidSymbols.contains(symbol) else { return }
    guard let combined = available.adding(restricted) else {
      markOverflow(for: symbol)
      return
    }
    guard combined.isPositive else { return }
    let currentTotal = total[symbol] ?? .zero
    let currentFree = free[symbol] ?? .zero
    guard let nextTotal = currentTotal.adding(combined),
      let nextFree = currentFree.adding(available)
    else {
      markOverflow(for: symbol)
      return
    }
    total[symbol] = nextTotal
    free[symbol] = nextFree
  }

  mutating func addTotal(_ amount: ExchangeAmount, for symbol: String) {
    guard amount.isPositive, !overflowedSymbols.contains(symbol), !invalidSymbols.contains(symbol)
    else { return }
    let current = total[symbol] ?? .zero
    guard let nextTotal = current.adding(amount) else {
      markOverflow(for: symbol)
      return
    }
    total[symbol] = nextTotal
  }

  mutating func markOverflow(for symbol: String) {
    total.removeValue(forKey: symbol)
    free.removeValue(forKey: symbol)
    overflowedSymbols.insert(symbol)
  }

  mutating func markInvalid(for symbol: String) {
    total.removeValue(forKey: symbol)
    free.removeValue(forKey: symbol)
    invalidSymbols.insert(symbol)
  }
}

private struct BinanceBalanceRecord: Equatable {
  var free: ExchangeAmount
  var locked: ExchangeAmount
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
    jwtNonce: @escaping @Sendable () -> String = {
      UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    },
    maxCoinbasePages: Int = 20,
    krakenNonceGenerator: KrakenNonceGenerator = .shared
  ) {
    self.http = http ?? BoundedURLSessionHTTPClient(maxResponseBytes: 8_000_000)
    self.binanceBaseURL =
      binanceBaseURL
      ?? endpointConfig.exchangeBaseURL(for: .binance)
      ?? URL(string: "https://api.binance.com")!
    self.coinbaseBaseURL =
      coinbaseBaseURL
      ?? endpointConfig.exchangeBaseURL(for: .coinbase)
      ?? URL(string: "https://api.coinbase.com")!
    self.krakenBaseURL =
      krakenBaseURL
      ?? endpointConfig.exchangeBaseURL(for: .kraken)
      ?? URL(string: "https://api.kraken.com")!
    self.binanceAccountPath =
      binanceAccountPath
      ?? endpointConfig.exchangeAccountPath(for: .binance)
      ?? "/api/v3/account"
    self.coinbaseAccountsPath =
      coinbaseAccountsPath
      ?? endpointConfig.exchangeAccountPath(for: .coinbase)
      ?? "/api/v3/brokerage/accounts"
    self.krakenBalancePath =
      krakenBalancePath
      ?? endpointConfig.exchangeAccountPath(for: .kraken)
      ?? "/0/private/Balance"
    self.now = now
    self.jwtNonce = jwtNonce
    self.maxCoinbasePages = max(1, maxCoinbasePages)
    self.krakenNonceGenerator = krakenNonceGenerator
  }

  public func fetchBalance(
    provider: ExchangeProvider,
    credentials: ExchangeCredentials,
    krakenDeviceIdentifier: String? = nil
  ) async throws -> ExchangeBalance {
    try Task.checkCancellation()
    switch provider {
    case .binance:
      return try await fetchBinanceBalance(credentials: credentials)
    case .coinbase:
      return try await fetchCoinbaseBalance(credentials: credentials)
    case .kraken:
      return try await fetchKrakenBalance(
        credentials: credentials,
        expectedDeviceIdentifier: krakenDeviceIdentifier
      )
    }
  }

  /// Validate credential scope before encrypted persistence. Binance exposes a
  /// signed, authoritative permission document; Coinbase and Kraken do not
  /// currently provide an equivalent check through the credential flows used
  /// here, so those providers return an explicit manual-verification result.
  public func validateCredentialScope(
    provider: ExchangeProvider,
    credentials: ExchangeCredentials
  ) async throws -> ExchangeCredentialScopeValidation {
    try Task.checkCancellation()
    switch provider {
    case .binance:
      let timestampMs = Int64(now().timeIntervalSince1970 * 1_000)
      let signed = ExchangeRequestSigner.binanceAPIRestrictionsRequest(
        credentials: credentials,
        timestampMs: timestampMs
      )
      let data = try await sendSignedRequest(signed, baseURL: binanceBaseURL)
      return try Self.validateBinancePermissionDocument(data)
    case .coinbase:
      return .manualVerificationRequired(
        provider: .coinbase,
        guidance:
          "Address Atlas can't check this Coinbase key's permissions. Make sure the CDP key is limited to view (read) access."
      )
    case .kraken:
      return .manualVerificationRequired(
        provider: .kraken,
        guidance:
          "Address Atlas can't check this Kraken key's permissions. Make sure only Query Funds is turned on, and use this key on one \(PlatformCopy.deviceNoun) only."
      )
    }
  }

  private static func validateBinancePermissionDocument(
    _ data: Data
  ) throws -> ExchangeCredentialScopeValidation {
    guard data.count <= 1_000_000,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["enableReading"] as? Bool == true
    else {
      throw ExchangeClientError.missingReadPermission(provider: .binance)
    }

    // Reject every true capability-shaped flag other than reading. This
    // includes newly added Binance enable*/permit*/can* permissions by default,
    // so API evolution cannot silently turn a key with broader powers into a
    // "verified read-only" key. `ipRestrict` is a safety control, not a power.
    let dangerous = object.compactMap { key, value -> String? in
      guard let enabled = value as? Bool, enabled, key != "enableReading", key != "ipRestrict"
      else {
        return nil
      }
      let normalized = key.lowercased()
      guard
        normalized.hasPrefix("enable")
          || normalized.hasPrefix("permit")
          || normalized.hasPrefix("can")
      else {
        return nil
      }
      return key
    }
    guard dangerous.isEmpty else {
      throw ExchangeClientError.unsafeCredentialScope(
        provider: .binance,
        permissions: dangerous
      )
    }
    return .verifiedReadOnly
  }

  private func fetchBinanceBalance(credentials: ExchangeCredentials) async throws -> ExchangeBalance
  {
    let timestampMs = Int64(now().timeIntervalSince1970 * 1000)
    let signed = ExchangeRequestSigner.binanceAccountRequest(
      credentials: credentials,
      timestampMs: timestampMs,
      path: binanceAccountPath
    )
    let data = try await sendSignedRequest(signed, baseURL: binanceBaseURL)
    let response = try JSONDecoder.addressAtlas.decode(BinanceAccountResponse.self, from: data)
    var accumulator = ExchangeBalanceAccumulator()
    var warnings: [String] = []
    var invalidSymbolCount = 0
    var invalidAmountCount = 0
    var recordsBySymbol: [String: BinanceBalanceRecord] = [:]
    var malformedSymbols = Set<String>()
    var conflictingSymbols = Set<String>()
    var identicalDuplicateCount = 0
    for balance in response.balances {
      guard let validatedAsset = ExchangeBalanceNormalizer.validatedExchangeSymbol(balance.asset)
      else {
        invalidSymbolCount += 1
        continue
      }
      let symbol = ExchangeBalanceNormalizer.normalizeSymbol(validatedAsset)
      guard !symbol.isEmpty else {
        invalidSymbolCount += 1
        continue
      }
      let freeAmount: ExchangeAmount
      let lockedAmount: ExchangeAmount
      switch (ExchangeAmount.parse(balance.free), ExchangeAmount.parse(balance.locked)) {
      case (.value(let free), .value(let locked)):
        freeAmount = free
        lockedAmount = locked
      case (.outOfRange, _), (_, .outOfRange):
        accumulator.markOverflow(for: symbol)
        malformedSymbols.insert(symbol)
        recordsBySymbol.removeValue(forKey: symbol)
        continue
      case (.invalid, _), (_, .invalid):
        invalidAmountCount += 1
        malformedSymbols.insert(symbol)
        recordsBySymbol.removeValue(forKey: symbol)
        continue
      }
      guard !malformedSymbols.contains(symbol), !conflictingSymbols.contains(symbol) else {
        continue
      }
      let candidate = BinanceBalanceRecord(free: freeAmount, locked: lockedAmount)
      if let existing = recordsBySymbol[symbol] {
        if existing == candidate {
          identicalDuplicateCount += 1
        } else {
          recordsBySymbol.removeValue(forKey: symbol)
          conflictingSymbols.insert(symbol)
        }
      } else {
        recordsBySymbol[symbol] = candidate
      }
    }
    for (symbol, record) in recordsBySymbol {
      accumulator.addAvailable(record.free, restricted: record.locked, for: symbol)
    }
    if invalidSymbolCount > 0 {
      warnings.append(
        invalidSymbolCount == 1
          ? "1 Binance balance has an invalid asset code, so it's left out of this scan."
          : "\(invalidSymbolCount) Binance balances have an invalid asset code, so they're left out of this scan."
      )
    }
    if invalidAmountCount > 0 {
      warnings.append(
        invalidAmountCount == 1
          ? "1 Binance balance has an invalid amount, so it's left out of this scan."
          : "\(invalidAmountCount) Binance balances have an invalid amount, so they're left out of this scan."
      )
    }
    if identicalDuplicateCount > 0 {
      warnings.append(
        identicalDuplicateCount == 1
          ? "Binance listed the same balance twice. It was counted once."
          : "Binance listed \(identicalDuplicateCount) balances more than once. Each was counted once."
      )
    }
    if !conflictingSymbols.isEmpty {
      warnings.append(
        "Binance sent conflicting balances for \(ExchangeBalanceNormalizer.formattedSymbols(Array(conflictingSymbols))), so those balances are left out of this scan. Scan again later."
      )
    }
    if !accumulator.overflowedSymbols.isEmpty {
      warnings.append(
        "The Binance balances of \(ExchangeBalanceNormalizer.formattedSymbols(Array(accumulator.overflowedSymbols))) are larger than Address Atlas can add up, so they're left out of this scan."
      )
    }
    return ExchangeBalance(
      exactTotal: accumulator.total,
      exactFree: accumulator.free,
      warnings: ScanWarningPolicy.bounded(warnings)
    )
  }

  private func fetchCoinbaseBalance(credentials: ExchangeCredentials) async throws
    -> ExchangeBalance
  {
    guard let host = Self.jwtHost(coinbaseBaseURL) else {
      throw ExchangeClientError.invalidResponse("The Coinbase server address isn't valid. Check the server settings in Settings.")
    }
    var accumulator = ExchangeBalanceAccumulator()
    var warnings: [String] = []
    var cursor: String?
    var seenCursors = Set<String>()
    var accountsByIdentifier: [UUID: CoinbaseAccountsResponse.Account] = [:]
    var conflictingAccountIdentifiers = Set<UUID>()
    var invalidAccountIdentifierCount = 0
    var exactDuplicateAccountRecordCount = 0
    var invalidAmountCount = 0
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
        warnings.append(
          "Couldn't read later pages of Coinbase accounts, so some balances may be missing from this scan. Scan again later."
        )
        break
      }
      for account in response.accounts {
        guard let identifier = account.identifier else {
          invalidAccountIdentifierCount += 1
          continue
        }
        guard !conflictingAccountIdentifiers.contains(identifier) else { continue }
        if let existing = accountsByIdentifier[identifier] {
          if existing == account {
            exactDuplicateAccountRecordCount += 1
          } else {
            accountsByIdentifier.removeValue(forKey: identifier)
            conflictingAccountIdentifiers.insert(identifier)
          }
          continue
        }
        accountsByIdentifier[identifier] = account
      }

      guard response.hasNext else { break }
      guard page < maxCoinbasePages else {
        warnings.append(
          ExchangeClientError.paginationLimit(provider: "Coinbase", pages: maxCoinbasePages)
            .localizedDescription)
        break
      }
      let next = response.cursor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !next.isEmpty, seenCursors.insert(next).inserted else {
        warnings.append(
          "Coinbase sent a missing or repeated page marker, so later accounts may be missing from this scan. Scan again later."
        )
        break
      }
      cursor = next
    }

    var invalidSymbolCount = 0
    for identifier in accountsByIdentifier.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard let account = accountsByIdentifier[identifier] else { continue }
      guard
        let validatedCurrency = ExchangeBalanceNormalizer.validatedExchangeSymbol(account.currency)
      else {
        invalidSymbolCount += 1
        continue
      }
      let symbol = ExchangeBalanceNormalizer.normalizeSymbol(validatedCurrency)
      guard !symbol.isEmpty else {
        invalidSymbolCount += 1
        continue
      }
      let available: ExchangeAmount
      let hold: ExchangeAmount
      switch (
        ExchangeAmount.parse(account.availableBalance?.value ?? "0"),
        ExchangeAmount.parse(account.hold?.value ?? "0")
      ) {
      case (.value(let parsedAvailable), .value(let parsedHold)):
        available = parsedAvailable
        hold = parsedHold
      case (.outOfRange, _), (_, .outOfRange):
        accumulator.markOverflow(for: symbol)
        continue
      case (.invalid, _), (_, .invalid):
        invalidAmountCount += 1
        accumulator.markInvalid(for: symbol)
        continue
      }
      accumulator.addAvailable(available, restricted: hold, for: symbol)
    }
    if invalidAccountIdentifierCount > 0 {
      warnings.append(
        invalidAccountIdentifierCount == 1
          ? "1 Coinbase account has a missing or invalid ID, so it's left out of this scan."
          : "\(invalidAccountIdentifierCount) Coinbase accounts have a missing or invalid ID, so they're left out of this scan."
      )
    }
    if exactDuplicateAccountRecordCount > 0 {
      warnings.append(
        exactDuplicateAccountRecordCount == 1
          ? "Coinbase listed one account twice. It was counted once."
          : "Coinbase listed \(exactDuplicateAccountRecordCount) accounts more than once. Each was counted once."
      )
    }
    if !conflictingAccountIdentifiers.isEmpty {
      warnings.append(
        conflictingAccountIdentifiers.count == 1
          ? "Coinbase sent conflicting data for one account, so it's left out of this scan. Scan again later."
          : "Coinbase sent conflicting data for \(conflictingAccountIdentifiers.count) accounts, so they're left out of this scan. Scan again later."
      )
    }
    if invalidSymbolCount > 0 {
      warnings.append(
        invalidSymbolCount == 1
          ? "1 Coinbase account has an invalid asset code, so it's left out of this scan."
          : "\(invalidSymbolCount) Coinbase accounts have an invalid asset code, so they're left out of this scan."
      )
    }
    if invalidAmountCount > 0 {
      warnings.append(
        invalidAmountCount == 1
          ? "1 Coinbase account has an invalid amount, so it's left out of this scan."
          : "\(invalidAmountCount) Coinbase accounts have an invalid amount, so they're left out of this scan."
      )
    }
    if !accumulator.overflowedSymbols.isEmpty {
      warnings.append(
        "The Coinbase balances of \(ExchangeBalanceNormalizer.formattedSymbols(Array(accumulator.overflowedSymbols))) are larger than Address Atlas can add up, so they're left out of this scan."
      )
    }
    return ExchangeBalance(
      exactTotal: accumulator.total,
      exactFree: accumulator.free,
      warnings: ScanWarningPolicy.bounded(warnings)
    )
  }

  private func fetchKrakenBalance(
    credentials: ExchangeCredentials,
    expectedDeviceIdentifier: String?
  ) async throws -> ExchangeBalance {
    // Even direct client callers get a deletion-race check: read the local
    // identity first, then require the nonce transaction to observe the same
    // identity while it persists the next value.
    let deviceIdentifier: String
    if let expectedDeviceIdentifier {
      deviceIdentifier = expectedDeviceIdentifier
    } else {
      deviceIdentifier = try await krakenNonceGenerator.deviceIdentifier()
    }
    let nonce = try await krakenNonceGenerator.next(
      apiKey: credentials.apiKey,
      at: now(),
      expectedDeviceIdentifier: deviceIdentifier
    )
    let signed = try ExchangeRequestSigner.krakenBalanceRequest(
      credentials: credentials,
      nonce: nonce,
      path: krakenBalancePath
    )
    let data = try await sendSignedRequest(
      signed, baseURL: krakenBaseURL, contentType: "application/x-www-form-urlencoded")
    let response = try JSONDecoder.addressAtlas.decode(KrakenBalanceResponse.self, from: data)
    guard response.error.isEmpty else {
      throw ExchangeClientError.invalidResponse(
        ProviderErrorSanitizer.sanitize(response.error.joined(separator: ", "))
      )
    }
    guard let rawBalances = response.result else {
      throw ExchangeClientError.invalidResponse(
        "Kraken's reply didn't include a balance list.")
    }

    var warnings: [String] = []
    let aliases: [String: String]
    do {
      aliases = try await fetchKrakenAssetAliases()
    } catch {
      try throwIfCancellation(error)
      aliases = [:]
      warnings.append("Couldn't load Kraken's asset list, so some coins may use older symbols.")
    }

    var accumulator = ExchangeBalanceAccumulator()
    var invalidSymbolCount = 0
    var invalidAmountCount = 0
    for (rawSymbol, rawAmount) in rawBalances {
      guard let validatedRawSymbol = ExchangeBalanceNormalizer.validatedExchangeSymbol(rawSymbol)
      else {
        invalidSymbolCount += 1
        continue
      }
      guard let symbol = Self.normalizedKrakenSymbol(validatedRawSymbol, aliases: aliases),
        !symbol.isEmpty
      else {
        invalidSymbolCount += 1
        continue
      }
      let amount: ExchangeAmount
      switch ExchangeAmount.parse(rawAmount) {
      case .value(let parsed):
        amount = parsed
      case .outOfRange:
        accumulator.markOverflow(for: symbol)
        continue
      case .invalid:
        invalidAmountCount += 1
        accumulator.markInvalid(for: symbol)
        continue
      }
      guard amount.isPositive else { continue }
      accumulator.addTotal(amount, for: symbol)
    }
    if invalidSymbolCount > 0 {
      warnings.append(
        invalidSymbolCount == 1
          ? "1 Kraken balance has an invalid asset code, so it's left out of this scan."
          : "\(invalidSymbolCount) Kraken balances have an invalid asset code, so they're left out of this scan."
      )
    }
    if invalidAmountCount > 0 {
      warnings.append(
        invalidAmountCount == 1
          ? "1 Kraken balance has an invalid amount, so it's left out of this scan."
          : "\(invalidAmountCount) Kraken balances have an invalid amount, so they're left out of this scan."
      )
    }
    if !accumulator.overflowedSymbols.isEmpty {
      warnings.append(
        "The Kraken balances of \(ExchangeBalanceNormalizer.formattedSymbols(Array(accumulator.overflowedSymbols))) are larger than Address Atlas can add up, so they're left out of this scan."
      )
    }
    return ExchangeBalance(
      exactTotal: accumulator.total,
      warnings: ScanWarningPolicy.bounded(warnings)
    )
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
    var aliases: [String: String] = [:]
    for (key, asset) in decoded.result.sorted(by: { $0.key < $1.key }) {
      guard let normalizedKey = ExchangeBalanceNormalizer.validatedExchangeSymbol(key),
        let normalizedAlias = ExchangeBalanceNormalizer.validatedExchangeSymbol(asset.altname)
      else {
        throw ExchangeClientError.invalidResponse(
          "Kraken asset metadata contained an invalid asset code or alias."
        )
      }
      // Provider-controlled JSON keys can be distinct before case folding
      // (`xbt` and `XBT`) but collide afterward. Reject the complete metadata
      // response instead of trapping in Dictionary(uniqueKeysWithValues:) or
      // choosing an attacker/order-dependent alias. The caller then uses the
      // conservative built-in symbol normalization and emits a warning.
      guard aliases[normalizedKey] == nil else {
        throw ExchangeClientError.invalidResponse(
          "Kraken asset metadata contained ambiguous case-insensitive asset keys."
        )
      }
      aliases[normalizedKey] = normalizedAlias
    }
    return aliases
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

  private static func normalizedKrakenSymbol(_ validatedRaw: String, aliases: [String: String])
    -> String?
  {
    let base = ExchangeBalanceNormalizer.strippingKrakenBalanceSuffix(validatedRaw)
    let alias = aliases[validatedRaw] ?? aliases[base] ?? base
    guard let validatedAlias = ExchangeBalanceNormalizer.validatedExchangeSymbol(alias) else {
      return nil
    }
    return ExchangeBalanceNormalizer.normalizeSymbol(validatedAlias)
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
    if let json = try? JSONSerialization.jsonObject(with: cappedData),
      let message = jsonMessage(json)
    {
      return ProviderErrorSanitizer.sanitize(message, fallback: fallback)
    }
    if let text = String(data: cappedData, encoding: .utf8)?.trimmingCharacters(
      in: .whitespacesAndNewlines), !text.isEmpty
    {
      return ProviderErrorSanitizer.sanitize(text, fallback: fallback)
    }
    return fallback
  }

  private static func jsonMessage(_ value: Any) -> String? {
    if let dictionary = value as? [String: Any] {
      for key in ["msg", "message", "error", "reason", "detail"] {
        if let message = dictionary[key] as? String, !message.isEmpty { return message }
      }
      if let errors = dictionary["errors"] as? [Any],
        let message = errors.compactMap(jsonMessage).first
      {
        return message
      }
    }
    if let array = value as? [Any] { return array.compactMap(jsonMessage).first }
    return nil
  }
}
