import Foundation

public struct ExportedExchangeConnection: Codable, Equatable, Sendable {
  public var id: UUID
  public var provider: ExchangeProvider
  public var label: String
  public var status: ScanStatus
  public var credentialScopeAssurance: ExchangeCredentialScopeAssurance?
  public var lastTestedAt: Date?
  public var lastSyncAt: Date?
  public var createdAt: Date
  public var updatedAt: Date

  public init(_ connection: ExchangeConnectionRecord) {
    id = connection.id
    provider = connection.provider
    label = connection.label
    status = connection.status
    credentialScopeAssurance = connection.credentialScopeAssurance
    lastTestedAt = connection.lastTestedAt
    lastSyncAt = connection.lastSyncAt
    createdAt = connection.createdAt
    updatedAt = connection.updatedAt
  }
}

/// Credential-free full-portfolio JSON export. It intentionally retains
/// identifying public addresses, labels, balances, asset IDs, and history;
/// only sync authentication/base metadata and encrypted exchange credentials
/// have no representation here. UI copy must disclose that privacy contract.
public struct ExportedVaultDocument: Codable, Equatable, Sendable {
  public var exportFormatVersion: Int
  public var sourceSchemaVersion: Int
  public var preferences: Preferences
  public var wallets: [WalletRecord]
  public var customTokens: [CustomTokenRecord]
  public var manualHoldings: [ManualHoldingRecord]
  public var exchangeConnections: [ExportedExchangeConnection]
  public var scanRuns: [ScanRunRecord]
  public var updatedAt: Date

  public init(_ document: VaultDocument) {
    exportFormatVersion = 1
    sourceSchemaVersion = document.schemaVersion
    preferences = document.preferences
    wallets = document.wallets
    customTokens = document.customTokens
    manualHoldings = document.manualHoldings
    exchangeConnections = document.exchangeConnections.map(ExportedExchangeConnection.init)
    scanRuns = document.scanRuns
    updatedAt = document.updatedAt
  }
}

/// Coarse holding-count ranges used by the share-safer export. The ranges are
/// intentionally categorical: the serialized report never receives an exact
/// portfolio holding count.
public enum ShareSafeHoldingCountRange: String, Codable, CaseIterable, Sendable {
  case oneToTwo = "1_to_2"
  case threeToFive = "3_to_5"
  case sixToTen = "6_to_10"
  case elevenToTwentyFive = "11_to_25"
  case twentySixOrMore = "26_or_more"

  init(count: Int) {
    precondition(count > 0)
    switch count {
    case 1...2: self = .oneToTwo
    case 3...5: self = .threeToFive
    case 6...10: self = .sixToTen
    case 11...25: self = .elevenToTwentyFive
    default: self = .twentySixOrMore
    }
  }
}

/// Coarse value ranges used by the share-safer export. `notAvailable` covers
/// both unpriced holdings and holdings whose quote could not be converted into
/// a trustworthy USD valuation.
public enum ShareSafeUSDValueRange: String, Codable, CaseIterable, Sendable {
  case notAvailable = "not_available"
  case underOneHundred = "under_100"
  case oneHundredToNineHundredNinetyNine = "100_to_999"
  case oneThousandToNineThousandNineHundredNinetyNine = "1_000_to_9_999"
  case tenThousandToNinetyNineThousandNineHundredNinetyNine = "10_000_to_99_999"
  case oneHundredThousandToNineHundredNinetyNineThousandNineHundredNinetyNine =
    "100_000_to_999_999"
  case oneMillionOrMore = "1_000_000_or_more"

  init(pricedValue: Double?) {
    guard let pricedValue else {
      self = .notAvailable
      return
    }
    precondition(pricedValue.isFinite && pricedValue >= 0)
    switch pricedValue {
    case ..<100: self = .underOneHundred
    case ..<1_000: self = .oneHundredToNineHundredNinetyNine
    case ..<10_000: self = .oneThousandToNineThousandNineHundredNinetyNine
    case ..<100_000: self = .tenThousandToNinetyNineThousandNineHundredNinetyNine
    case ..<1_000_000:
      self = .oneHundredThousandToNineHundredNinetyNineThousandNineHundredNinetyNine
    default: self = .oneMillionOrMore
    }
  }
}

/// One aggregate in the share-safer portfolio report. Every serialized field
/// is either a closed application enum or a coarse categorical range. There is
/// deliberately no generic metadata bag that could later acquire identifiers.
public struct ShareSafePortfolioGroup: Codable, Equatable, Sendable {
  public let family: ChainFamily
  public let source: AssetSource
  public let pricingStatus: AssetPricingStatus
  public let holdingCountRange: ShareSafeHoldingCountRange
  public let estimatedValueUsdRange: ShareSafeUSDValueRange
}

/// A structurally minimized portfolio export intended for intentional sharing.
/// It is safer than the full export, but composition alone may identify a
/// portfolio, so the format is explicitly and permanently *not anonymous*.
///
/// Wallet addresses, user/provider labels, raw names, symbols, chain IDs,
/// record IDs, URLs, notes, warnings, history, timestamps, configuration,
/// credentials, sessions, exact amounts, prices, and values have no field in
/// this DTO.
public struct ShareSafePortfolioReport: Codable, Equatable, Sendable {
  public static let privacyNotice =
    "This share-safer summary reduces direct exposure, but portfolio composition may still re-identify you. It is not anonymous."

  public let exportFormatVersion: Int
  public let privacyNotice: String
  public let groups: [ShareSafePortfolioGroup]

  fileprivate init(groups: [ShareSafePortfolioGroup]) {
    exportFormatVersion = 1
    privacyNotice = Self.privacyNotice
    self.groups = groups
  }
}

private struct ShareSafeAggregationKey: Hashable {
  let family: String
  let source: String
  let pricingStatus: String
}

private struct ShareSafeAggregate {
  let family: ChainFamily
  let source: AssetSource
  let pricingStatus: AssetPricingStatus
  var holdingCount: Int
  var pricedValues: [Double]?
}

public enum AddressAtlasExporter {
  /// Builds the sole source-of-truth DTO for both share-safer serialization
  /// formats. It uses only the latest scan and validates the entire source
  /// document before reading it, so malformed authenticated data cannot be
  /// transformed into an apparently trustworthy report.
  public static func shareSafeReport(for document: VaultDocument) throws
    -> ShareSafePortfolioReport
  {
    try VaultDocumentSemanticValidator.validate(document)
    let latestHoldings = document.scanRuns.enumerated().max { lhs, rhs in
      if lhs.element.generatedAt == rhs.element.generatedAt {
        return lhs.offset < rhs.offset
      }
      return lhs.element.generatedAt < rhs.element.generatedAt
    }?.element.holdings ?? []

    var aggregates: [ShareSafeAggregationKey: ShareSafeAggregate] = [:]
    for asset in latestHoldings {
      let key = ShareSafeAggregationKey(
        family: asset.family.rawValue,
        source: asset.source.rawValue,
        pricingStatus: asset.pricingStatus.rawValue
      )
      var aggregate = aggregates[key] ?? ShareSafeAggregate(
        family: asset.family,
        source: asset.source,
        pricingStatus: asset.pricingStatus,
        holdingCount: 0,
        pricedValues: asset.pricingStatus == .priced ? [] : nil
      )
      aggregate.holdingCount += 1
      if aggregate.pricedValues != nil {
        aggregate.pricedValues?.append(asset.valueUsd)
      }
      aggregates[key] = aggregate
    }

    let groups = aggregates.sorted { lhs, rhs in
      if lhs.key.family != rhs.key.family { return lhs.key.family < rhs.key.family }
      if lhs.key.source != rhs.key.source { return lhs.key.source < rhs.key.source }
      return lhs.key.pricingStatus < rhs.key.pricingStatus
    }.map { _, aggregate in
      ShareSafePortfolioGroup(
        family: aggregate.family,
        source: aggregate.source,
        pricingStatus: aggregate.pricingStatus,
        holdingCountRange: ShareSafeHoldingCountRange(count: aggregate.holdingCount),
        estimatedValueUsdRange: ShareSafeUSDValueRange(
          pricedValue: aggregate.pricedValues.map(cappedDeterministicValue)
        )
      )
    }
    return ShareSafePortfolioReport(groups: groups)
  }

  public static func shareSafeCSV(for document: VaultDocument) throws -> String {
    let report = try shareSafeReport(for: document)
    let header = [
      "privacy_notice",
      "family",
      "source",
      "pricing_status",
      "holding_count_range",
      "estimated_value_usd_range",
    ].joined(separator: ",")
    let rows = report.groups.map { group in
      [
        csvEscape(report.privacyNotice),
        group.family.rawValue,
        group.source.rawValue,
        group.pricingStatus.rawValue,
        group.holdingCountRange.rawValue,
        group.estimatedValueUsdRange.rawValue,
      ].joined(separator: ",")
    }
    // Keep the output rectangular even when no scan exists. The first column
    // repeats the non-anonymity notice so it survives row-only imports.
    let outputRows = rows.isEmpty
      ? [[csvEscape(report.privacyNotice), "", "", "", "", ""].joined(separator: ",")]
      : rows
    return ([header] + outputRows).joined(separator: "\n")
  }

  public static func shareSafeJSON(for document: VaultDocument) throws -> Data {
    try JSONEncoder.addressAtlas.encode(shareSafeReport(for: document))
  }

  private static func cappedDeterministicValue(_ values: [Double]) -> Double {
    var total = 0.0
    // Floating-point addition is not associative. A canonical order prevents
    // the same holdings from crossing a bucket boundary merely because a scan
    // returned them in a different order.
    for value in values.sorted() {
      // The largest output bucket starts at $1m, so neither an exact total nor
      // arithmetic beyond that boundary is needed by the report.
      total = min(1_000_000, total + min(value, 1_000_000))
      if total == 1_000_000 { break }
    }
    return total
  }

  public static func csv(for assets: [TrackedAsset]) throws -> String {
    try VaultDocumentSemanticValidator.validateAssets(assets)
    let header = [
      "wallet_or_exchange",
      "chain",
      "symbol",
      "name",
      "amount",
      "price_usd",
      "value_usd",
      "pricing_status",
      "source",
    ].joined(separator: ",")
    let rows = assets.map { asset in
      [
        csvEscape(asset.walletLabel ?? asset.address),
        csvEscape(asset.chainName),
        csvEscape(asset.symbol),
        csvEscape(asset.name),
        asset.canonicalAmount,
        asset.pricingStatus == .unpriced ? "" : String(asset.priceUsd),
        asset.pricingStatus == .priced ? String(asset.valueUsd) : "",
        asset.pricingStatus.rawValue,
        csvEscape(asset.source.rawValue),
      ].joined(separator: ",")
    }
    return ([header] + rows).joined(separator: "\n")
  }

  public static func json(for document: VaultDocument) throws -> Data {
    try VaultDocumentSemanticValidator.validate(document)
    return try JSONEncoder.addressAtlas.encode(ExportedVaultDocument(document))
  }

  private static func csvEscape(_ value: String) -> String {
    // Neutralize spreadsheet formula injection: a free-text cell (symbol, name,
    // wallet label) beginning with =, +, -, @, or tab can be executed as a
    // formula by Excel/Sheets. Apply the same protection after CR/LF so even a
    // consumer that mishandles multiline fields cannot expose a formula at a
    // record boundary. Prefix it with a single quote so it stays text.
    // (Numeric columns are written without csvEscape, so negative numbers are
    // unaffected.)
    var sanitized = ""
    sanitized.reserveCapacity(value.count)
    var atRecordStart = true
    for scalar in value.unicodeScalars {
      if atRecordStart, [61, 43, 45, 64, 9].contains(scalar.value) {
        sanitized.append("'")
      }
      sanitized.append(String(scalar))
      atRecordStart = scalar.value == 13 || scalar.value == 10
    }
    let requiresQuotes = sanitized.unicodeScalars.contains { scalar in
      scalar.value == 44 || scalar.value == 34 || scalar.value == 13 || scalar.value == 10
    }
    if requiresQuotes {
      return "\"\(sanitized.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return sanitized
  }
}
