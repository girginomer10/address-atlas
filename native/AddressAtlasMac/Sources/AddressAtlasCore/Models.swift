import Foundation

public enum ChainFamily: String, Codable, CaseIterable, Sendable {
  case bitcoin
  case cosmos
  case evm
  case solana
  case tron
  case xrp
  case exchange
}

public enum AssetSource: String, Codable, Sendable {
  case native
  case erc20
  case spl
  case trc20
  case issued
  case exchange
  case staked
  case rewards
}

public enum ScanStatus: String, Codable, Sendable {
  case ok
  case empty
  case failed
}

/// Whether a holding's USD columns are measured values or intentionally
/// unknown. Numeric zero cannot carry this distinction: a real quoted price
/// may be exactly zero, while a missing quote was historically also encoded
/// as zero.
public enum AssetPricingStatus: String, Codable, Sendable {
  case priced
  case unpriced
  case valuationUnavailable = "valuation_unavailable"
}

public enum ExchangeProvider: String, Codable, CaseIterable, Hashable, Sendable {
  case binance
  case coinbase
  case kraken

  public var label: String {
    switch self {
    case .binance: "Binance"
    case .coinbase: "Coinbase"
    case .kraken: "Kraken"
    }
  }
}

public struct WalletRecord: Codable, Identifiable, Hashable, Sendable {
  public var id: UUID
  public var label: String
  public var address: String
  public var chainKind: ChainFamily
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    label: String,
    address: String,
    chainKind: ChainFamily,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.label = label
    self.address = address
    self.chainKind = chainKind
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct Preferences: Codable, Equatable, Sendable {
  public var darkMode: Bool
  public var density: Density
  public var mono: Bool
  public var hideDust: Bool
  public var dustThreshold: Double
  public var autoRefresh: Bool
  public var currency: String

  public enum Density: String, Codable, Sendable {
    case compact
    case comfy
  }

  public init(
    darkMode: Bool = false,
    density: Density = .comfy,
    mono: Bool = false,
    hideDust: Bool = false,
    dustThreshold: Double = 5,
    autoRefresh: Bool = true,
    currency: String = "USD"
  ) {
    self.darkMode = darkMode
    self.density = density
    self.mono = mono
    self.hideDust = hideDust
    self.dustThreshold = dustThreshold
    self.autoRefresh = autoRefresh
    self.currency = currency
  }
}

public struct CustomTokenRecord: Codable, Identifiable, Hashable, Sendable {
  public var id: UUID
  public var chainKind: ChainFamily
  public var chainId: String
  public var address: String
  public var symbol: String
  public var name: String
  public var decimals: Int
  public var coinGeckoId: String?
  public var priceUsd: Double?
  public var enabled: Bool
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    chainKind: ChainFamily,
    chainId: String,
    address: String,
    symbol: String,
    name: String,
    decimals: Int,
    coinGeckoId: String? = nil,
    priceUsd: Double? = nil,
    enabled: Bool = true,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.chainKind = chainKind
    self.chainId = chainId
    self.address = address
    self.symbol = symbol
    self.name = name
    self.decimals = decimals
    self.coinGeckoId = coinGeckoId
    self.priceUsd = priceUsd
    self.enabled = enabled
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct ManualHoldingRecord: Codable, Identifiable, Hashable, Sendable {
  public var id: UUID
  public var label: String
  public var provider: String
  public var customVenue: String?
  public var symbol: String
  public var name: String
  public var amount: Double
  public var priceUsd: Double?
  public var valueUsd: Double
  public var notes: String?
  public var enabled: Bool
  public var generatedAt: Date
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    label: String,
    provider: String,
    customVenue: String? = nil,
    symbol: String,
    name: String,
    amount: Double,
    priceUsd: Double?,
    valueUsd: Double,
    notes: String? = nil,
    enabled: Bool = true,
    generatedAt: Date = Date(),
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.label = label
    self.provider = provider
    self.customVenue = customVenue
    self.symbol = symbol
    self.name = name
    self.amount = amount
    self.priceUsd = priceUsd
    self.valueUsd = valueUsd
    self.notes = notes
    self.enabled = enabled
    self.generatedAt = generatedAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum ExchangeCredentialScopeAssurance: String, Codable, Hashable, Sendable {
  case verifiedReadOnly
  case manualVerificationRequired
}

public struct ExchangeConnectionRecord: Codable, Identifiable, Hashable, Sendable {
  public var id: UUID
  public var provider: ExchangeProvider
  public var label: String
  public var encryptedCredentials: EncryptedVaultEnvelope
  /// Kraken rejects any nonce that is not greater than the last nonce seen for
  /// an API key. Binding each Kraken connection to one local installation keeps
  /// a synced credential from being used concurrently by unsynchronised Macs.
  public var krakenDeviceIdentifier: String?
  /// Nil only for records created before provider-aware scope validation was
  /// introduced. The UI treats nil conservatively as unverified.
  public var credentialScopeAssurance: ExchangeCredentialScopeAssurance?
  public var status: ScanStatus
  public var lastTestedAt: Date?
  public var lastSyncAt: Date?
  public var lastError: String?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    provider: ExchangeProvider,
    label: String,
    encryptedCredentials: EncryptedVaultEnvelope,
    krakenDeviceIdentifier: String? = nil,
    credentialScopeAssurance: ExchangeCredentialScopeAssurance? = nil,
    status: ScanStatus = .empty,
    lastTestedAt: Date? = nil,
    lastSyncAt: Date? = nil,
    lastError: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.provider = provider
    self.label = label
    self.encryptedCredentials = encryptedCredentials
    self.krakenDeviceIdentifier = krakenDeviceIdentifier
    self.credentialScopeAssurance = credentialScopeAssurance
    self.status = status
    self.lastTestedAt = lastTestedAt
    self.lastSyncAt = lastSyncAt
    self.lastError = lastError
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

/// The backend issues UUID account IDs and embeds the same UUID in its signed
/// session token. Keep callback parsing and persistence on one canonical rule
/// so malformed callback data can never become durable sync state.
public enum SyncAccountIdentifier {
  public static let maximumUTF8ByteCount = 36

  public static func normalized(_ candidate: String) -> String? {
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    let bytes = Array(trimmed.utf8)
    guard bytes.count == maximumUTF8ByteCount else { return nil }

    let hyphenIndexes: Set<Int> = [8, 13, 18, 23]
    for (index, byte) in bytes.enumerated() {
      if hyphenIndexes.contains(index) {
        guard byte == 45 else { return nil }
      } else {
        guard (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        else {
          return nil
        }
      }
    }

    // Match the server's UUID invariant: RFC variant plus versions 1 through 8.
    guard "12345678".utf8.contains(bytes[14]), "89abAB".utf8.contains(bytes[19]) else {
      return nil
    }
    return trimmed.lowercased()
  }
}

/// Session tokens are opaque to the Mac, but they are later placed verbatim in
/// an HTTP Authorization header. Bound their size to the server contract and
/// accept only visible token characters so a compromised or malformed callback
/// cannot persist control characters or an unbounded header value.
public struct SyncSessionTokenClaims: Equatable, Sendable {
  public var userId: String
  public var sessionId: String
  public var issuedAt: Int64
  public var expiresAt: Int64
}

public enum SyncSessionToken {
  public static let maximumUTF8ByteCount = 4_096
  public static let maximumLifetimeMilliseconds: Int64 = 12 * 60 * 60 * 1_000

  private struct Payload: Decodable {
    var userId: String
    var sessionId: String
    var issuedAt: Int64
    var expiresAt: Int64
  }

  public static func isValid(_ candidate: String) -> Bool {
    claims(candidate) != nil
  }

  public static func isValid(_ candidate: String, forAccountId accountId: String) -> Bool {
    guard let normalizedAccount = SyncAccountIdentifier.normalized(accountId),
      let claims = claims(candidate)
    else { return false }
    return claims.userId == normalizedAccount
  }

  public static func isUsable(
    _ candidate: String,
    forAccountId accountId: String,
    at date: Date = Date()
  ) -> Bool {
    guard let normalizedAccount = SyncAccountIdentifier.normalized(accountId),
      let claims = claims(candidate), claims.userId == normalizedAccount
    else {
      return false
    }
    return isUsable(claims, at: date)
  }

  public static func isUsable(_ candidate: String, at date: Date = Date()) -> Bool {
    guard let claims = claims(candidate) else { return false }
    return isUsable(claims, at: date)
  }

  private static func isUsable(_ claims: SyncSessionTokenClaims, at date: Date) -> Bool {
    let nowMilliseconds = Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    return claims.issuedAt <= nowMilliseconds + 30_000
      && nowMilliseconds < claims.expiresAt
  }

  /// Parses the server's signed token envelope without claiming to verify its
  /// HMAC (only the server has that secret). Exact shape and account binding
  /// are still enforceable locally and prevent pairing an otherwise plausible
  /// bearer for account B with account A's encrypted-vault identity.
  public static func claims(_ candidate: String) -> SyncSessionTokenClaims? {
    let bytes = candidate.utf8
    guard !bytes.isEmpty, bytes.count <= maximumUTF8ByteCount else { return nil }
    guard bytes.allSatisfy({ byte in
      (48...57).contains(byte)
        || (65...90).contains(byte)
        || (97...122).contains(byte)
        || byte == 45  // -
        || byte == 46  // .
        || byte == 43  // +
        || byte == 47  // /
        || byte == 61  // =
        || byte == 95  // _
        || byte == 126  // ~
    }) else { return nil }
    let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4, parts[0] == "v1", parts[1] == "session" else { return nil }
    let encodedPayload = String(parts[2])
    let encodedSignature = String(parts[3])
    guard let payloadData = try? Base64URL.decode(encodedPayload),
      Base64URL.encode(payloadData) == encodedPayload,
      let signature = try? Base64URL.decode(encodedSignature),
      signature.count == 32,
      Base64URL.encode(signature) == encodedSignature,
      let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
      Set(object.keys) == Set(["userId", "sessionId", "issuedAt", "expiresAt"]),
      let payload = try? JSONDecoder().decode(Payload.self, from: payloadData),
      let userId = SyncAccountIdentifier.normalized(payload.userId), userId == payload.userId,
      let sessionId = SyncAccountIdentifier.normalized(payload.sessionId), sessionId == payload.sessionId,
      payload.issuedAt >= 0,
      payload.expiresAt > payload.issuedAt,
      payload.expiresAt - payload.issuedAt <= maximumLifetimeMilliseconds
    else { return nil }
    return SyncSessionTokenClaims(
      userId: userId,
      sessionId: sessionId,
      issuedAt: payload.issuedAt,
      expiresAt: payload.expiresAt
    )
  }
}

/// A deletion operation key is persisted before the destructive request and
/// replayed until the server acknowledges it. Exactly 32 random bytes encoded
/// as canonical, unpadded base64url gives one stable 43-character identity
/// without accepting alternate textual representations.
public enum AccountDeletionIdempotencyKey {
  public static let encodedCharacterCount = 43
  public static let decodedByteCount = 32

  public static func normalized(_ candidate: String?) -> String? {
    guard let candidate, candidate.count == encodedCharacterCount,
      let decoded = try? Base64URL.decode(candidate),
      decoded.count == decodedByteCount
    else {
      return nil
    }
    return candidate
  }
}

/// Checked arithmetic for values that can cross provider, portfolio, and
/// persistence boundaries. Swift floating-point operations intentionally
/// produce infinities instead of trapping, but JSONEncoder rejects those
/// values. Every scan therefore has to reject an unrepresentable result before
/// it can become part of a durable vault snapshot.
public enum FiniteValueMath {
  public static func addingNonnegative(_ lhs: Double, _ rhs: Double) -> Double? {
    guard lhs.isFinite, lhs >= 0, rhs.isFinite, rhs >= 0 else { return nil }
    let result = lhs + rhs
    return result.isFinite ? result : nil
  }

  public static func multiplyingNonnegative(_ lhs: Double, _ rhs: Double) -> Double? {
    guard lhs.isFinite, lhs >= 0, rhs.isFinite, rhs >= 0 else { return nil }
    let result = lhs * rhs
    return result.isFinite ? result : nil
  }

  public static func sumNonnegative<S: Sequence>(_ values: S) -> Double? where S.Element == Double {
    var total = 0.0
    for value in values {
      guard let next = addingNonnegative(total, value) else { return nil }
      total = next
    }
    return total
  }

  public static func finiteOptional(_ value: Double?) -> Double? {
    value.flatMap { $0.isFinite ? $0 : nil }
  }
}

public enum PortfolioValueError: Error, Equatable, LocalizedError, Sendable {
  case totalExceedsSupportedRange

  public var errorDescription: String? {
    switch self {
    case .totalExceedsSupportedRange:
      return "The portfolio total exceeds the supported numeric range. No snapshot was saved."
    }
  }
}

public struct TrackedAsset: Codable, Identifiable, Hashable, Sendable {
  public var id: String
  public var address: String
  public var chainId: String
  public var chainName: String
  public var family: ChainFamily
  public var symbol: String
  public var name: String
  public var amount: Double {
    didSet {
      guard amount != oldValue else { return }
      exactAmount = Self.validatedExactAmount(
        nil,
        approximateAmount: amount,
        source: source
      )
    }
  }
  /// Canonical base-10 amount for exchange holdings. `amount` is retained as
  /// the explicit binary-floating-point approximation used by valuation code.
  public private(set) var exactAmount: String?
  public var priceUsd: Double
  public var valueUsd: Double
  public var pricingStatus: AssetPricingStatus
  public var change24h: Double?
  public var explorerUrl: String
  public var source: AssetSource {
    didSet {
      guard source != oldValue else { return }
      exactAmount = Self.validatedExactAmount(
        exactAmount,
        approximateAmount: amount,
        source: source
      )
    }
  }
  public var status: ScanStatus
  public var walletLabel: String?
  public var exchangeId: UUID?
  public var exchangeProvider: ExchangeProvider?

  public init(
    id: String,
    address: String,
    chainId: String,
    chainName: String,
    family: ChainFamily,
    symbol: String,
    name: String,
    amount: Double,
    exactAmount: String? = nil,
    priceUsd: Double,
    valueUsd: Double,
    pricingStatus: AssetPricingStatus? = nil,
    change24h: Double? = nil,
    explorerUrl: String = "",
    source: AssetSource,
    status: ScanStatus = .ok,
    walletLabel: String? = nil,
    exchangeId: UUID? = nil,
    exchangeProvider: ExchangeProvider? = nil
  ) {
    self.id = id
    self.address = address
    self.chainId = chainId
    self.chainName = chainName
    self.family = family
    self.symbol = symbol
    self.name = name
    self.amount = amount
    self.exactAmount = Self.validatedExactAmount(
      exactAmount,
      approximateAmount: amount,
      source: source
    )
    self.priceUsd = priceUsd
    self.valueUsd = valueUsd
    self.pricingStatus = pricingStatus
      ?? ((priceUsd > 0 || valueUsd > 0) ? .priced : .unpriced)
    self.change24h = change24h
    self.explorerUrl = explorerUrl
    self.source = source
    self.status = status
    self.walletLabel = walletLabel
    self.exchangeId = exchangeId
    self.exchangeProvider = exchangeProvider
  }

  /// Exact, locale-independent amount used by exports and exchange UI. Legacy
  /// non-exchange records continue to use their existing Double representation.
  public var canonicalAmount: String {
    exactAmount ?? String(amount)
  }

  public var displayedAmount: String {
    displayedAmount(locale: .autoupdatingCurrent)
  }

  public func displayedAmount(locale: Locale) -> String {
    exactAmount ?? amount.formatted(.number.locale(locale))
  }

  private static func validatedExactAmount(
    _ candidate: String?,
    approximateAmount: Double,
    source: AssetSource
  ) -> String? {
    guard source == .exchange else { return nil }
    if let candidate,
      let exact = ExchangeAmount(providerString: candidate),
      exact.approximateDouble == approximateAmount
    {
      return exact.canonicalString
    }
    return ExchangeAmount(legacyDouble: approximateAmount)?.canonicalString
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case address
    case chainId
    case chainName
    case family
    case symbol
    case name
    case amount
    case exactAmount
    case priceUsd
    case valueUsd
    case pricingStatus
    case change24h
    case explorerUrl
    case source
    case status
    case walletLabel
    case exchangeId
    case exchangeProvider
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    address = try container.decode(String.self, forKey: .address)
    chainId = try container.decode(String.self, forKey: .chainId)
    chainName = try container.decode(String.self, forKey: .chainName)
    family = try container.decode(ChainFamily.self, forKey: .family)
    symbol = try container.decode(String.self, forKey: .symbol)
    name = try container.decode(String.self, forKey: .name)
    amount = try container.decode(Double.self, forKey: .amount)
    priceUsd = try container.decode(Double.self, forKey: .priceUsd)
    valueUsd = try container.decode(Double.self, forKey: .valueUsd)
    // pricingStatus was introduced without changing the vault schema. Legacy
    // rows can only recover the old display rule; every newly scanned row
    // persists the explicit status and can distinguish known zero from unknown.
    pricingStatus = try container.decodeIfPresent(
      AssetPricingStatus.self,
      forKey: .pricingStatus
    ) ?? ((priceUsd > 0 || valueUsd > 0) ? .priced : .unpriced)
    change24h = try container.decodeIfPresent(Double.self, forKey: .change24h)
    explorerUrl = try container.decode(String.self, forKey: .explorerUrl)
    source = try container.decode(AssetSource.self, forKey: .source)
    status = try container.decode(ScanStatus.self, forKey: .status)
    walletLabel = try container.decodeIfPresent(String.self, forKey: .walletLabel)
    exchangeId = try container.decodeIfPresent(UUID.self, forKey: .exchangeId)
    exchangeProvider = try container.decodeIfPresent(
      ExchangeProvider.self,
      forKey: .exchangeProvider
    )
    let encodedExactAmount = try container.decodeIfPresent(String.self, forKey: .exactAmount)
    if source == .exchange {
      if let encodedExactAmount {
        guard
          let validated = Self.validatedExactAmount(
            encodedExactAmount,
            approximateAmount: amount,
            source: source
          ),
          validated == encodedExactAmount
        else {
          throw DecodingError.dataCorruptedError(
            forKey: .exactAmount,
            in: container,
            debugDescription: "Exchange exactAmount is malformed or disagrees with amount."
          )
        }
        exactAmount = validated
      } else {
        // exactAmount was added without a vault schema bump. Its absence is
        // the one explicit v2 legacy case; derive a canonical representation.
        exactAmount = Self.validatedExactAmount(nil, approximateAmount: amount, source: source)
      }
    } else {
      guard encodedExactAmount == nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .exactAmount,
          in: container,
          debugDescription: "Only exchange holdings may carry exactAmount."
        )
      }
      exactAmount = nil
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(address, forKey: .address)
    try container.encode(chainId, forKey: .chainId)
    try container.encode(chainName, forKey: .chainName)
    try container.encode(family, forKey: .family)
    try container.encode(symbol, forKey: .symbol)
    try container.encode(name, forKey: .name)
    try container.encode(amount, forKey: .amount)
    try container.encodeIfPresent(exactAmount, forKey: .exactAmount)
    try container.encode(priceUsd, forKey: .priceUsd)
    try container.encode(valueUsd, forKey: .valueUsd)
    try container.encode(pricingStatus, forKey: .pricingStatus)
    try container.encodeIfPresent(change24h, forKey: .change24h)
    try container.encode(explorerUrl, forKey: .explorerUrl)
    try container.encode(source, forKey: .source)
    try container.encode(status, forKey: .status)
    try container.encodeIfPresent(walletLabel, forKey: .walletLabel)
    try container.encodeIfPresent(exchangeId, forKey: .exchangeId)
    try container.encodeIfPresent(exchangeProvider, forKey: .exchangeProvider)
  }
}

public struct ScanRunRecord: Codable, Identifiable, Hashable, Sendable {
  public var id: UUID
  public var generatedAt: Date
  public var totalUsd: Double
  public var inputCount: Int
  public var holdings: [TrackedAsset]
  public var warnings: [String]

  public init(
    id: UUID = UUID(),
    generatedAt: Date = Date(),
    totalUsd: Double,
    inputCount: Int,
    holdings: [TrackedAsset],
    warnings: [String] = []
  ) {
    self.id = id
    self.generatedAt = generatedAt
    self.totalUsd = totalUsd
    self.inputCount = inputCount
    self.holdings = holdings
    self.warnings = warnings
  }
}

public struct SyncState: Codable, Equatable, Sendable {
  public var accountId: String?
  public var serverURL: String
  public var sessionToken: String
  public var latestRemoteVersion: Int
  public var lastSyncedAt: Date?
  public var lastChecksum: String?
  /// SHA-256 of the user-controlled vault content at the last successful sync.
  /// Authentication/session fields are deliberately excluded from this digest.
  public var lastSyncedContentChecksum: String?
  /// True when an upload may have committed remotely but the user explicitly
  /// stopped replay. It forces every subsequent download through the discard
  /// confirmation path, including for an otherwise empty vault.
  public var remoteOutcomeUncertain: Bool
  /// Local-only reminder that a removed exchange credential may still exist
  /// inside the last confirmed encrypted remote snapshot. A successful
  /// replacement upload clears it; remote snapshots never contain it.
  public var pendingExchangeCredentialCleanup: Bool
  /// Local-only operation identity for replay-safe remote account deletion.
  /// VaultSyncCodec strips it from encrypted server snapshots.
  public var accountDeletionIdempotencyKey: String?

  enum CodingKeys: String, CodingKey {
    case accountId
    case serverURL
    case sessionToken
    case latestRemoteVersion
    case lastSyncedAt
    case lastChecksum
    case lastSyncedContentChecksum
    case remoteOutcomeUncertain
    case pendingExchangeCredentialCleanup
    case accountDeletionIdempotencyKey
  }

  public init(
    accountId: String? = nil,
    serverURL: String = "",
    sessionToken: String = "",
    latestRemoteVersion: Int = 0,
    lastSyncedAt: Date? = nil,
    lastChecksum: String? = nil,
    lastSyncedContentChecksum: String? = nil,
    remoteOutcomeUncertain: Bool = false,
    pendingExchangeCredentialCleanup: Bool = false,
    accountDeletionIdempotencyKey: String? = nil
  ) {
    self.accountId = accountId
    self.serverURL = serverURL
    self.sessionToken = sessionToken
    self.latestRemoteVersion = latestRemoteVersion
    self.lastSyncedAt = lastSyncedAt
    self.lastChecksum = lastChecksum
    self.lastSyncedContentChecksum = lastSyncedContentChecksum
    self.remoteOutcomeUncertain = remoteOutcomeUncertain
    self.pendingExchangeCredentialCleanup = pendingExchangeCredentialCleanup
    self.accountDeletionIdempotencyKey = AccountDeletionIdempotencyKey.normalized(
      accountDeletionIdempotencyKey
    )
  }

  /// Decode old schema-v1 documents whose sync state predates server/session
  /// fields and content-baseline tracking.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let storedAccountId = try container.decodeIfPresent(String.self, forKey: .accountId)
    accountId = storedAccountId.flatMap(SyncAccountIdentifier.normalized)
    serverURL = try container.decodeIfPresent(String.self, forKey: .serverURL) ?? ""
    sessionToken = try container.decodeIfPresent(String.self, forKey: .sessionToken) ?? ""
    latestRemoteVersion = max(
      0, try container.decodeIfPresent(Int.self, forKey: .latestRemoteVersion) ?? 0)
    lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
    lastChecksum = try container.decodeIfPresent(String.self, forKey: .lastChecksum)
    lastSyncedContentChecksum = try container.decodeIfPresent(
      String.self, forKey: .lastSyncedContentChecksum)
    remoteOutcomeUncertain =
      try container.decodeIfPresent(Bool.self, forKey: .remoteOutcomeUncertain) ?? false
    pendingExchangeCredentialCleanup =
      try container.decodeIfPresent(Bool.self, forKey: .pendingExchangeCredentialCleanup) ?? false
    accountDeletionIdempotencyKey = AccountDeletionIdempotencyKey.normalized(
      try container.decodeIfPresent(String.self, forKey: .accountDeletionIdempotencyKey)
    )
    if accountId == nil {
      // Missing and malformed persisted identities cannot safely authorize
      // requests or identify a remote baseline. Force a fresh passkey sign-in
      // instead of carrying bearer or version metadata forward.
      sessionToken = ""
      accountDeletionIdempotencyKey = nil
      clearRemoteTracking()
    } else if !sessionToken.isEmpty,
      !SyncSessionToken.isUsable(sessionToken, forAccountId: accountId!)
    {
      // Preserve the authenticated remote baseline, but force a fresh sign-in
      // before any Authorization header is constructed.
      sessionToken = ""
    }
  }

  /// Switch the sync authority without ever forwarding the previous server's
  /// bearer token or treating its version/checksum as a baseline on the new one.
  public mutating func changeServer(to serverURL: String) {
    let nextServer = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard nextServer != self.serverURL else { return }
    self.serverURL = nextServer
    accountId = nil
    sessionToken = ""
    accountDeletionIdempotencyKey = nil
    clearRemoteTracking()
  }

  /// Install credentials returned by passkey authentication. A different
  /// account or server starts with a clean remote baseline.
  @discardableResult
  public mutating func connect(
    accountId: String,
    serverURL: String,
    sessionToken: String,
    at date: Date = Date()
  ) -> Bool {
    guard let accountId = SyncAccountIdentifier.normalized(accountId),
      SyncSessionToken.isUsable(sessionToken, forAccountId: accountId, at: date)
    else { return false }
    let nextServer = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if self.accountId != accountId || self.serverURL != nextServer {
      accountDeletionIdempotencyKey = nil
      clearRemoteTracking()
    }
    self.accountId = accountId
    self.serverURL = nextServer
    self.sessionToken = sessionToken
    return true
  }

  public mutating func clearRemoteTracking() {
    latestRemoteVersion = 0
    lastSyncedAt = nil
    lastChecksum = nil
    lastSyncedContentChecksum = nil
    remoteOutcomeUncertain = false
    pendingExchangeCredentialCleanup = false
  }

  /// Forget only the bearer grant after the server has revoked this device's
  /// session. The account identity and authenticated remote baseline remain
  /// useful after the user signs back in to the same account.
  public mutating func clearSession() {
    sessionToken = ""
  }

  /// Disconnect a deleted remote account without deleting any local vault
  /// content. Keep the selected server so the user can create a replacement
  /// account explicitly, but never carry the deleted account's baseline into it.
  public mutating func disconnectAccount() {
    accountId = nil
    sessionToken = ""
    accountDeletionIdempotencyKey = nil
    clearRemoteTracking()
  }

  public mutating func markSynced(
    version: Int,
    snapshotChecksum: String,
    contentChecksum: String,
    at date: Date = Date()
  ) {
    latestRemoteVersion = version
    lastSyncedAt = date
    lastChecksum = snapshotChecksum
    lastSyncedContentChecksum = contentChecksum
    remoteOutcomeUncertain = false
    pendingExchangeCredentialCleanup = false
  }
}

private struct CurrentVaultSyncStatePayload: Decodable {
  var accountId: String?
  var serverURL: String
  var sessionToken: String
  var latestRemoteVersion: Int
  var lastSyncedAt: Date?
  var lastChecksum: String?
  var lastSyncedContentChecksum: String?
  var remoteOutcomeUncertain: Bool
  var pendingExchangeCredentialCleanup: Bool
  var accountDeletionIdempotencyKey: String?

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case accountId
    case serverURL
    case sessionToken
    case latestRemoteVersion
    case lastSyncedAt
    case lastChecksum
    case lastSyncedContentChecksum
    case remoteOutcomeUncertain
    case pendingExchangeCredentialCleanup
    case accountDeletionIdempotencyKey
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let requiredKeys: [CodingKeys] = [
      .serverURL,
      .sessionToken,
      .latestRemoteVersion,
      .remoteOutcomeUncertain,
    ]
    for key in requiredKeys where !container.contains(key) {
      throw DecodingError.keyNotFound(
        key,
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Current vault sync state is missing \(key.stringValue)."
        )
      )
    }
    accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
    serverURL = try container.decode(String.self, forKey: .serverURL)
    sessionToken = try container.decode(String.self, forKey: .sessionToken)
    latestRemoteVersion = try container.decode(Int.self, forKey: .latestRemoteVersion)
    lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
    lastChecksum = try container.decodeIfPresent(String.self, forKey: .lastChecksum)
    lastSyncedContentChecksum = try container.decodeIfPresent(
      String.self,
      forKey: .lastSyncedContentChecksum
    )
    remoteOutcomeUncertain = try container.decode(Bool.self, forKey: .remoteOutcomeUncertain)
    pendingExchangeCredentialCleanup = try container.decodeIfPresent(
      Bool.self,
      forKey: .pendingExchangeCredentialCleanup
    ) ?? false
    accountDeletionIdempotencyKey = try container.decodeIfPresent(
      String.self,
      forKey: .accountDeletionIdempotencyKey
    )
  }

  var value: SyncState {
    var state = SyncState()
    state.accountId = accountId
    state.serverURL = serverURL
    state.sessionToken = sessionToken
    state.latestRemoteVersion = latestRemoteVersion
    state.lastSyncedAt = lastSyncedAt
    state.lastChecksum = lastChecksum
    state.lastSyncedContentChecksum = lastSyncedContentChecksum
    state.remoteOutcomeUncertain = remoteOutcomeUncertain
    state.pendingExchangeCredentialCleanup = pendingExchangeCredentialCleanup
    state.accountDeletionIdempotencyKey = accountDeletionIdempotencyKey
    return state
  }
}

enum VaultDocumentAuthenticatedDecodeError: Error, Equatable, Sendable {
  case schemaEnvelopeMismatch(envelopeSchemaVersion: Int, documentSchemaVersion: Int?)
}

private struct VaultDocumentSchemaProbe: Decodable {
  let schemaVersion: Int?
}

public struct VaultDocument: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 2

  public var schemaVersion: Int
  public var preferences: Preferences
  public var wallets: [WalletRecord]
  public var customTokens: [CustomTokenRecord]
  public var manualHoldings: [ManualHoldingRecord]
  public var exchangeConnections: [ExchangeConnectionRecord]
  public var scanRuns: [ScanRunRecord]
  public var syncState: SyncState
  public var updatedAt: Date

  public init(
    schemaVersion: Int = VaultDocument.currentSchemaVersion,
    preferences: Preferences = Preferences(),
    wallets: [WalletRecord] = [],
    customTokens: [CustomTokenRecord] = [],
    manualHoldings: [ManualHoldingRecord] = [],
    exchangeConnections: [ExchangeConnectionRecord] = [],
    scanRuns: [ScanRunRecord] = [],
    syncState: SyncState = SyncState(),
    updatedAt: Date = Date()
  ) {
    self.schemaVersion = schemaVersion
    self.preferences = preferences
    self.wallets = wallets
    self.customTokens = customTokens
    self.manualHoldings = manualHoldings
    self.exchangeConnections = exchangeConnections
    self.scanRuns = scanRuns
    self.syncState = syncState
    self.updatedAt = updatedAt
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case preferences
    case wallets
    case customTokens
    case manualHoldings
    case exchangeConnections
    case scanRuns
    case syncState
    case updatedAt
  }

  /// Decode authenticated plaintext only when its explicit inner schema agrees
  /// with the authenticated envelope metadata. Schema-v1 is the sole legacy
  /// exception: the original format predated the inner field, so a missing
  /// value is unambiguously treated as v1. Current documents must always carry
  /// an explicit current schema; otherwise a truncated v2 payload could be
  /// silently interpreted through the permissive migration path.
  static func decodeAuthenticatedPlaintext(
    _ data: Data,
    envelopeSchemaVersion: Int,
    decoder: JSONDecoder = .addressAtlas
  ) throws -> VaultDocument {
    let probe = try JSONDecoder.addressAtlas.decode(VaultDocumentSchemaProbe.self, from: data)
    let schemaMatchesEnvelope: Bool
    switch envelopeSchemaVersion {
    case 1:
      schemaMatchesEnvelope = probe.schemaVersion == nil || probe.schemaVersion == 1
    case Self.currentSchemaVersion:
      schemaMatchesEnvelope = probe.schemaVersion == Self.currentSchemaVersion
    default:
      schemaMatchesEnvelope = false
    }
    guard schemaMatchesEnvelope else {
      throw VaultDocumentAuthenticatedDecodeError.schemaEnvelopeMismatch(
        envelopeSchemaVersion: envelopeSchemaVersion,
        documentSchemaVersion: probe.schemaVersion
      )
    }
    return try decoder.decode(VaultDocument.self, from: data)
  }

  /// Migrate persisted schema-v1 documents in memory. Missing collections and
  /// sync fields receive conservative defaults; unknown future schemas fail
  /// closed instead of being partially interpreted.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let storedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard (1...Self.currentSchemaVersion).contains(storedSchemaVersion) else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Unsupported vault schema version \(storedSchemaVersion)."
      )
    }

    schemaVersion = Self.currentSchemaVersion
    if storedSchemaVersion == Self.currentSchemaVersion {
      preferences = try container.decode(Preferences.self, forKey: .preferences)
      wallets = try container.decode([WalletRecord].self, forKey: .wallets)
      customTokens = try container.decode([CustomTokenRecord].self, forKey: .customTokens)
      manualHoldings = try container.decode([ManualHoldingRecord].self, forKey: .manualHoldings)
      exchangeConnections = try container.decode(
        [ExchangeConnectionRecord].self,
        forKey: .exchangeConnections
      )
      scanRuns = try container.decode([ScanRunRecord].self, forKey: .scanRuns)
      syncState = try container.decode(
        CurrentVaultSyncStatePayload.self,
        forKey: .syncState
      ).value
      updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    } else {
      preferences =
        try container.decodeIfPresent(Preferences.self, forKey: .preferences) ?? Preferences()
      wallets = try container.decodeIfPresent([WalletRecord].self, forKey: .wallets) ?? []
      customTokens =
        try container.decodeIfPresent([CustomTokenRecord].self, forKey: .customTokens) ?? []
      manualHoldings =
        try container.decodeIfPresent([ManualHoldingRecord].self, forKey: .manualHoldings) ?? []
      exchangeConnections =
        try container.decodeIfPresent(
          [ExchangeConnectionRecord].self,
          forKey: .exchangeConnections
        ) ?? []
      scanRuns = try container.decodeIfPresent([ScanRunRecord].self, forKey: .scanRuns) ?? []
      syncState = try container.decodeIfPresent(SyncState.self, forKey: .syncState) ?? SyncState()
      updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
  }
}
