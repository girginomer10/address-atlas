import CryptoKit
import Darwin
import Foundation

// Swift's Darwin overlay exposes `struct flock` but not the same-named BSD
// function on every toolchain. Bind the stable libc symbol explicitly.
@_silgen_name("flock")
private func addressAtlasFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

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
    self.warnings = ScanWarningPolicy.bounded(warnings)
  }
}

public enum ExchangeClientError: Error, Equatable, LocalizedError, Sendable {
  case httpError(statusCode: Int, message: String)
  case invalidResponse(String)
  case paginationLimit(provider: String, pages: Int)
  case legacyKrakenCredentialRequiresMigration
  case krakenCredentialBelongsToAnotherDevice
  case duplicateKrakenCredential
  case duplicateCredential(provider: ExchangeProvider)

  public var errorDescription: String? {
    switch self {
    case .httpError(let statusCode, let message):
      return "Exchange request failed (\(statusCode)): \(message)"
    case .invalidResponse(let message):
      return "Exchange returned invalid data: \(message)"
    case .paginationLimit(let provider, let pages):
      return "\(provider) pagination exceeded the \(pages)-page safety limit."
    case .legacyKrakenCredentialRequiresMigration:
      return "This Kraken connection predates device-safe nonces. Remove it, then add a new read-only Kraken API key created only for this Mac. Use a different Kraken API key on every device."
    case .krakenCredentialBelongsToAnotherDevice:
      return "This Kraken connection belongs to another Mac. Add a separate read-only Kraken API key for this Mac; never reuse one Kraken API key across devices."
    case .duplicateKrakenCredential:
      return "The same Kraken API key appears in more than one saved connection. Remove every duplicate, then add exactly one read-only Kraken API key created only for this Mac. Use a different Kraken API key on every device."
    case .duplicateCredential(let provider):
      return "The same \(provider.label) API key appears in more than one saved connection. Remove every duplicate so this exchange account is scanned exactly once."
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
  private let krakenDeviceIdentifier: @Sendable () throws -> String

  public init(
    client: NativeExchangeBalanceClient = NativeExchangeBalanceClient(),
    credentialVault: ExchangeCredentialVault = ExchangeCredentialVault(),
    priceProvider: PriceProviding = CoinGeckoPriceClient(),
    maxConcurrentConnections: Int = 3,
    connectionDeadline: TimeInterval = 45,
    workflowDeadline: TimeInterval = 120,
    krakenDeviceIdentifier: @escaping @Sendable () throws -> String = {
      try KrakenDeviceIdentity.currentIdentifier()
    }
  ) {
    self.client = client
    self.credentialVault = credentialVault
    self.priceProvider = priceProvider
    self.maxConcurrentConnections = max(1, maxConcurrentConnections)
    self.connectionDeadline = connectionDeadline.isFinite && connectionDeadline > 0 ? connectionDeadline : 45
    self.workflowDeadline = workflowDeadline.isFinite && workflowDeadline > 0 ? workflowDeadline : 120
    self.krakenDeviceIdentifier = krakenDeviceIdentifier
  }

  public func scanThrowing(connections: [ExchangeConnectionRecord], vaultKey: Data) async throws -> ExchangeScanResult {
    // Synced, legacy, or damaged vault state can contain duplicate records even
    // though ordinary creation prevents them. Fail every member of any duplicate
    // raw-key group before HTTP: scanning two same-device records would otherwise
    // double-count the same account. The plaintext comparison lives only for this
    // in-memory preflight; no global/raw-key fingerprint is persisted.
    let duplicateCredentialErrors = duplicateCredentialErrors(
      connections,
      vaultKey: vaultKey
    )
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
            if let duplicateError = duplicateCredentialErrors[job.connection.id] {
              throw duplicateError
            }
            outcome = try await withWorkflowTimeout(seconds: connectionDeadline) {
              try await scanConnection(job.connection, vaultKey: vaultKey)
            }
          } catch ExchangeClientError.krakenCredentialBelongsToAnotherDevice {
            // A synced vault legitimately contains one distinct Kraken key per
            // Mac. The foreign record is not an error on this installation and
            // must remain byte-for-byte unchanged; marking it failed would make
            // every Mac rewrite every other Mac's status on each scan.
            outcome = ExchangeConnectionOutcome(
              connection: job.connection,
              warnings: [
                ProviderErrorSanitizer.sanitize(
                  "\(job.connection.label): skipped on this Mac because this Kraken connection is bound to another Mac."
                )
              ]
            )
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
      let deadline = WorkflowTimeoutError(seconds: workflowDeadline).displaySeconds
      globalWarnings.append(
        "The overall exchange scan reached its \(deadline)-second deadline; \(skipped) unfinished connections were skipped and completed results were kept."
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
      warnings: ScanWarningPolicy.bounded(globalWarnings + outcomes.flatMap(\.warnings))
    )
  }

  private func duplicateCredentialErrors(
    _ connections: [ExchangeConnectionRecord],
    vaultKey: Data
  ) -> [UUID: ExchangeClientError] {
    struct CredentialIdentity: Hashable {
      var provider: ExchangeProvider
      var apiKey: String
    }

    var connectionsByCredential: [CredentialIdentity: [UUID]] = [:]
    for connection in connections {
      guard let credentials = try? credentialVault.open(
        connection.encryptedCredentials,
        vaultKey: vaultKey
      )
      else { continue }
      let normalizedAPIKey = credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalizedAPIKey.isEmpty else { continue }
      connectionsByCredential[
        CredentialIdentity(provider: connection.provider, apiKey: normalizedAPIKey),
        default: []
      ].append(connection.id)
    }

    return connectionsByCredential.reduce(into: [UUID: ExchangeClientError]()) { duplicates, entry in
      let (identity, connectionIDs) = entry
      guard connectionIDs.count > 1 else { return }
      let error: ExchangeClientError = identity.provider == .kraken
        ? .duplicateKrakenCredential
        : .duplicateCredential(provider: identity.provider)
      for connectionID in connectionIDs {
        duplicates[connectionID] = error
      }
    }
  }

  private func scanConnection(
    _ original: ExchangeConnectionRecord,
    vaultKey: Data
  ) async throws -> ExchangeConnectionOutcome {
    var connection = original
    if connection.provider == .kraken {
      guard let boundIdentifier = connection.krakenDeviceIdentifier.flatMap(
        KrakenDeviceIdentity.normalizedIdentifier
      ) else {
        throw ExchangeClientError.legacyKrakenCredentialRequiresMigration
      }
      guard let localIdentifier = KrakenDeviceIdentity.normalizedIdentifier(
        try krakenDeviceIdentifier()
      ) else {
        throw KrakenNonceError.localStateUnavailable
      }
      guard boundIdentifier == localIdentifier else {
        throw ExchangeClientError.krakenCredentialBelongsToAnotherDevice
      }
    }
    let credentials = try credentialVault.open(connection.encryptedCredentials, vaultKey: vaultKey)
    let balance = try await client.fetchBalance(
      provider: connection.provider,
      credentials: credentials,
      krakenDeviceIdentifier: connection.krakenDeviceIdentifier
    )
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

public enum KrakenNonceError: Error, Equatable, LocalizedError, Sendable {
  case invalidClock
  case exhausted
  case localStateUnavailable
  case localStateChanged

  public var errorDescription: String? {
    switch self {
    case .invalidClock:
      return "The system clock cannot produce a safe Kraken nonce. Correct the Mac's date and time before retrying."
    case .exhausted:
      return "The Kraken nonce range is exhausted for this API key. Create a new read-only Kraken API key."
    case .localStateUnavailable:
      return "Kraken's protected local nonce state is unavailable. No Kraken request was sent."
    case .localStateChanged:
      return "Kraken's local device state changed. Remove this connection and add a new read-only Kraken API key created only for this Mac."
    }
  }
}

protocol KrakenInstallationSecretStore: Sendable {
  func loadSecret() throws -> Data?
  /// Atomically installs the first secret or returns the value installed by a
  /// competing process. Implementations must never replace an existing value.
  func saveSecretIfAbsent(_ secret: Data) throws -> Data
}

/// The Kraken state-binding key is deliberately separate from both the vault
/// key and the cloneable Application Support state. The underlying Keychain
/// item is `WhenUnlockedThisDeviceOnly`, so it is neither synced nor restored
/// onto a different Mac. No per-request user-presence prompt is used because
/// scans can run unattended while the user's login session is unlocked.
private struct KeychainKrakenInstallationSecretStore: KrakenInstallationSecretStore {
  private let backingStore = KeychainVaultKeyStore(
    service: "com.addressatlas.mac.kraken-installation",
    account: "nonce-state-binding-v1"
  )

  func loadSecret() throws -> Data? {
    try backingStore.loadVaultKey()
  }

  func saveSecretIfAbsent(_ secret: Data) throws -> Data {
    try backingStore.saveVaultKeyIfAbsent(secret)
  }
}

public enum KrakenDeviceIdentity {
  public static func currentIdentifier(
    storageURL: URL = KrakenNonceGenerator.defaultStorageURL
  ) throws -> String {
    try currentIdentifier(
      storageURL: storageURL,
      installationSecretStore: KeychainKrakenInstallationSecretStore()
    )
  }

  static func currentIdentifier(
    storageURL: URL,
    installationSecretStore: any KrakenInstallationSecretStore
  ) throws -> String {
    do {
      return try KrakenLocalNonceStore.withLockedState(
        at: storageURL,
        installationSecretStore: installationSecretStore
      ) { state, _ in
        state.deviceIdentifier
      }
    } catch let error as KrakenNonceError {
      throw error
    } catch {
      throw KrakenNonceError.localStateUnavailable
    }
  }

  public static func normalizedIdentifier(_ candidate: String) -> String? {
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count == 36,
          let parsed = UUID(uuidString: trimmed),
          parsed.uuidString.lowercased() == trimmed.lowercased()
    else { return nil }
    return parsed.uuidString.lowercased()
  }
}

/// Kraken requires a strictly increasing nonce per API key. Every update is
/// serialized across processes with `flock` and durably replaced before the
/// signed request is allowed to leave the process. A device-only Keychain
/// secret authenticates the cloneable state file and derives its opaque
/// HMAC(apiKey) identifiers; neither the secret nor an API key is stored there.
public actor KrakenNonceGenerator {
  public static var defaultStorageURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "AddressAtlas", directoryHint: .isDirectory)
      .appending(path: "kraken-nonce-state.json")
  }

  public static let shared = KrakenNonceGenerator(storageURL: defaultStorageURL)
  private let storageURL: URL
  private let installationSecretStore: any KrakenInstallationSecretStore

  public init(storageURL: URL = KrakenNonceGenerator.defaultStorageURL) {
    self.storageURL = storageURL
    self.installationSecretStore = KeychainKrakenInstallationSecretStore()
  }

  init(
    storageURL: URL,
    installationSecretStore: any KrakenInstallationSecretStore
  ) {
    self.storageURL = storageURL
    self.installationSecretStore = installationSecretStore
  }

  public func deviceIdentifier() throws -> String {
    try KrakenDeviceIdentity.currentIdentifier(
      storageURL: storageURL,
      installationSecretStore: installationSecretStore
    )
  }

  func next(
    apiKey: String,
    at date: Date,
    expectedDeviceIdentifier: String? = nil
  ) throws -> String {
    let rawMilliseconds = date.timeIntervalSince1970 * 1_000
    guard rawMilliseconds.isFinite,
          rawMilliseconds > 0,
          rawMilliseconds < Double(Int64.max)
    else {
      throw KrakenNonceError.invalidClock
    }
    let currentMilliseconds = Int64(rawMilliseconds.rounded(.down))

    do {
      return try KrakenLocalNonceStore.withLockedState(
        at: storageURL,
        installationSecretStore: installationSecretStore
      ) { state, installationSecret in
        if let expectedDeviceIdentifier {
          guard KrakenDeviceIdentity.normalizedIdentifier(expectedDeviceIdentifier) == state.deviceIdentifier else {
            throw KrakenNonceError.localStateChanged
          }
        }
        let identifier = try state.credentialIdentifier(
          for: apiKey,
          installationSecret: installationSecret
        )
        let previous = state.lastNonceByCredential[identifier].flatMap(Int64.init)
        guard previous != nil || state.lastNonceByCredential.count < KrakenLocalNonceState.maximumCredentialCount else {
          throw KrakenNonceError.localStateUnavailable
        }
        let next: Int64
        if let previous, previous >= currentMilliseconds {
          guard previous < Int64.max else { throw KrakenNonceError.exhausted }
          next = previous + 1
        } else {
          next = currentMilliseconds
        }
        state.lastNonceByCredential[identifier] = String(next)
        return String(next)
      }
    } catch let error as KrakenNonceError {
      throw error
    } catch {
      throw KrakenNonceError.localStateUnavailable
    }
  }
}

private struct KrakenLocalNonceState: Codable {
  static let currentVersion = 2
  static let maximumCredentialCount = 1_024
  static let installationSecretByteCount = 32

  var version: Int
  var deviceIdentifier: String
  var lastNonceByCredential: [String: String]
  var installationBinding: String

  static func makeNew(installationSecret: Data) throws -> Self {
    var state = Self(
      version: currentVersion,
      deviceIdentifier: UUID().uuidString.lowercased(),
      lastNonceByCredential: [:],
      installationBinding: ""
    )
    try state.reseal(using: installationSecret)
    return state
  }

  func validated(using installationSecret: Data) throws -> Self {
    guard version == Self.currentVersion,
          KrakenDeviceIdentity.normalizedIdentifier(deviceIdentifier) == deviceIdentifier,
          installationSecret.count == Self.installationSecretByteCount,
          lastNonceByCredential.count <= Self.maximumCredentialCount,
          lastNonceByCredential.allSatisfy({ key, value in
            key.utf8.count == 64 && key.utf8.allSatisfy(Self.isLowercaseHex)
              && Int64(value).map { $0 >= 0 } == true
          }),
          let binding = Data(base64Encoded: installationBinding),
          binding.count == SHA256.Digest.byteCount,
          HMAC<SHA256>.isValidAuthenticationCode(
            binding,
            authenticating: bindingPayload(),
            using: SymmetricKey(data: installationSecret)
          )
    else {
      throw KrakenNonceError.localStateUnavailable
    }
    return self
  }

  func credentialIdentifier(
    for apiKey: String,
    installationSecret: Data
  ) throws -> String {
    guard installationSecret.count == Self.installationSecretByteCount else {
      throw KrakenNonceError.localStateUnavailable
    }
    var authenticatedData = Data("address-atlas.kraken.credential-id.v1\0".utf8)
    authenticatedData.append(Data(apiKey.utf8))
    let code = HMAC<SHA256>.authenticationCode(
      for: authenticatedData,
      using: SymmetricKey(data: installationSecret)
    )
    return Self.lowercaseHex(code)
  }

  mutating func reseal(using installationSecret: Data) throws {
    guard installationSecret.count == Self.installationSecretByteCount else {
      throw KrakenNonceError.localStateUnavailable
    }
    installationBinding = Data(
      HMAC<SHA256>.authenticationCode(
        for: bindingPayload(),
        using: SymmetricKey(data: installationSecret)
      )
    ).base64EncodedString()
  }

  private func bindingPayload() -> Data {
    var payload = Data("address-atlas.kraken.nonce-state.v2\0".utf8)
    Self.appendLengthPrefixed(Data(deviceIdentifier.utf8), to: &payload)
    for (identifier, nonce) in lastNonceByCredential.sorted(by: { $0.key < $1.key }) {
      Self.appendLengthPrefixed(Data(identifier.utf8), to: &payload)
      Self.appendLengthPrefixed(Data(nonce.utf8), to: &payload)
    }
    return payload
  }

  private static func appendLengthPrefixed(_ value: Data, to payload: inout Data) {
    var length = UInt64(value.count).bigEndian
    withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
    payload.append(value)
  }

  private static func lowercaseHex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    let hex = Array("0123456789abcdef".utf8)
    return bytes.reduce(into: "") { result, byte in
      result.append(Character(UnicodeScalar(hex[Int(byte >> 4)])))
      result.append(Character(UnicodeScalar(hex[Int(byte & 0x0f)])))
    }
  }

  private static func isLowercaseHex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...102).contains(byte)
  }
}

/// Version 1 put the installation UUID, the credential HMAC key, and every
/// nonce into the same copyable JSON object. It can be parsed only so migration
/// can fail closed by rotating to a fresh v2 identity; none of its identity or
/// nonce material is ever trusted or carried forward.
private struct KrakenLegacyLocalNonceStateV1: Decodable {
  var version: Int
  var deviceIdentifier: String
  var credentialIdentifierKey: String
  var lastNonceByCredential: [String: String]

  func validateForDiscard() throws {
    guard version == 1,
          KrakenDeviceIdentity.normalizedIdentifier(deviceIdentifier) == deviceIdentifier,
          Data(base64Encoded: credentialIdentifierKey)?.count == 32,
          lastNonceByCredential.count <= KrakenLocalNonceState.maximumCredentialCount,
          lastNonceByCredential.allSatisfy({ key, value in
            key.utf8.count == 64
              && key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
              && Int64(value).map { $0 >= 0 } == true
          })
    else { throw KrakenNonceError.localStateUnavailable }
  }
}

private struct KrakenLocalNonceStateVersion: Decodable {
  var version: Int
}

private enum KrakenLocalNonceStore {
  private static let maximumEncodedByteCount = 256 * 1_024

  static func withLockedState<T>(
    at storageURL: URL,
    installationSecretStore: any KrakenInstallationSecretStore,
    _ update: (inout KrakenLocalNonceState, Data) throws -> T
  ) throws -> T {
    let directoryURL = storageURL.deletingLastPathComponent()
    try prepareDirectory(directoryURL)
    let lockURL = storageURL.appendingPathExtension("lock")
    let lockDescriptor = lockURL.path.withCString {
      Darwin.open($0, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    }
    guard lockDescriptor >= 0 else { throw KrakenNonceError.localStateUnavailable }
    defer { Darwin.close(lockDescriptor) }
    guard isOwnedRegularFile(lockDescriptor),
          Darwin.fchmod(lockDescriptor, S_IRUSR | S_IWUSR) == 0
    else { throw KrakenNonceError.localStateUnavailable }
    while addressAtlasFlock(lockDescriptor, LOCK_EX) != 0 {
      guard errno == EINTR else { throw KrakenNonceError.localStateUnavailable }
    }
    defer { _ = addressAtlasFlock(lockDescriptor, LOCK_UN) }

    var metadata = stat()
    let statePathStatus = storageURL.path.withCString { Darwin.lstat($0, &metadata) }
    let installationSecret: Data
    var state: KrakenLocalNonceState
    var requiresInitialWrite = false
    if statePathStatus == 0 {
      guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
            metadata.st_uid == geteuid(),
            metadata.st_nlink == 1
      else { throw KrakenNonceError.localStateUnavailable }
      let data = try readBoundedState(at: storageURL)
      if let version = try? JSONDecoder().decode(KrakenLocalNonceStateVersion.self, from: data).version {
        switch version {
        case KrakenLocalNonceState.currentVersion:
          if let existingSecret = try installationSecretStore.loadSecret() {
            guard existingSecret.count == KrakenLocalNonceState.installationSecretByteCount else {
              throw KrakenNonceError.localStateUnavailable
            }
            installationSecret = existingSecret
            do {
              state = try JSONDecoder().decode(KrakenLocalNonceState.self, from: data)
                .validated(using: installationSecret)
            } catch {
              // A regular, owner-only v2 file that cannot authenticate with this
              // device-only secret is copied, corrupt, or tampered state. It can
              // never be trusted for nonces. Replace it with a fresh identity,
              // then let the expected-identifier check reject every saved old
              // connection before HTTP. Files that fail type/owner/link checks
              // never reach this branch and are not replaced.
              state = try .makeNew(installationSecret: installationSecret)
              requiresInitialWrite = true
            }
          } else {
            // `nil` means Keychain returned the precise item-not-found status;
            // thrown access/decoding errors never enter this recovery path. The
            // old authenticated state is unusable without its secret, so rotate
            // both identity and nonce material. Persist the replacement before
            // installing its secret and before the caller can compare an expected
            // old identifier. A crash or Keychain failure therefore cannot send a
            // request under the old binding, and a later retry can rotate again.
            let replacement = try rotateAfterConfirmedMissingSecret(
              at: storageURL,
              in: installationSecretStore
            )
            state = replacement.0
            installationSecret = replacement.1
          }
        case 1:
          let legacy = try JSONDecoder().decode(KrakenLegacyLocalNonceStateV1.self, from: data)
          try legacy.validateForDiscard()
          installationSecret = try loadOrCreateSecret(in: installationSecretStore)
          state = try .makeNew(installationSecret: installationSecret)
          requiresInitialWrite = true
        default:
          // Preserve a structurally versioned future state for a newer app.
          throw KrakenNonceError.localStateUnavailable
        }
      } else if let existingSecret = try installationSecretStore.loadSecret() {
        guard existingSecret.count == KrakenLocalNonceState.installationSecretByteCount else {
          throw KrakenNonceError.localStateUnavailable
        }
        installationSecret = existingSecret
        state = try .makeNew(installationSecret: installationSecret)
        requiresInitialWrite = true
      } else {
        // An unreadable owner-only state plus a confirmed missing Keychain item
        // has no recoverable identity or nonce material. Apply the same safe
        // pre-comparison rotation used for an unreadable v2 binding.
        let replacement = try rotateAfterConfirmedMissingSecret(
          at: storageURL,
          in: installationSecretStore
        )
        state = replacement.0
        installationSecret = replacement.1
      }
    } else if errno == ENOENT {
      installationSecret = try loadOrCreateSecret(in: installationSecretStore)
      state = try .makeNew(installationSecret: installationSecret)
      requiresInitialWrite = true
    } else {
      throw KrakenNonceError.localStateUnavailable
    }

    // Persist a newly created or safely rotated identity before evaluating an
    // expected old device identifier. If that comparison fails, retries see
    // the same replacement identity instead of generating a new one each time.
    if requiresInitialWrite {
      try writeAtomicallyAndDurably(state, to: storageURL)
    }

    let result = try update(&state, installationSecret)
    try state.reseal(using: installationSecret)
    try writeAtomicallyAndDurably(state, to: storageURL)
    return result
  }

  private static func loadOrCreateSecret(
    in store: any KrakenInstallationSecretStore
  ) throws -> Data {
    if let existing = try store.loadSecret() {
      guard existing.count == KrakenLocalNonceState.installationSecretByteCount else {
        throw KrakenNonceError.localStateUnavailable
      }
      return existing
    }
    let generated = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    let installed = try store.saveSecretIfAbsent(generated)
    guard installed.count == KrakenLocalNonceState.installationSecretByteCount else {
      throw KrakenNonceError.localStateUnavailable
    }
    return installed
  }

  private static func rotateAfterConfirmedMissingSecret(
    at storageURL: URL,
    in store: any KrakenInstallationSecretStore
  ) throws -> (KrakenLocalNonceState, Data) {
    let candidate = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    var state = try KrakenLocalNonceState.makeNew(installationSecret: candidate)

    // Write first. If the process stops before the Keychain insert, the next
    // exact item-not-found result safely replaces this unusable candidate state.
    // Installing the secret first would leave the old v2 file permanently
    // indistinguishable from a copied/tampered file if the state write failed.
    try writeAtomicallyAndDurably(state, to: storageURL)

    let installed = try store.saveSecretIfAbsent(candidate)
    guard installed.count == KrakenLocalNonceState.installationSecretByteCount else {
      throw KrakenNonceError.localStateUnavailable
    }
    if installed != candidate {
      // A competing process may have won the atomic Keychain insert. Bind a new
      // identity to the winner and persist it before returning to the caller.
      state = try .makeNew(installationSecret: installed)
      try writeAtomicallyAndDurably(state, to: storageURL)
    }
    return (state, installed)
  }

  private static func prepareDirectory(_ directoryURL: URL) throws {
    var metadata = stat()
    let status = directoryURL.path.withCString { Darwin.lstat($0, &metadata) }
    if status == 0 {
      guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
            metadata.st_uid == geteuid()
      else { throw KrakenNonceError.localStateUnavailable }
    } else if errno == ENOENT {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } else {
      throw KrakenNonceError.localStateUnavailable
    }

    let descriptor = directoryURL.path.withCString {
      Darwin.open($0, O_RDONLY | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw KrakenNonceError.localStateUnavailable }
    defer { Darwin.close(descriptor) }
    var openedMetadata = stat()
    guard Darwin.fstat(descriptor, &openedMetadata) == 0,
          (openedMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
          openedMetadata.st_uid == geteuid(),
          Darwin.fchmod(descriptor, 0o700) == 0
    else { throw KrakenNonceError.localStateUnavailable }
  }

  private static func readBoundedState(at storageURL: URL) throws -> Data {
    let descriptor = storageURL.path.withCString {
      Darwin.open($0, O_RDONLY | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw KrakenNonceError.localStateUnavailable }
    defer { Darwin.close(descriptor) }
    guard isOwnedRegularFile(descriptor), Darwin.fchmod(descriptor, 0o600) == 0 else {
      throw KrakenNonceError.localStateUnavailable
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw KrakenNonceError.localStateUnavailable }
      guard count > 0 else { break }
      guard data.count <= maximumEncodedByteCount - count else {
        throw KrakenNonceError.localStateUnavailable
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    return data
  }

  private static func isOwnedRegularFile(_ descriptor: Int32) -> Bool {
    var metadata = stat()
    return Darwin.fstat(descriptor, &metadata) == 0
      && (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
      && metadata.st_uid == geteuid()
      && metadata.st_nlink == 1
  }

  private static func writeAtomicallyAndDurably(
    _ state: KrakenLocalNonceState,
    to storageURL: URL
  ) throws {
    let data = try JSONEncoder().encode(state)
    guard data.count <= maximumEncodedByteCount else {
      throw KrakenNonceError.localStateUnavailable
    }
    let temporaryURL = storageURL.deletingLastPathComponent().appending(
      path: ".\(storageURL.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp"
    )
    let temporaryDescriptor = temporaryURL.path.withCString {
      Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    }
    guard temporaryDescriptor >= 0 else { throw KrakenNonceError.localStateUnavailable }
    var shouldRemoveTemporary = true
    defer {
      Darwin.close(temporaryDescriptor)
      if shouldRemoveTemporary { try? FileManager.default.removeItem(at: temporaryURL) }
    }

    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      var offset = 0
      while offset < rawBuffer.count {
        let written = Darwin.write(
          temporaryDescriptor,
          baseAddress.advanced(by: offset),
          rawBuffer.count - offset
        )
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { throw KrakenNonceError.localStateUnavailable }
        offset += written
      }
    }
    guard Darwin.fsync(temporaryDescriptor) == 0 else {
      throw KrakenNonceError.localStateUnavailable
    }
    guard temporaryURL.path.withCString({ temporaryPath in
      storageURL.path.withCString { storagePath in
        Darwin.rename(temporaryPath, storagePath)
      }
    }) == 0 else {
      throw KrakenNonceError.localStateUnavailable
    }
    shouldRemoveTemporary = false

    let directoryDescriptor = storageURL.deletingLastPathComponent().path.withCString {
      Darwin.open($0, O_RDONLY | O_NOFOLLOW)
    }
    guard directoryDescriptor >= 0 else { throw KrakenNonceError.localStateUnavailable }
    defer { Darwin.close(directoryDescriptor) }
    guard Darwin.fsync(directoryDescriptor) == 0 || errno == EINVAL else {
      throw KrakenNonceError.localStateUnavailable
    }
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
    var invalidSymbolCount = 0
    var invalidAmountCount = 0
    var overflowedSymbols = Set<String>()
    for balance in response.balances {
      guard let validatedAsset = ExchangeBalanceNormalizer.validatedExchangeSymbol(balance.asset) else {
        invalidSymbolCount += 1
        continue
      }
      let symbol = ExchangeBalanceNormalizer.normalizeSymbol(validatedAsset)
      guard !symbol.isEmpty else {
        invalidSymbolCount += 1
        continue
      }
      guard let freeAmount = Self.parseAmount(balance.free), let lockedAmount = Self.parseAmount(balance.locked) else {
        invalidAmountCount += 1
        continue
      }
      guard let total = FiniteValueMath.addingNonnegative(freeAmount, lockedAmount) else {
        totals.removeValue(forKey: symbol)
        free.removeValue(forKey: symbol)
        overflowedSymbols.insert(symbol)
        continue
      }
      guard total > 0 else { continue }
      guard !overflowedSymbols.contains(symbol) else { continue }
      guard let nextTotal = FiniteValueMath.addingNonnegative(totals[symbol, default: 0], total),
            let nextFree = FiniteValueMath.addingNonnegative(free[symbol, default: 0], freeAmount)
      else {
        totals.removeValue(forKey: symbol)
        free.removeValue(forKey: symbol)
        overflowedSymbols.insert(symbol)
        continue
      }
      totals[symbol] = nextTotal
      free[symbol] = nextFree
    }
    if invalidSymbolCount > 0 {
      warnings.append(
        "Binance returned \(invalidSymbolCount) account balance record(s) with an invalid asset code; they were skipped."
      )
    }
    if invalidAmountCount > 0 {
      warnings.append("Binance returned \(invalidAmountCount) account balance record(s) with invalid numeric amounts; they were skipped.")
    }
    if !overflowedSymbols.isEmpty {
      warnings.append(
        "Binance balances exceeded the supported numeric range for \(ExchangeBalanceNormalizer.formattedSymbols(Array(overflowedSymbols))); those assets were skipped."
      )
    }
    return ExchangeBalance(total: totals, free: free, warnings: ScanWarningPolicy.bounded(warnings))
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
    var accountsByIdentifier: [UUID: CoinbaseAccountsResponse.Account] = [:]
    var conflictingAccountIdentifiers = Set<UUID>()
    var invalidAccountIdentifierCount = 0
    var exactDuplicateAccountRecordCount = 0
    var invalidAmountCount = 0
    var overflowedSymbols = Set<String>()
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

    var invalidSymbolCount = 0
    for identifier in accountsByIdentifier.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard let account = accountsByIdentifier[identifier] else { continue }
      guard let validatedCurrency = ExchangeBalanceNormalizer.validatedExchangeSymbol(account.currency) else {
        invalidSymbolCount += 1
        continue
      }
      let symbol = ExchangeBalanceNormalizer.normalizeSymbol(validatedCurrency)
      guard !symbol.isEmpty else {
        invalidSymbolCount += 1
        continue
      }
      guard let available = Self.parseAmount(account.availableBalance?.value ?? "0"),
            let hold = Self.parseAmount(account.hold?.value ?? "0")
      else {
        invalidAmountCount += 1
        continue
      }
      guard let total = FiniteValueMath.addingNonnegative(available, hold) else {
        totals.removeValue(forKey: symbol)
        free.removeValue(forKey: symbol)
        overflowedSymbols.insert(symbol)
        continue
      }
      guard total > 0 else { continue }
      guard !overflowedSymbols.contains(symbol) else { continue }
      guard let nextTotal = FiniteValueMath.addingNonnegative(totals[symbol, default: 0], total),
            let nextFree = FiniteValueMath.addingNonnegative(free[symbol, default: 0], available)
      else {
        totals.removeValue(forKey: symbol)
        free.removeValue(forKey: symbol)
        overflowedSymbols.insert(symbol)
        continue
      }
      totals[symbol] = nextTotal
      free[symbol] = nextFree
    }
    if invalidAccountIdentifierCount > 0 {
      warnings.append(
        "Coinbase returned \(invalidAccountIdentifierCount) account record(s) with a missing or malformed UUID; they were skipped to avoid corrupting totals."
      )
    }
    if exactDuplicateAccountRecordCount > 0 {
      warnings.append(
        "Coinbase repeated \(exactDuplicateAccountRecordCount) identical account record(s) in paginated results; duplicates were skipped to avoid double-counting."
      )
    }
    if !conflictingAccountIdentifiers.isEmpty {
      warnings.append(
        "Coinbase returned conflicting data for \(conflictingAccountIdentifiers.count) repeated account UUID(s); every version of those accounts was skipped to keep totals deterministic."
      )
    }
    if invalidSymbolCount > 0 {
      warnings.append(
        "Coinbase returned \(invalidSymbolCount) account record(s) with an invalid asset code; they were skipped."
      )
    }
    if invalidAmountCount > 0 {
      warnings.append("Coinbase returned \(invalidAmountCount) account record(s) with invalid numeric amounts; they were skipped.")
    }
    if !overflowedSymbols.isEmpty {
      warnings.append(
        "Coinbase balances exceeded the supported numeric range for \(ExchangeBalanceNormalizer.formattedSymbols(Array(overflowedSymbols))); those assets were skipped."
      )
    }
    return ExchangeBalance(total: totals, free: free, warnings: ScanWarningPolicy.bounded(warnings))
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
    var invalidSymbolCount = 0
    var invalidAmountCount = 0
    var overflowedSymbols = Set<String>()
    for (rawSymbol, rawAmount) in rawBalances {
      guard let validatedRawSymbol = ExchangeBalanceNormalizer.validatedExchangeSymbol(rawSymbol) else {
        invalidSymbolCount += 1
        continue
      }
      guard let amount = Self.parseAmount(rawAmount) else {
        invalidAmountCount += 1
        continue
      }
      guard amount > 0 else { continue }
      guard let symbol = Self.normalizedKrakenSymbol(validatedRawSymbol, aliases: aliases),
            !symbol.isEmpty
      else {
        invalidSymbolCount += 1
        continue
      }
      guard !overflowedSymbols.contains(symbol),
            let nextTotal = FiniteValueMath.addingNonnegative(totals[symbol, default: 0], amount)
      else {
        totals.removeValue(forKey: symbol)
        overflowedSymbols.insert(symbol)
        continue
      }
      totals[symbol] = nextTotal
    }
    if invalidSymbolCount > 0 {
      warnings.append(
        "Kraken returned \(invalidSymbolCount) balance record(s) with an invalid asset code; they were skipped."
      )
    }
    if invalidAmountCount > 0 {
      warnings.append("Kraken returned \(invalidAmountCount) balance record(s) with invalid numeric amounts; they were skipped.")
    }
    if !overflowedSymbols.isEmpty {
      warnings.append(
        "Kraken balances exceeded the supported numeric range for \(ExchangeBalanceNormalizer.formattedSymbols(Array(overflowedSymbols))); those assets were skipped."
      )
    }
    return ExchangeBalance(total: totals, warnings: ScanWarningPolicy.bounded(warnings))
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

  private static func parseAmount(_ raw: String) -> Double? {
    guard let amount = Double(raw), amount.isFinite, amount >= 0 else { return nil }
    return amount
  }

  private static func normalizedKrakenSymbol(_ validatedRaw: String, aliases: [String: String]) -> String? {
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
  public static let usdStableSymbols: Set<String> = ["USD", "USDC", "USDT", "USDT0", "BUSD", "FDUSD", "TUSD", "USDP", "DAI"]
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
    "TIA": "celestia", "TUSD": "true-usd", "UNI": "uniswap", "USDC": "usd-coin", "USDP": "pax-dollar", "USDT": "tether", "USDT0": "usdt0",
    "WBTC": "wrapped-bitcoin", "WETH": "weth", "WIF": "dogwifcoin", "XLM": "stellar",
    "XRP": "ripple", "XDAI": "xdai", "ZK": "zksync"
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
    let ids = Array(Set(entries.compactMap { symbol, _ in
      fiatSymbols.contains(symbol) ? nil : coinGeckoIds[symbol]
    }))
    let requestedFiatSymbols = Array(Set(entries.compactMap { symbol, _ in
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
          prices = fetched.reduce(into: [:]) { valid, entry in
            guard let point = CoinGeckoPriceClient.sanitized(entry.value) else { return }
            valid[entry.key] = point
          }
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
        warnings.append("No USD price was available for \(formattedSymbols(unpriced)); those balances are shown unpriced.")
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
      let price = pricePoint(symbol: symbol, coinId: coinId, prices: prices, fiatUsdRates: fiatUsdRates)
      let unitPrice = price.usd.isFinite && price.usd >= 0 ? price.usd : 0
      let valueUsd = FiniteValueMath.multiplyingNonnegative(amount, unitPrice)
      if valueUsd == nil { valuationOverflowSymbols.append(symbol) }
      holdings.append(TrackedAsset(
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

  private static func aggregateBalanceEntries(_ balance: ExchangeBalance) -> BalanceEntryAggregation {
    let source = balance.total.isEmpty ? balance.free : balance.total
    var aggregated: [String: Double] = [:]
    var overflowedSymbols = Set<String>()
    for (rawSymbol, amount) in source where amount.isFinite && amount > 0 {
      let symbol = normalizeSymbol(rawSymbol)
      guard !symbol.isEmpty, !overflowedSymbols.contains(symbol) else { continue }
      guard let next = FiniteValueMath.addingNonnegative(aggregated[symbol, default: 0], amount) else {
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
      case 45, 46, 95: // hyphen, period, underscore
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

  struct Account: Decodable, Equatable {
    var identifier: UUID?
    var currency: String
    var availableBalance: Money?
    var hold: Money?

    enum CodingKeys: String, CodingKey {
      case identifier = "uuid"
      case currency
      case availableBalance = "available_balance"
      case hold
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      currency = try container.decode(String.self, forKey: .currency)
      availableBalance = try container.decodeIfPresent(Money.self, forKey: .availableBalance)
      hold = try container.decodeIfPresent(Money.self, forKey: .hold)

      // The API documents `uuid` as the stable account identity. Treat it as
      // untrusted input: a missing, non-string, or non-canonical value leaves
      // this one account invalid without discarding other valid accounts on the
      // same page. The caller skips it with an explicit aggregate warning.
      let rawIdentifier: String?
      do {
        rawIdentifier = try container.decodeIfPresent(String.self, forKey: .identifier)
      } catch {
        rawIdentifier = nil
      }
      guard let candidate = rawIdentifier,
            candidate.utf8.count == 36,
            let parsed = UUID(uuidString: candidate),
            parsed.uuidString.lowercased() == candidate.lowercased()
      else {
        identifier = nil
        return
      }
      identifier = parsed
    }
  }

  struct Money: Decodable, Equatable { var value: String }
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
