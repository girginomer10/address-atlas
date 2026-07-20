import Foundation

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
  public static let usdStableSymbols: Set<String> = [
    "USD", "USDC", "USDT", "USDT0", "BUSD", "FDUSD", "TUSD", "USDP", "DAI",
  ]
  public static let fiatSymbols: Set<String> = ["USD", "EUR", "GBP", "JPY", "CAD", "AUD", "CHF"]

  public static let coinGeckoIds: [String: String] = [
    "AAVE": "aave", "ADA": "cardano", "AERO": "aerodrome-finance", "ARB": "arbitrum",
    "ATOM": "cosmos", "AVAX": "avalanche-2", "BCH": "bitcoin-cash", "BNB": "binancecoin",
    "BONK": "bonk", "BTC": "bitcoin", "BUSD": "binance-usd", "CRV": "curve-dao-token", "DAI": "dai",
    "DOGE": "dogecoin", "DOT": "polkadot", "ETH": "ethereum", "EURC": "euro-coin",
    "GNO": "gnosis", "JUP": "jupiter-exchange-solana", "LINK": "chainlink", "LDO": "lido-dao",
    "FDUSD": "first-digital-usd", "LTC": "litecoin", "MATIC": "polygon-ecosystem-token",
    "MNT": "mantle", "MORPHO": "morpho",
    "MSOL": "msol", "OP": "optimism", "ORCA": "orca", "OSMO": "osmosis", "PEPE": "pepe",
    "POL": "polygon-ecosystem-token", "PYTH": "pyth-network", "RAY": "raydium", "SCR": "scroll",
    "SHIB": "shiba-inu", "SOL": "solana", "STETH": "staked-ether", "STRD": "stride",
    "TIA": "celestia", "TUSD": "true-usd", "UNI": "uniswap", "USDC": "usd-coin",
    "USDP": "pax-dollar", "USDT": "tether", "USDT0": "usdt0",
    "WBTC": "wrapped-bitcoin", "WETH": "weth", "WIF": "dogwifcoin", "XLM": "stellar",
    "XRP": "ripple", "XDAI": "xdai", "ZK": "zksync",
  ]

  private struct BalanceEntryAggregation {
    var entries: [(String, Double)]
    var overflowedSymbols: [String]
  }

  private struct HoldingNormalization {
    var holdings: [TrackedAsset]
    var valuationOverflowSymbols: [String]
  }

  public static func normalizeWithWarnings(
    balance: ExchangeBalance,
    id: UUID,
    provider: ExchangeProvider,
    label: String,
    priceProvider: PriceProviding
  ) async throws -> ExchangeNormalizationResult {
    let aggregation = aggregateBalanceEntries(balance)
    let entries = aggregation.entries
    let ids = Array(
      Set(
        entries.compactMap { symbol, _ in
          fiatSymbols.contains(symbol) ? nil : coinGeckoIds[symbol]
        }))
    let requestedFiatSymbols = Array(
      Set(
        entries.compactMap { symbol, _ in
          fiatSymbols.contains(symbol) && symbol != "USD" ? symbol : nil
        }))
    var warnings = ScanWarningPolicy.bounded(balance.warnings)
    if !aggregation.overflowedSymbols.isEmpty {
      warnings.append(
        "Balances exceeded the supported numeric range for \(formattedSymbols(aggregation.overflowedSymbols)); those assets were skipped."
      )
    }
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
            return .fiatRates(
              try await priceProvider.usdRates(forFiatSymbols: requestedFiatSymbols))
          } catch {
            try throwIfCancellation(error)
            return .fiatFailure
          }
        }
      }

      for try await result in group {
        switch result {
        case .cryptoPrices(let fetched):
          prices = fetched.reduce(into: [:]) { valid, entry in
            guard let point = CoinGeckoPriceClient.sanitized(entry.value) else { return }
            valid[entry.key] = point
          }
        case .fiatRates(let fetched):
          fiatUsdRates = fetched.reduce(into: [:]) { valid, entry in
            let symbol = entry.key.uppercased()
            guard requestedFiatSymbols.contains(symbol), entry.value.isFinite, entry.value > 0
            else { return }
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
      warnings.append(
        "USD crypto prices are temporarily unavailable; affected balances are shown unpriced (USD stablecoins are valued at $1.00)."
      )
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
      // Stablecoins with a missing live price get the $1.00 fallback in
      // `pricePoint`, so their warning must not claim they are unpriced.
      let stablecoinFallbacks = missing.filter { usdStableSymbols.contains($0) }
      let unpriced = missing.filter { !usdStableSymbols.contains($0) }
      if !unpriced.isEmpty {
        warnings.append(
          "No USD price was available for \(formattedSymbols(unpriced)); those balances are shown unpriced."
        )
      }
      if !stablecoinFallbacks.isEmpty {
        warnings.append(
          "No live USD price was available for \(formattedSymbols(stablecoinFallbacks)); those stablecoin balances were valued at $1.00."
        )
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
    let normalized = normalize(
      entries: entries,
      id: id,
      provider: provider,
      label: label,
      prices: prices,
      fiatUsdRates: fiatUsdRates
    )
    if !normalized.valuationOverflowSymbols.isEmpty {
      warnings.append(
        "USD valuation exceeded the supported numeric range for \(formattedSymbols(normalized.valuationOverflowSymbols)); those balances are shown without a USD value."
      )
    }
    return ExchangeNormalizationResult(
      holdings: normalized.holdings,
      warnings: ScanWarningPolicy.bounded(warnings)
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
    normalize(
      entries: aggregateBalanceEntries(balance).entries,
      id: id,
      provider: provider,
      label: label,
      prices: prices,
      fiatUsdRates: fiatUsdRates
    ).holdings
  }

  private static func normalize(
    entries: [(String, Double)],
    id: UUID,
    provider: ExchangeProvider,
    label: String,
    prices: [String: PricePoint],
    fiatUsdRates: [String: Double]
  ) -> HoldingNormalization {
    var holdings: [TrackedAsset] = []
    var valuationOverflowSymbols: [String] = []
    for (symbol, amount) in entries {
      let coinId = coinGeckoIds[symbol]
      let price = pricePoint(
        symbol: symbol, coinId: coinId, prices: prices, fiatUsdRates: fiatUsdRates)
      let unitPrice = price.usd.isFinite && price.usd >= 0 ? price.usd : 0
      let valueUsd = FiniteValueMath.multiplyingNonnegative(amount, unitPrice)
      if valueUsd == nil { valuationOverflowSymbols.append(symbol) }
      holdings.append(
        TrackedAsset(
          id: "\(id.uuidString)-\(provider.rawValue)-\(symbol)",
          address: label,
          chainId: provider.rawValue,
          chainName: provider.label,
          family: .exchange,
          symbol: symbol,
          name: symbol,
          amount: amount,
          priceUsd: unitPrice,
          valueUsd: valueUsd ?? 0,
          change24h: FiniteValueMath.finiteOptional(price.usd24hChange),
          explorerUrl: "",
          source: .exchange,
          walletLabel: label,
          exchangeId: id,
          exchangeProvider: provider
        ))
    }
    return HoldingNormalization(
      holdings: holdings,
      valuationOverflowSymbols: valuationOverflowSymbols
    )
  }

  public static func balanceEntries(_ balance: ExchangeBalance) -> [(String, Double)] {
    aggregateBalanceEntries(balance).entries
  }

  private static func aggregateBalanceEntries(_ balance: ExchangeBalance) -> BalanceEntryAggregation
  {
    let source = balance.total.isEmpty ? balance.free : balance.total
    var aggregated: [String: Double] = [:]
    var overflowedSymbols = Set<String>()
    for (rawSymbol, amount) in source where amount.isFinite && amount > 0 {
      let symbol = normalizeSymbol(rawSymbol)
      guard !symbol.isEmpty, !overflowedSymbols.contains(symbol) else { continue }
      guard let next = FiniteValueMath.addingNonnegative(aggregated[symbol, default: 0], amount)
      else {
        aggregated.removeValue(forKey: symbol)
        overflowedSymbols.insert(symbol)
        continue
      }
      aggregated[symbol] = next
    }
    return BalanceEntryAggregation(
      entries: aggregated.sorted { $0.key < $1.key },
      overflowedSymbols: overflowedSymbols.sorted()
    )
  }

  public static func normalizeSymbol(_ symbol: String) -> String {
    guard let validated = validatedExchangeSymbol(symbol) else { return "" }
    let base = strippingKrakenBalanceSuffix(validated)
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

  /// Returns the only exchange asset-code representation allowed to reach
  /// aggregation, persistence, generated identifiers, or UI text. Providers
  /// commonly use lowercase metadata and Kraken suffixes, so input ASCII is
  /// case-folded while the canonical result remains uppercase and tightly
  /// bounded. At least one alphanumeric byte is required.
  static func validatedExchangeSymbol(_ candidate: String) -> String? {
    guard !candidate.isEmpty, candidate.utf8.count <= 64 else { return nil }
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    let bytes = trimmed.utf8
    guard !bytes.isEmpty else { return nil }

    var containsAlphanumeric = false
    for byte in bytes {
      switch byte {
      case 48...57, 65...90, 97...122:
        containsAlphanumeric = true
      case 45, 46, 95:  // hyphen, period, underscore
        continue
      default:
        return nil
      }
    }
    guard containsAlphanumeric else { return nil }
    return trimmed.uppercased()
  }

  static func strippingKrakenBalanceSuffix(_ symbol: String) -> String {
    let components = symbol.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count > 1, let suffix = components.last,
      ["B", "F", "M", "S", "T"].contains(String(suffix))
    else {
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
    if let coinId, let price = prices[coinId], price.usd.isFinite, price.usd >= 0 {
      return PricePoint(
        usd: price.usd,
        usd24hChange: FiniteValueMath.finiteOptional(price.usd24hChange)
      )
    }
    // A live CoinGecko price always wins above. Only when it is missing (the
    // symbol was omitted from the response or the request failed) may a USD
    // stablecoin fall back to exactly $1.00 instead of rendering a real
    // balance as $0. Every other symbol without a price stays visibly unpriced.
    if usdStableSymbols.contains(symbol) { return PricePoint(usd: 1) }
    return PricePoint(usd: 0)
  }

  static func formattedSymbols(_ symbols: [String]) -> String {
    let unique = Array(Set(symbols)).sorted()
    guard unique.count > 5 else { return unique.joined(separator: ", ") }
    return "\(unique.prefix(5).joined(separator: ", ")) and \(unique.count - 5) more"
  }
}
