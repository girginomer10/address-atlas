import Foundation

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
      "source"
    ].joined(separator: ",")
    let rows = assets.map { asset in
      [
        csvEscape(asset.walletLabel ?? asset.address),
        csvEscape(asset.chainName),
        csvEscape(asset.symbol),
        csvEscape(asset.name),
        String(asset.amount),
        String(asset.priceUsd),
        String(asset.valueUsd),
        csvEscape(asset.source.rawValue)
      ].joined(separator: ",")
    }
    return ([header] + rows).joined(separator: "\n")
  }

  public static func json(for document: VaultDocument) throws -> Data {
    try JSONEncoder.addressAtlas.encode(document)
  }

  private static func csvEscape(_ value: String) -> String {
    // Neutralize spreadsheet formula injection: a free-text cell (symbol, name,
    // wallet label) beginning with =, +, -, @, tab, or CR is executed as a
    // formula by Excel/Sheets. Prefix it with a single quote so it stays text.
    // (Numeric columns are written without csvEscape, so negative numbers are
    // unaffected.)
    var sanitized = value
    if let first = value.first, "=+-@\t\r".contains(first) {
      sanitized = "'" + value
    }
    if sanitized.contains(",") || sanitized.contains("\"") || sanitized.contains("\n") {
      return "\"\(sanitized.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return sanitized
  }
}
