import CryptoKit
import Foundation

/// Product-wide collection limits. Persistence, sync, recovery, and export all
/// use the same values so no trust boundary can reinterpret an oversized vault.
public enum VaultDocumentLimits {
  public static let maximumStoredScanRuns = 30
  public static let maximumWallets = 24
  public static let maximumCustomTokens = 100
  public static let maximumManualHoldings = 100
  public static let maximumExchangeConnections = 20
  public static let maximumHoldingsPerScan = 10_000
  public static let maximumRemoteVersion = 2_000_000_000
  /// Read-only migration allowance. The app immediately canonicalizes and
  /// trims authenticated historical snapshots to the current 30-run limit.
  public static let maximumLegacyStoredScanRuns = 1_000
}

public enum VaultTextLimits {
  public static let walletLabelCharacters = 80
  public static let walletLabelUTF8Bytes = 2_560
  public static let exchangeLabelCharacters = 80
  public static let exchangeLabelUTF8Bytes = 2_560
  public static let tokenSymbolCharacters = 32
  public static let tokenSymbolUTF8Bytes = 1_024
  public static let tokenNameCharacters = 128
  public static let tokenNameUTF8Bytes = 4_096

  public static func contains(
    _ value: String,
    maximumCharacters: Int,
    maximumUTF8Bytes: Int
  ) -> Bool {
    value.count <= maximumCharacters && value.utf8.count <= maximumUTF8Bytes
  }
}

public enum VaultDocumentValidationContext: Equatable, Sendable {
  case local
  case authenticatedLegacyLocalRead
  case remoteSnapshot(accountId: String)
  case authenticatedLegacyRemoteSnapshot(accountId: String)

  fileprivate var allowsHistoricalNormalization: Bool {
    switch self {
    case .authenticatedLegacyLocalRead, .authenticatedLegacyRemoteSnapshot: true
    case .local, .remoteSnapshot: false
    }
  }

  fileprivate var remoteAccountId: String? {
    switch self {
    case .remoteSnapshot(let accountId), .authenticatedLegacyRemoteSnapshot(let accountId):
      accountId
    case .local, .authenticatedLegacyLocalRead:
      nil
    }
  }
}

public struct VaultDocumentSemanticError: Error, Equatable, LocalizedError, Sendable {
  public var field: String

  public init(field: String) {
    self.field = field
  }

  public var errorDescription: String? {
    "The decrypted vault violates the supported data contract at \(field). No data was changed."
  }
}

/// Strict, side-effect-free semantic gate for authenticated plaintext. AEAD
/// proves who produced bytes; it does not prove that their decoded graph is
/// bounded, non-ambiguous, finite, or safe for later business logic.
public enum VaultDocumentSemanticValidator {
  public static func validate(
    _ document: VaultDocument,
    context: VaultDocumentValidationContext = .local
  ) throws {
    try require(
      document.schemaVersion == VaultDocument.currentSchemaVersion,
      "schemaVersion"
    )
    try finite(document.updatedAt, "updatedAt")
    if context.allowsHistoricalNormalization {
      try boundedTrimmed(document.preferences.currency, maximumUTF8Bytes: 16, "preferences.currency")
    } else {
      try require(document.preferences.currency == "USD", "preferences.currency")
    }
    try nonnegative(document.preferences.dustThreshold, "preferences.dustThreshold")
    try require(document.wallets.count <= VaultDocumentLimits.maximumWallets, "wallets.count")
    try require(
      document.customTokens.count <= VaultDocumentLimits.maximumCustomTokens,
      "customTokens.count"
    )
    try require(
      document.manualHoldings.count <= VaultDocumentLimits.maximumManualHoldings,
      "manualHoldings.count"
    )
    try require(
      document.exchangeConnections.count <= VaultDocumentLimits.maximumExchangeConnections,
      "exchangeConnections.count"
    )
    let scanRunLimit = context.allowsHistoricalNormalization
      ? VaultDocumentLimits.maximumLegacyStoredScanRuns
      : VaultDocumentLimits.maximumStoredScanRuns
    try require(document.scanRuns.count <= scanRunLimit, "scanRuns.count")

    try unique(document.wallets.map(\.id), "wallets.id")
    try unique(document.customTokens.map(\.id), "customTokens.id")
    try unique(document.manualHoldings.map(\.id), "manualHoldings.id")
    try unique(document.exchangeConnections.map(\.id), "exchangeConnections.id")
    try unique(document.scanRuns.map(\.id), "scanRuns.id")

    let manualHoldingsByID = Dictionary(uniqueKeysWithValues: document.manualHoldings.map { ($0.id, $0) })
    let exchangeConnectionsByID = Dictionary(
      uniqueKeysWithValues: document.exchangeConnections.map { ($0.id, $0) }
    )

    var walletIdentities = Set<String>()
    for (index, wallet) in document.wallets.enumerated() {
      let path = "wallets[\(index)]"
      try boundedDisplayText(
        wallet.label,
        maximumCharacters: VaultTextLimits.walletLabelCharacters,
        maximumUTF8Bytes: VaultTextLimits.walletLabelUTF8Bytes,
        "\(path).label"
      )
      try boundedTrimmed(wallet.address, maximumUTF8Bytes: 90, "\(path).address")
      try finite(wallet.createdAt, "\(path).createdAt")
      try finite(wallet.updatedAt, "\(path).updatedAt")
      try require(wallet.updatedAt >= wallet.createdAt, "\(path).updatedAt")
      guard let canonical = AddressDetection.canonicalAddress(
        wallet.address,
        family: wallet.chainKind
      ) else {
        throw VaultDocumentSemanticError(field: "\(path).address")
      }
      try require(
        walletIdentities.insert("\(wallet.chainKind.rawValue):\(canonical)").inserted,
        "wallets.identity"
      )
    }

    var tokenIdentities = Set<String>()
    let evmChainIDs = Set(ChainRegistry.evmChains.map(\.id))
    for (index, token) in document.customTokens.enumerated() {
      let path = "customTokens[\(index)]"
      try require(token.chainKind == .evm || token.chainKind == .solana, "\(path).chainKind")
      try boundedTrimmed(token.chainId, maximumUTF8Bytes: 64, "\(path).chainId")
      if token.chainKind == .evm {
        try require(evmChainIDs.contains(token.chainId), "\(path).chainId")
      } else {
        try require(token.chainId == ChainRegistry.solana.id, "\(path).chainId")
      }
      try require(
        AddressDetection.isValidCustomTokenAddress(token.address, family: token.chainKind),
        "\(path).address"
      )
      guard let canonicalAddress = AddressDetection.canonicalAddress(
        token.address,
        family: token.chainKind
      ) else {
        throw VaultDocumentSemanticError(field: "\(path).address")
      }
      try require(token.address == canonicalAddress, "\(path).address")
      try boundedDisplayText(
        token.symbol,
        maximumCharacters: VaultTextLimits.tokenSymbolCharacters,
        maximumUTF8Bytes: VaultTextLimits.tokenSymbolUTF8Bytes,
        "\(path).symbol"
      )
      try require(token.symbol == token.symbol.uppercased(), "\(path).symbol")
      try boundedDisplayText(
        token.name,
        maximumCharacters: VaultTextLimits.tokenNameCharacters,
        maximumUTF8Bytes: VaultTextLimits.tokenNameUTF8Bytes,
        "\(path).name"
      )
      try require((0...36).contains(token.decimals), "\(path).decimals")
      if let coinGeckoID = token.coinGeckoId {
        if context.allowsHistoricalNormalization {
          try boundedTrimmed(coinGeckoID, maximumUTF8Bytes: 256, "\(path).coinGeckoId")
        } else {
          try require(
            UserInputValidation.normalizedCoinGeckoId(coinGeckoID) == coinGeckoID,
            "\(path).coinGeckoId"
          )
        }
      }
      if let price = token.priceUsd {
        try nonnegative(price, "\(path).priceUsd")
      }
      try finite(token.createdAt, "\(path).createdAt")
      try finite(token.updatedAt, "\(path).updatedAt")
      try require(token.updatedAt >= token.createdAt, "\(path).updatedAt")
      try require(
        tokenIdentities.insert(
          "\(token.chainKind.rawValue):\(token.chainId):\(canonicalAddress)"
        ).inserted,
        "customTokens.identity"
      )
    }

    for (index, holding) in document.manualHoldings.enumerated() {
      let path = "manualHoldings[\(index)]"
      try boundedDisplayText(holding.label, maximumCharacters: 128, maximumUTF8Bytes: 4_096, "\(path).label")
      try boundedDisplayText(holding.provider, maximumCharacters: 64, maximumUTF8Bytes: 2_048, "\(path).provider")
      if let venue = holding.customVenue {
        try boundedDisplayText(venue, maximumCharacters: 128, maximumUTF8Bytes: 4_096, "\(path).customVenue")
      }
      try boundedTrimmed(holding.symbol, maximumUTF8Bytes: 32, "\(path).symbol")
      try require(holding.symbol == holding.symbol.uppercased(), "\(path).symbol")
      try boundedDisplayText(holding.name, maximumCharacters: 128, maximumUTF8Bytes: 4_096, "\(path).name")
      try positive(holding.amount, "\(path).amount")
      if let price = holding.priceUsd { try nonnegative(price, "\(path).priceUsd") }
      try nonnegative(holding.valueUsd, "\(path).valueUsd")
      if let notes = holding.notes {
        try boundedSafeMultiline(notes, maximumUTF8Bytes: 4_096, "\(path).notes")
      }
      try finite(holding.generatedAt, "\(path).generatedAt")
      try finite(holding.createdAt, "\(path).createdAt")
      try finite(holding.updatedAt, "\(path).updatedAt")
      try require(holding.updatedAt >= holding.createdAt, "\(path).updatedAt")
    }

    for (index, connection) in document.exchangeConnections.enumerated() {
      let path = "exchangeConnections[\(index)]"
      try boundedDisplayText(
        connection.label,
        maximumCharacters: VaultTextLimits.exchangeLabelCharacters,
        maximumUTF8Bytes: VaultTextLimits.exchangeLabelUTF8Bytes,
        "\(path).label"
      )
      try validateExchangeEnvelope(
        connection.encryptedCredentials,
        expectedConnectionID: connection.id,
        path: "\(path).encryptedCredentials"
      )
      if let device = connection.krakenDeviceIdentifier {
        try require(
          KrakenDeviceIdentity.normalizedIdentifier(device) == device,
          "\(path).krakenDeviceIdentifier"
        )
      }
      if connection.provider != .kraken {
        try require(connection.krakenDeviceIdentifier == nil, "\(path).krakenDeviceIdentifier")
      }
      if let lastError = connection.lastError {
        try boundedSafeMultiline(lastError, maximumUTF8Bytes: 4_096, "\(path).lastError")
      }
      try finiteOptional(connection.lastTestedAt, "\(path).lastTestedAt")
      try finiteOptional(connection.lastSyncAt, "\(path).lastSyncAt")
      try finite(connection.createdAt, "\(path).createdAt")
      try finite(connection.updatedAt, "\(path).updatedAt")
      try finite(connection.encryptedCredentials.createdAt, "\(path).encryptedCredentials.createdAt")
      try require(connection.updatedAt >= connection.createdAt, "\(path).updatedAt")
      switch connection.status {
      case .empty:
        try require(connection.lastError == nil, "\(path).lastError")
      case .ok:
        try require(
          connection.lastError == nil && connection.lastTestedAt != nil && connection.lastSyncAt != nil,
          "\(path).status"
        )
      case .failed:
        try require(connection.lastError?.isEmpty == false && connection.lastTestedAt != nil, "\(path).status")
      }
    }

    for (runIndex, run) in document.scanRuns.enumerated() {
      let path = "scanRuns[\(runIndex)]"
      try finite(run.generatedAt, "\(path).generatedAt")
      try nonnegative(run.totalUsd, "\(path).totalUsd")
      try require((0...VaultDocumentLimits.maximumWallets).contains(run.inputCount), "\(path).inputCount")
      try require(
        run.holdings.count <= VaultDocumentLimits.maximumHoldingsPerScan,
        "\(path).holdings.count"
      )
      if context.allowsHistoricalNormalization {
        try require(run.warnings.count <= 256, "\(path).warnings.count")
      }
      try unique(run.holdings.map(\.id), "\(path).holdings.id")
      // Reject the raw size before running the sanitizer. The sanitizer does
      // regex-based secret scrubbing and must never receive attacker-sized
      // authenticated plaintext merely to discover that it is oversized.
      for (warningIndex, warning) in run.warnings.enumerated() {
        try boundedSafeMultiline(warning, maximumUTF8Bytes: 4_096, "\(path).warnings[\(warningIndex)]")
      }
      if !context.allowsHistoricalNormalization {
        try require(ScanWarningPolicy.bounded(run.warnings) == run.warnings, "\(path).warnings")
      }
      try require(
        FiniteValueMath.sumNonnegative(run.holdings.map(\.valueUsd)) == run.totalUsd,
        "\(path).totalUsd"
      )
      try validateAssets(
        run.holdings,
        path: "\(path).holdings",
        manualHoldingsByID: manualHoldingsByID,
        exchangeConnectionsByID: exchangeConnectionsByID
      )
    }

    try validateSyncState(document.syncState, context: context)
  }

  public static func validateAssets(_ assets: [TrackedAsset]) throws {
    try require(
      assets.count <= VaultDocumentLimits.maximumHoldingsPerScan,
      "assets.count"
    )
    try unique(assets.map(\.id), "assets.id")
    try validateAssets(
      assets,
      path: "assets",
      manualHoldingsByID: [:],
      exchangeConnectionsByID: [:]
    )
  }

  private static func validateAssets(
    _ assets: [TrackedAsset],
    path: String,
    manualHoldingsByID: [UUID: ManualHoldingRecord],
    exchangeConnectionsByID: [UUID: ExchangeConnectionRecord]
  ) throws {
    for (index, asset) in assets.enumerated() {
      let item = "\(path)[\(index)]"
      try boundedTrimmed(asset.id, maximumUTF8Bytes: 512, "\(item).id")
      try boundedTrimmed(asset.address, maximumUTF8Bytes: 256, "\(item).address")
      try boundedTrimmed(asset.chainId, maximumUTF8Bytes: 64, "\(item).chainId")
      try boundedTrimmed(asset.chainName, maximumUTF8Bytes: 128, "\(item).chainName")
      try boundedTrimmed(asset.symbol, maximumUTF8Bytes: 64, "\(item).symbol")
      try boundedTrimmed(asset.name, maximumUTF8Bytes: 256, "\(item).name")
      try positive(asset.amount, "\(item).amount")
      try nonnegative(asset.priceUsd, "\(item).priceUsd")
      try nonnegative(asset.valueUsd, "\(item).valueUsd")
      try require(asset.status == .ok, "\(item).status")
      if asset.pricingStatus == .unpriced {
        try require(
          asset.priceUsd == 0 && asset.valueUsd == 0,
          "\(item).pricingStatus"
        )
      } else if asset.pricingStatus == .valuationUnavailable {
        try require(asset.valueUsd == 0, "\(item).pricingStatus")
      } else {
        try require(
          FiniteValueMath.multiplyingNonnegative(asset.amount, asset.priceUsd)
            == asset.valueUsd,
          "\(item).valueUsd"
        )
      }
      if let change = asset.change24h { try finite(change, "\(item).change24h") }
      try require(
        asset.explorerUrl.isEmpty || isSafeCanonicalWebURL(asset.explorerUrl),
        "\(item).explorerUrl"
      )
      if let label = asset.walletLabel {
        try boundedTrimmed(label, maximumUTF8Bytes: 256, "\(item).walletLabel")
      }
      switch asset.source {
      case .exchange:
        try require(asset.family == .exchange, "\(item).family")
        switch (asset.exchangeId, asset.exchangeProvider) {
        case (nil, nil):
          // Manual holdings deliberately share the portfolio's exchange-style
          // presentation, but they have no provider credential identity.
          guard asset.id.hasPrefix("manual-"),
            let holdingID = UUID(uuidString: String(asset.id.dropFirst("manual-".count))),
            asset.id == "manual-\(holdingID.uuidString)",
            asset.chainId.hasPrefix("manual-"),
            asset.chainId.utf8.count > "manual-".utf8.count
          else {
            throw VaultDocumentSemanticError(field: "\(item).exchange")
          }
          if let holding = manualHoldingsByID[holdingID] {
            try require(
              asset.chainId == "manual-\(holding.provider)"
                && asset.address == holding.label
                && asset.symbol == holding.symbol
                && asset.name == holding.name
                && asset.amount == holding.amount
                && asset.priceUsd == (holding.priceUsd ?? 0)
                && asset.valueUsd == holding.valueUsd,
              "\(item).exchange"
            )
          }
        case (let exchangeID?, let provider?):
          try require(
            asset.id == "\(exchangeID.uuidString)-\(provider.rawValue)-\(asset.symbol)"
              && asset.chainId == provider.rawValue,
            "\(item).exchange"
          )
          if let connection = exchangeConnectionsByID[exchangeID] {
            try require(
              connection.provider == provider && asset.walletLabel == connection.label,
              "\(item).exchange"
            )
          }
        default:
          throw VaultDocumentSemanticError(field: "\(item).exchange")
        }
      case .erc20:
        try require(
          asset.family == .evm && asset.exchangeId == nil && asset.exchangeProvider == nil,
          "\(item).family"
        )
      case .spl:
        try require(
          asset.family == .solana && asset.exchangeId == nil && asset.exchangeProvider == nil,
          "\(item).family"
        )
      case .trc20:
        try require(
          asset.family == .tron && asset.exchangeId == nil && asset.exchangeProvider == nil,
          "\(item).family"
        )
      case .issued:
        try require(
          asset.family == .xrp && asset.exchangeId == nil && asset.exchangeProvider == nil,
          "\(item).family"
        )
      case .staked, .rewards:
        try require(
          asset.family == .cosmos && asset.exchangeId == nil && asset.exchangeProvider == nil,
          "\(item).family"
        )
      case .native:
        try require(
          asset.family != .exchange && asset.exchangeId == nil && asset.exchangeProvider == nil,
          "\(item).family"
        )
      }
      if asset.family != .exchange {
        try require(
          AddressDetection.canonicalAddress(asset.address, family: asset.family) != nil,
          "\(item).address"
        )
      }
    }
  }

  private static func validateSyncState(
    _ state: SyncState,
    context: VaultDocumentValidationContext
  ) throws {
    if let remoteAccount = context.remoteAccountId {
      try require(
        SyncAccountIdentifier.normalized(remoteAccount) == remoteAccount
          && state.accountId == remoteAccount,
        "syncState.accountId"
      )
      try require(state.serverURL.isEmpty, "syncState.serverURL")
      try require(state.sessionToken.isEmpty, "syncState.sessionToken")
      try require(!state.remoteOutcomeUncertain, "syncState.remoteOutcomeUncertain")
      try require(
        !state.pendingExchangeCredentialCleanup,
        "syncState.pendingExchangeCredentialCleanup"
      )
      try require(state.accountDeletionIdempotencyKey == nil, "syncState.accountDeletionIdempotencyKey")
    }
    if let accountID = state.accountId {
      try require(SyncAccountIdentifier.normalized(accountID) == accountID, "syncState.accountId")
    } else {
      try require(state.sessionToken.isEmpty, "syncState.sessionToken")
      try require(state.latestRemoteVersion == 0, "syncState.latestRemoteVersion")
      try require(state.lastSyncedAt == nil, "syncState.lastSyncedAt")
      try require(state.lastChecksum == nil, "syncState.lastChecksum")
      try require(state.lastSyncedContentChecksum == nil, "syncState.lastSyncedContentChecksum")
      try require(!state.remoteOutcomeUncertain, "syncState.remoteOutcomeUncertain")
      try require(
        !state.pendingExchangeCredentialCleanup,
        "syncState.pendingExchangeCredentialCleanup"
      )
      try require(state.accountDeletionIdempotencyKey == nil, "syncState.accountDeletionIdempotencyKey")
    }
    if context.remoteAccountId == nil, state.accountId != nil {
      if context.allowsHistoricalNormalization {
        try bounded(state.serverURL, maximumUTF8Bytes: 2_048, "syncState.serverURL")
      } else {
        try require(
          SyncServerURL.validatedOrigin(state.serverURL)?.absoluteString == state.serverURL,
          "syncState.serverURL"
        )
      }
    } else if state.accountId == nil, !state.serverURL.isEmpty {
      try require(
        SyncServerURL.validatedOrigin(state.serverURL)?.absoluteString == state.serverURL,
        "syncState.serverURL"
      )
    }
    if !state.sessionToken.isEmpty {
      try require(
        state.accountId.map {
          SyncSessionToken.isValid(state.sessionToken, forAccountId: $0)
        } == true,
        "syncState.sessionToken"
      )
    }
    try require(
      (0...VaultDocumentLimits.maximumRemoteVersion).contains(state.latestRemoteVersion),
      "syncState.latestRemoteVersion"
    )
    try finiteOptional(state.lastSyncedAt, "syncState.lastSyncedAt")
    if let checksum = state.lastChecksum {
      try require(isChecksum(checksum), "syncState.lastChecksum")
    }
    if let checksum = state.lastSyncedContentChecksum {
      try require(isChecksum(checksum), "syncState.lastSyncedContentChecksum")
    }
    if let key = state.accountDeletionIdempotencyKey {
      try require(AccountDeletionIdempotencyKey.normalized(key) == key, "syncState.accountDeletionIdempotencyKey")
      try require(state.accountId != nil, "syncState.accountDeletionIdempotencyKey")
    }
    if state.remoteOutcomeUncertain {
      try require(state.accountId != nil, "syncState.remoteOutcomeUncertain")
    }
    if state.pendingExchangeCredentialCleanup {
      try require(state.accountId != nil, "syncState.pendingExchangeCredentialCleanup")
    }
    if state.latestRemoteVersion == 0 {
      try require(
        state.lastSyncedAt == nil && state.lastChecksum == nil
          && state.lastSyncedContentChecksum == nil,
        "syncState.remoteBaseline"
      )
    } else {
      // Content checksums were introduced after the original sync format.
      // A nil content checksum remains an explicit read-only legacy state; the
      // next successful sync writes the complete tuple.
      try require(
        state.lastSyncedAt != nil && state.lastChecksum != nil,
        "syncState.remoteBaseline"
      )
    }
  }

  private static func unique<T: Hashable>(_ values: [T], _ field: String) throws {
    try require(Set(values).count == values.count, field)
  }

  private static func validateExchangeEnvelope(
    _ envelope: EncryptedVaultEnvelope,
    expectedConnectionID: UUID,
    path: String
  ) throws {
    try require(envelope.schemaVersion == 1, "\(path).schemaVersion")
    try require(envelope.cryptoVersion == 1, "\(path).cryptoVersion")
    try require(
      envelope.keyId == "exchange-\(expectedConnectionID.uuidString)",
      "\(path).keyId"
    )
    guard let nonce = try? Base64URL.decode(envelope.nonce),
      nonce.count == 12,
      Base64URL.encode(nonce) == envelope.nonce,
      let ciphertext = try? Base64URL.decode(envelope.ciphertext),
      (16...65_536).contains(ciphertext.count),
      Base64URL.encode(ciphertext) == envelope.ciphertext,
      isChecksum(envelope.checksum)
    else {
      throw VaultDocumentSemanticError(field: path)
    }
    var checksumInput = Data(
      "schema:\(envelope.schemaVersion)|crypto:\(envelope.cryptoVersion)|key:\(envelope.keyId)|".utf8
    )
    checksumInput.append(nonce)
    checksumInput.append(ciphertext)
    try require(
      Data(SHA256.hash(data: checksumInput)).hexString == envelope.checksum,
      "\(path).checksum"
    )
  }

  public static func validateExchangeCredentialPayloads(
    in document: VaultDocument,
    vaultKey: Data,
    crypto: VaultCrypto = VaultCrypto()
  ) throws {
    let credentialKey = try crypto.deriveKey(from: vaultKey, purpose: .exchangeCredentials)
    try validateExchangeCredentialPayloads(
      in: document,
      credentialKey: credentialKey,
      crypto: crypto
    )
  }

  public static func validateExchangeCredentialPayloads(
    in document: VaultDocument,
    credentialKey: SymmetricKey,
    crypto: VaultCrypto = VaultCrypto()
  ) throws {
    var credentialIdentities = Set<String>()
    for (index, connection) in document.exchangeConnections.enumerated() {
      let credentials = try crypto.openJSON(
        ExchangeCredentials.self,
        envelope: connection.encryptedCredentials,
        with: credentialKey
      )
      let path = "exchangeConnections[\(index)].encryptedCredentials"
      try require(
        !credentials.apiKey.isEmpty
          && credentials.apiKey == credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
          && credentials.apiKey.utf8.count <= 4_096,
        "\(path).apiKey"
      )
      try require(
        !credentials.secret.isEmpty
          && credentials.secret == credentials.secret.trimmingCharacters(in: .whitespacesAndNewlines)
          && credentials.secret.utf8.count <= 32_768,
        "\(path).secret"
      )
      if let passphrase = credentials.passphrase {
        try require(
          !passphrase.isEmpty
            && passphrase == passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
            && passphrase.utf8.count <= 4_096,
          "\(path).passphrase"
        )
      }
      var identity = Data(connection.provider.rawValue.utf8)
      identity.append(0)
      identity.append(Data(credentials.apiKey.utf8))
      try require(
        credentialIdentities.insert(Data(SHA256.hash(data: identity)).hexString).inserted,
        "\(path).duplicateIdentity"
      )
    }
  }

  private static func isSafeCanonicalWebURL(_ value: String) -> Bool {
    guard value.utf8.count <= 2_048,
      let components = URLComponents(string: value),
      components.scheme == "https",
      components.host?.isEmpty == false,
      components.user == nil,
      components.password == nil,
      components.url?.absoluteString == value
    else {
      return false
    }
    return true
  }

  private static func boundedDisplayText(
    _ value: String,
    maximumCharacters: Int,
    maximumUTF8Bytes: Int,
    _ field: String
  ) throws {
    try boundedTrimmed(value, maximumUTF8Bytes: maximumUTF8Bytes, field)
    try require(value.count <= maximumCharacters && hasSafeDisplayScalars(value), field)
  }

  private static func boundedSafeMultiline(
    _ value: String,
    maximumUTF8Bytes: Int,
    _ field: String
  ) throws {
    try bounded(value, maximumUTF8Bytes: maximumUTF8Bytes, field)
    try require(hasSafeDisplayScalars(value, permitsLineBreaks: true), field)
  }

  private static func hasSafeDisplayScalars(
    _ value: String,
    permitsLineBreaks: Bool = false
  ) -> Bool {
    value.unicodeScalars.allSatisfy { scalar in
      let code = scalar.value
      if (0x202A...0x202E).contains(code) || (0x2066...0x2069).contains(code) {
        return false
      }
      if code < 0x20 || code == 0x7F {
        return permitsLineBreaks && (code == 0x09 || code == 0x0A || code == 0x0D)
      }
      return true
    }
  }

  private static func boundedTrimmed(
    _ value: String,
    maximumUTF8Bytes: Int,
    _ field: String
  ) throws {
    try require(
      !value.isEmpty
        && value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      field
    )
    try bounded(value, maximumUTF8Bytes: maximumUTF8Bytes, field)
  }

  private static func bounded(_ value: String, maximumUTF8Bytes: Int, _ field: String) throws {
    try require(value.utf8.count <= maximumUTF8Bytes, field)
  }

  private static func finiteOptional(_ value: Date?, _ field: String) throws {
    if let value { try finite(value, field) }
  }

  private static func finite(_ value: Date, _ field: String) throws {
    try require(value.timeIntervalSince1970.isFinite, field)
  }

  private static func finite(_ value: Double, _ field: String) throws {
    try require(value.isFinite, field)
  }

  private static func nonnegative(_ value: Double, _ field: String) throws {
    try require(value.isFinite && value >= 0, field)
  }

  private static func positive(_ value: Double, _ field: String) throws {
    try require(value.isFinite && value > 0, field)
  }

  private static func isChecksum(_ value: String) -> Bool {
    value.count == 64
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
      }
  }

  private static func require(_ condition: @autoclosure () -> Bool, _ field: String) throws {
    guard condition() else { throw VaultDocumentSemanticError(field: field) }
  }
}
