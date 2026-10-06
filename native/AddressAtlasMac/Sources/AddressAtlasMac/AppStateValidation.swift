import AddressAtlasCore
import Foundation

extension AppState {

  /// Accepts the sync server URL only if it is https (http allowed for loopback
  /// dev hosts). Prevents the bearer token / config / vault traffic from ever
  /// traversing plaintext.
  static func validatedSyncURL(_ raw: String) -> URL? {
    SyncServerURL.validatedOrigin(raw)
  }

  /// Existing-session controls are bound to the canonical origin persisted with
  /// the bearer grant. Equivalent URL spellings remain usable, while an edited
  /// draft can never retarget an operation until it has been explicitly saved.
  static func syncServerDraftMatchesPersisted(_ draft: String, persisted: String) -> Bool {
    guard let draftURL = validatedSyncURL(draft),
      let persistedURL = validatedSyncURL(persisted)
    else { return false }
    return draftURL == persistedURL
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
    asset.pricingStatus == .priced
  }

  static func remoteVersionStatus(_ state: SyncState) -> String {
    guard state.remoteOutcomeUncertain else { return "\(state.latestRemoteVersion)" }
    return state.latestRemoteVersion > 0
      ? "Unknown (last confirmed \(state.latestRemoteVersion))"
      : "Unknown (no confirmed remote version)"
  }

  static func lastConfirmedSyncStatus(_ state: SyncState) -> String {
    let confirmed = state.lastSyncedAt.map(AtlasFormatting.dateTime) ?? "never"
    return state.remoteOutcomeUncertain ? "Unknown (last confirmed \(confirmed))" : confirmed
  }

  static func lastConfirmedChecksumStatus(_ state: SyncState) -> String {
    let confirmed = state.lastChecksum ?? "none"
    return state.remoteOutcomeUncertain ? "Unknown (last confirmed \(confirmed))" : confirmed
  }

  static func derivedManualPrice(amount: Double, valueUsd: Double) -> Double? {
    guard amount.isFinite, amount > 0, valueUsd.isFinite, valueUsd >= 0 else { return nil }
    let price = valueUsd / amount
    return price.isFinite ? price : nil
  }

  static func validatedPortfolioTotal(_ holdings: [TrackedAsset]) -> Double? {
    FiniteValueMath.sumNonnegative(
      holdings.filter { $0.pricingStatus == .priced }.map(\.valueUsd)
    )
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

  /// The network a wallet is presented under ("Ethereum", "Osmosis").
  nonisolated static func walletNetworkName(family: ChainFamily, address: String) -> String {
    switch family {
    case .evm: "Ethereum"
    case .bitcoin: "Bitcoin"
    case .solana: "Solana"
    case .tron: "TRON"
    case .xrp: "XRP"
    case .cosmos:
      AddressDetection.detectChains(for: address).first(where: { $0.family == .cosmos })?.name
        ?? "Cosmos"
    case .exchange: "Exchange"
    }
  }

  /// One readable name per wallet for every screen, search, and export.
  /// Wallets saved before readable defaults still carry their truncated
  /// address as the label; those are presented as "<Network> wallet",
  /// numbered in saved order so two of them never share a name.
  nonisolated static func walletDisplayNames(_ wallets: [WalletRecord]) -> [UUID: String] {
    var names: [UUID: String] = [:]
    var taken = Set<String>()
    var legacy: [WalletRecord] = []
    for wallet in wallets {
      if wallet.label == AddressDetection.defaultWalletLabel(wallet.address) {
        legacy.append(wallet)
      } else {
        names[wallet.id] = wallet.label
        taken.insert(wallet.label.lowercased())
      }
    }
    for wallet in legacy {
      let base = "\(walletNetworkName(family: wallet.chainKind, address: wallet.address)) wallet"
      var candidate = base
      var number = 2
      while taken.contains(candidate.lowercased()) {
        candidate = "\(base) \(number)"
        number += 1
      }
      taken.insert(candidate.lowercased())
      names[wallet.id] = candidate
    }
    return names
  }

  /// The presented name of a saved wallet, including an unsaved rename.
  func walletDisplayName(for wallet: WalletRecord) -> String {
    let draft = walletLabelDraft(for: wallet).trimmingCharacters(in: .whitespacesAndNewlines)
    if !draft.isEmpty, draft != AddressDetection.defaultWalletLabel(wallet.address) {
      return draft
    }
    return Self.walletDisplayNames(document.wallets)[wallet.id]
      ?? "\(Self.walletNetworkName(family: wallet.chainKind, address: wallet.address)) wallet"
  }

  static func applyingWalletLabels(
    to holdings: [TrackedAsset],
    wallets: [WalletRecord]
  ) -> [TrackedAsset] {
    var labelsByAddress: [String: String] = [:]
    let displayNames = walletDisplayNames(wallets)
    for wallet in wallets {
      guard
        let canonical = AddressDetection.canonicalAddress(wallet.address, family: wallet.chainKind)
      else { continue }
      labelsByAddress["\(wallet.chainKind.rawValue):\(canonical)"] =
        displayNames[wallet.id] ?? wallet.label
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
      let existing = try credentialVault.open(
        connection.encryptedCredentials,
        vaultKey: vaultKey,
        connectionId: connection.id
      )
      if existing.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == candidate {
        return true
      }
    }
    return false
  }

}
