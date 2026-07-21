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

/// User-facing JSON export. Sync authentication/base metadata and encrypted
/// exchange credential material intentionally have no representation here.
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

public enum AddressAtlasExporter {
  public static func csv(for assets: [TrackedAsset]) -> String {
    let header = [
      "wallet_or_exchange",
      "chain",
      "symbol",
      "name",
      "amount",
      "price_usd",
      "value_usd",
      "source",
    ].joined(separator: ",")
    let rows = assets.map { asset in
      [
        csvEscape(asset.walletLabel ?? asset.address),
        csvEscape(asset.chainName),
        csvEscape(asset.symbol),
        csvEscape(asset.name),
        asset.canonicalAmount,
        String(asset.priceUsd),
        String(asset.valueUsd),
        csvEscape(asset.source.rawValue),
      ].joined(separator: ",")
    }
    return ([header] + rows).joined(separator: "\n")
  }

  public static func json(for document: VaultDocument) throws -> Data {
    try JSONEncoder.addressAtlas.encode(ExportedVaultDocument(document))
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
