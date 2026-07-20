import AddressAtlasCore
import Foundation

extension AppState {

  /// Accepts the sync server URL only if it is https (http allowed for loopback
  /// dev hosts). Prevents the bearer token / config / vault traffic from ever
  /// traversing plaintext.
  static func validatedSyncURL(_ raw: String) -> URL? {
    SyncServerURL.validatedOrigin(raw)
  }

  static func resolvedAppVersion(_ bundleVersion: String?) -> String {
    guard let bundleVersion else { return currentAppVersion }
    let trimmed = bundleVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? currentAppVersion : trimmed
  }

  static func supportsAppVersion(_ current: String, minimum: String?) -> Bool {
    guard let minimum else { return true }
    guard let comparison = compareVersions(current, minimum) else { return false }
    return comparison >= 0
  }

  /// Numeric dotted-version comparison: nil for malformed/out-of-range input;
  /// otherwise -1 if lhs < rhs, 0 if equal, and 1 if greater.
  static func compareVersions(_ lhs: String, _ rhs: String) -> Int? {
    guard let a = NativeEndpointConfig.appVersionComponents(lhs),
      let b = NativeEndpointConfig.appVersionComponents(rhs)
    else {
      return nil
    }
    for index in 0..<max(a.count, b.count) {
      let x = index < a.count ? a[index] : 0
      let y = index < b.count ? b[index] : 0
      if x != y { return x < y ? -1 : 1 }
    }
    return 0
  }

  static func isPricedForDisplay(_ asset: TrackedAsset) -> Bool {
    asset.priceUsd > 0 || asset.valueUsd > 0
  }

  static func derivedManualPrice(amount: Double, valueUsd: Double) -> Double? {
    guard amount.isFinite, amount > 0, valueUsd.isFinite, valueUsd >= 0 else { return nil }
    let price = valueUsd / amount
    return price.isFinite ? price : nil
  }

  static func validatedPortfolioTotal(_ holdings: [TrackedAsset]) -> Double? {
    FiniteValueMath.sumNonnegative(holdings.map(\.valueUsd))
  }

  private static let maximumOperatorMessageScalarCount = 320

  /// Server-supplied broadcast text is untrusted UI input: replace control
  /// characters, collapse whitespace runs, and bound the rendered length.
  /// Returns nil when no displayable text remains.
  static func normalizedOperatorMessage(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let withoutControls = String(
      raw.unicodeScalars.map { scalar -> Character in
        CharacterSet.controlCharacters.contains(scalar) ? " " : Character(String(scalar))
      })
    let collapsed =
      withoutControls
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
    guard !collapsed.isEmpty else { return nil }
    let scalars = collapsed.unicodeScalars
    guard scalars.count > maximumOperatorMessageScalarCount else { return collapsed }
    return String(String.UnicodeScalarView(scalars.prefix(maximumOperatorMessageScalarCount))) + "…"
  }

  static func applyingWalletLabels(
    to holdings: [TrackedAsset],
    wallets: [WalletRecord]
  ) -> [TrackedAsset] {
    var labelsByAddress: [String: String] = [:]
    for wallet in wallets {
      guard
        let canonical = AddressDetection.canonicalAddress(wallet.address, family: wallet.chainKind)
      else { continue }
      labelsByAddress["\(wallet.chainKind.rawValue):\(canonical)"] = wallet.label
    }

    var attributed = holdings
    for index in attributed.indices {
      let asset = attributed[index]
      guard let canonical = AddressDetection.canonicalAddress(asset.address, family: asset.family)
      else { continue }
      if let label = labelsByAddress["\(asset.family.rawValue):\(canonical)"] {
        attributed[index].walletLabel = label
      }
    }
    return attributed
  }

  static func hasDuplicateExchangeAPIKey(
    provider: ExchangeProvider,
    apiKey: String,
    connections: [ExchangeConnectionRecord],
    vaultKey: Data,
    crypto: VaultCrypto = VaultCrypto()
  ) throws -> Bool {
    let candidate = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let credentialVault = ExchangeCredentialVault(crypto: crypto)
    for connection in connections where connection.provider == provider {
      let existing = try credentialVault.open(connection.encryptedCredentials, vaultKey: vaultKey)
      if existing.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == candidate {
        return true
      }
    }
    return false
  }

}
