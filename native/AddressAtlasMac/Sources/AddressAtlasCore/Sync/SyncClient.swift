import CryptoKit
import Foundation

public struct RemoteVaultSnapshot: Codable, Equatable, Sendable {
  public var version: Int
  public var envelope: EncryptedVaultEnvelope
  public var byteSize: Int
  public var checksum: String
  public var updatedAt: Date

  public init(
    version: Int, envelope: EncryptedVaultEnvelope, byteSize: Int, checksum: String,
    updatedAt: Date = Date()
  ) {
    self.version = version
    self.envelope = envelope
    self.byteSize = byteSize
    self.checksum = checksum
    self.updatedAt = updatedAt
  }
}

public struct OpenedVaultSnapshot: Equatable, Sendable {
  public var document: VaultDocument
  /// True only for an authenticated legacy v1 blob. The caller should upload
  /// the document once as v2 before considering the migration complete.
  public var requiresV2Upgrade: Bool

  public init(document: VaultDocument, requiresV2Upgrade: Bool) {
    self.document = document
    self.requiresV2Upgrade = requiresV2Upgrade
  }
}

public enum VaultSyncCodecError: Error, Equatable, LocalizedError {
  case invalidAccount
  case invalidVersion
  case invalidSnapshot
  case accountMismatch
  case legacyMetadataMismatch

  public var errorDescription: String? {
    switch self {
    case .invalidAccount:
      "Sync account identity is missing or invalid. Sign in again."
    case .invalidVersion:
      "Sync snapshot version is invalid."
    case .invalidSnapshot:
      "Sync snapshot failed integrity validation."
    case .accountMismatch:
      "Sync snapshot belongs to a different account."
    case .legacyMetadataMismatch:
      "Legacy sync snapshot metadata is inconsistent and cannot be migrated safely."
    }
  }
}

/// Separate from `VaultSyncCodecError` so size enforcement remains
/// source-compatible with exhaustive switches over the existing public enum.
public struct VaultSyncSnapshotTooLargeError: Error, Equatable, LocalizedError, Sendable {
  public let actualByteCount: Int
  public let maximumByteCount: Int

  public init(actualByteCount: Int, maximumByteCount: Int) {
    self.actualByteCount = actualByteCount
    self.maximumByteCount = maximumByteCount
  }

  public var errorDescription: String? {
    "Encrypted sync snapshot is too large (\(actualByteCount) bytes; maximum \(maximumByteCount)). Remove older scan history or reduce vault data before syncing."
  }
}

public struct VaultSyncCodec: Sendable {
  public static let maximumSnapshotByteCount = 8_000_000
  private static let maximumVersion = VaultDocumentLimits.maximumRemoteVersion
  private let crypto: VaultCrypto

  public init(crypto: VaultCrypto = VaultCrypto()) {
    self.crypto = crypto
  }

  public func seal(
    document: VaultDocument,
    vaultKey: Data,
    version: Int,
    accountId: String
  ) throws -> RemoteVaultSnapshot {
    let accountId = try validatedAccountId(accountId)
    try validateVersion(version)
    let remoteDocument = documentForRemoteSnapshot(document, accountId: accountId)
    // Never emit ciphertext that this codec would reject on the read path. A
    // snapshot is the immediate successor of the authenticated baseline
    // recorded inside its plaintext; accepting a gap here would create an
    // apparently successful upload that no client could safely open.
    guard remoteDocument.syncState.latestRemoteVersion == version - 1 else {
      throw VaultSyncCodecError.legacyMetadataMismatch
    }
    try VaultDocumentSemanticValidator.validate(
      remoteDocument,
      context: .remoteSnapshot(accountId: accountId)
    )
    try VaultDocumentSemanticValidator.validateExchangeCredentialPayloads(
      in: remoteDocument,
      vaultKey: vaultKey,
      crypto: crypto
    )
    let projectedByteCount = try encodedEnvelopeByteCount(for: remoteDocument)
    guard projectedByteCount <= Self.maximumSnapshotByteCount else {
      throw VaultSyncSnapshotTooLargeError(
        actualByteCount: projectedByteCount,
        maximumByteCount: Self.maximumSnapshotByteCount
      )
    }
    let key = try crypto.deriveKey(from: vaultKey, purpose: .syncBlob)
    let authenticatedData = syncAuthenticatedData(
      accountId: accountId,
      version: version,
      schemaVersion: remoteDocument.schemaVersion
    )
    let envelope = try crypto.sealJSON(
      remoteDocument,
      with: key,
      keyId: "sync-v2",
      schemaVersion: remoteDocument.schemaVersion,
      authenticatedData: authenticatedData
    )
    let encoded = try JSONEncoder.addressAtlas.encode(envelope)
    // The projection and the concrete envelope must stay byte-for-byte size
    // equivalent. Fail closed if a future envelope format invalidates the
    // projection instead of silently accepting an incorrect limit decision.
    guard !encoded.isEmpty, encoded.count == projectedByteCount else {
      throw VaultSyncCodecError.invalidSnapshot
    }
    let checksum = snapshotChecksum(envelopeData: encoded, version: version, cryptoVersion: 2)
    return RemoteVaultSnapshot(
      version: version,
      envelope: envelope,
      byteSize: encoded.count,
      checksum: checksum
    )
  }

  /// Exact encoded JSON size of the encrypted v2 envelope without performing
  /// encryption. AES-GCM adds a fixed 16-byte tag and every envelope field has
  /// a fixed encoded width except the Base64URL ciphertext, so this projection
  /// matches `RemoteVaultSnapshot.byteSize` exactly.
  public func encodedSnapshotByteCount(
    document: VaultDocument,
    accountId: String
  ) throws -> Int {
    let accountId = try validatedAccountId(accountId)
    return try encodedEnvelopeByteCount(
      for: documentForRemoteSnapshot(document, accountId: accountId)
    )
  }

  /// Project the exact envelope size after a successful upload has installed
  /// its version, timestamp, and two 64-character checksums. Persistence uses
  /// this larger size so a just-uploaded document cannot immediately become
  /// too large when `markSynced` adds its metadata.
  public func projectedPostSyncSnapshotByteCount(
    document: VaultDocument,
    version: Int,
    accountId: String
  ) throws -> Int {
    try validateVersion(version)
    var projected = document
    projected.syncState.markSynced(
      version: version,
      snapshotChecksum: String(repeating: "0", count: 64),
      contentChecksum: try contentChecksum(for: document),
      // JSONEncoder.addressAtlas emits all ordinary dates with the same
      // second-precision width. Epoch makes the projection deterministic.
      at: Date(timeIntervalSince1970: 0)
    )
    return try encodedSnapshotByteCount(document: projected, accountId: accountId)
  }

  public func isValidAccountId(_ accountId: String?) -> Bool {
    guard let accountId else { return false }
    return (try? validatedAccountId(accountId)) != nil
  }

  public func open(
    snapshot: RemoteVaultSnapshot,
    vaultKey: Data,
    expectedAccountId: String
  ) throws -> OpenedVaultSnapshot {
    let accountId = try validatedAccountId(expectedAccountId)
    try validateRemoteSnapshot(snapshot)
    let key = try crypto.deriveKey(from: vaultKey, purpose: .syncBlob)

    switch snapshot.envelope.cryptoVersion {
    case 2:
      guard snapshot.envelope.keyId == "sync-v2",
        snapshot.envelope.schemaVersion == VaultDocument.currentSchemaVersion
      else {
        throw VaultSyncCodecError.invalidSnapshot
      }
      let authenticatedData = syncAuthenticatedData(
        accountId: accountId,
        version: snapshot.version,
        schemaVersion: snapshot.envelope.schemaVersion
      )
      let document = try crypto.openJSON(
        VaultDocument.self,
        envelope: snapshot.envelope,
        with: key,
        authenticatedData: authenticatedData
      )
      try VaultDocumentSemanticValidator.validate(
        document,
        context: .authenticatedLegacyRemoteSnapshot(accountId: accountId)
      )
      try VaultDocumentSemanticValidator.validateExchangeCredentialPayloads(
        in: document,
        vaultKey: vaultKey,
        crypto: crypto
      )
      guard document.syncState.accountId == accountId else {
        throw VaultSyncCodecError.accountMismatch
      }
      guard document.syncState.latestRemoteVersion == snapshot.version - 1 else {
        throw VaultSyncCodecError.legacyMetadataMismatch
      }
      return OpenedVaultSnapshot(document: document, requiresV2Upgrade: false)

    case 1:
      // Safe one-time migration for snapshots created by the previous client.
      // The encrypted v1 document recorded the prior remote version, so it must
      // be exactly one less than the uploaded top-level version. This detects a
      // server that simply relabels old ciphertext with a higher version.
      guard snapshot.envelope.keyId == "sync-v1", snapshot.envelope.schemaVersion == 1 else {
        throw VaultSyncCodecError.invalidSnapshot
      }
      let document = try crypto.openJSON(VaultDocument.self, envelope: snapshot.envelope, with: key)
      try VaultDocumentSemanticValidator.validate(
        document,
        context: .authenticatedLegacyRemoteSnapshot(accountId: accountId)
      )
      try VaultDocumentSemanticValidator.validateExchangeCredentialPayloads(
        in: document,
        vaultKey: vaultKey,
        crypto: crypto
      )
      guard document.syncState.accountId == accountId else {
        throw VaultSyncCodecError.accountMismatch
      }
      guard document.syncState.latestRemoteVersion == snapshot.version - 1 else {
        throw VaultSyncCodecError.legacyMetadataMismatch
      }
      return OpenedVaultSnapshot(document: document, requiresV2Upgrade: true)

    default:
      throw VaultSyncCodecError.invalidSnapshot
    }
  }

  /// Detect local user-content changes without relying on every UI mutation to
  /// remember to toggle a dirty flag.
  public func hasLocalChanges(in document: VaultDocument) throws -> Bool {
    if document.syncState.remoteOutcomeUncertain
      || document.syncState.pendingExchangeCredentialCleanup
    {
      return true
    }
    let current = try contentChecksum(for: document)
    if let baseline = document.syncState.lastSyncedContentChecksum {
      return current != baseline
    }
    // Legacy documents have no content baseline. Treat a non-empty vault as
    // dirty so Download cannot silently replace it.
    return current != (try contentChecksum(for: VaultDocument()))
  }

  public func markSynced(
    document: inout VaultDocument,
    snapshot: RemoteVaultSnapshot,
    at date: Date = Date()
  ) throws {
    let contentChecksum = try contentChecksum(for: document)
    document.syncState.markSynced(
      version: snapshot.version,
      snapshotChecksum: snapshot.checksum,
      contentChecksum: contentChecksum,
      at: date
    )
  }

  public func contentChecksum(for document: VaultDocument) throws -> String {
    let content = VaultSyncContent(document)
    return Data(SHA256.hash(data: try JSONEncoder.addressAtlas.encode(content))).hexString
  }

  /// Validate all server-controlled snapshot metadata before callers use it for
  /// conflict decisions or version arithmetic. Decryption performs this check
  /// again before trusting the encrypted document.
  public func validateRemoteSnapshot(_ snapshot: RemoteVaultSnapshot) throws {
    try validateVersion(snapshot.version)
    guard snapshot.byteSize > 0,
      snapshot.byteSize <= Self.maximumSnapshotByteCount,
      snapshot.checksum.count == 64,
      snapshot.checksum.unicodeScalars.allSatisfy({ scalar in
        (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
      })
    else {
      throw VaultSyncCodecError.invalidSnapshot
    }
    let encoded = try JSONEncoder.addressAtlas.encode(snapshot.envelope)
    guard encoded.count == snapshot.byteSize,
      snapshotChecksum(
        envelopeData: encoded,
        version: snapshot.version,
        cryptoVersion: snapshot.envelope.cryptoVersion
      ) == snapshot.checksum
    else {
      throw VaultSyncCodecError.invalidSnapshot
    }
  }

  /// Return the next protocol version without ever evaluating trapping integer
  /// arithmetic. Zero is the local pre-sync sentinel; remote versions start at 1.
  public func nextVersion(after latestVersion: Int) throws -> Int {
    guard latestVersion >= 0 else { throw VaultSyncCodecError.invalidVersion }
    let (candidate, overflow) = latestVersion.addingReportingOverflow(1)
    guard !overflow else { throw VaultSyncCodecError.invalidVersion }
    let next = max(1, candidate)
    try validateVersion(next)
    return next
  }

  /// Local persistence still needs a bounded size projection after the remote
  /// version space is exhausted. Reuse the final valid version for byte-width
  /// accounting; an actual upload continues to call `nextVersion` and fail.
  public func versionForNextSyncSizeProjection(after latestVersion: Int) throws -> Int {
    guard latestVersion >= 0 else { throw VaultSyncCodecError.invalidVersion }
    if latestVersion >= Self.maximumVersion {
      return Self.maximumVersion
    }
    return try nextVersion(after: latestVersion)
  }

  private func validatedAccountId(_ accountId: String) throws -> String {
    guard let normalized = SyncAccountIdentifier.normalized(accountId) else {
      throw VaultSyncCodecError.invalidAccount
    }
    return normalized
  }

  private func validateVersion(_ version: Int) throws {
    guard (1...Self.maximumVersion).contains(version) else {
      throw VaultSyncCodecError.invalidVersion
    }
  }

  private func documentForRemoteSnapshot(
    _ document: VaultDocument,
    accountId: String
  ) -> VaultDocument {
    var remoteDocument = document
    remoteDocument.schemaVersion = VaultDocument.currentSchemaVersion
    remoteDocument.syncState.accountId = accountId
    // A bearer token grants server access but provides no value inside the
    // encrypted backup. Never preserve a live token in historical snapshots.
    remoteDocument.syncState.sessionToken = ""
    remoteDocument.syncState.serverURL = ""
    remoteDocument.syncState.accountDeletionIdempotencyKey = nil
    remoteDocument.syncState.remoteOutcomeUncertain = false
    remoteDocument.syncState.pendingExchangeCredentialCleanup = false
    return remoteDocument
  }

  private func encodedEnvelopeByteCount(for remoteDocument: VaultDocument) throws -> Int {
    let plaintextByteCount = try JSONEncoder.addressAtlas.encode(remoteDocument).count
    let (bodyByteCount, bodyOverflow) = plaintextByteCount.addingReportingOverflow(16)
    guard !bodyOverflow else { throw VaultSyncCodecError.invalidSnapshot }
    let ciphertextCharacterCount = try base64URLCharacterCount(forByteCount: bodyByteCount)

    // All Base64URL characters are JSON-safe, so encoding the fixed envelope
    // with an empty ciphertext and adding its projected character count is
    // equivalent to allocating and encoding the full ciphertext string.
    let template = EncryptedVaultEnvelope(
      schemaVersion: VaultDocument.currentSchemaVersion,
      cryptoVersion: 2,
      keyId: "sync-v2",
      nonce: String(repeating: "A", count: 16),
      ciphertext: "",
      checksum: String(repeating: "0", count: 64),
      createdAt: Date(timeIntervalSince1970: 0)
    )
    let fixedByteCount = try JSONEncoder.addressAtlas.encode(template).count
    let (total, totalOverflow) = fixedByteCount.addingReportingOverflow(ciphertextCharacterCount)
    guard !totalOverflow, total > 0 else { throw VaultSyncCodecError.invalidSnapshot }
    return total
  }

  private func base64URLCharacterCount(forByteCount byteCount: Int) throws -> Int {
    guard byteCount >= 0 else { throw VaultSyncCodecError.invalidSnapshot }
    let (fullTripletCharacters, multiplicationOverflow) = (byteCount / 3)
      .multipliedReportingOverflow(by: 4)
    guard !multiplicationOverflow else { throw VaultSyncCodecError.invalidSnapshot }
    let trailingCharacters: Int
    switch byteCount % 3 {
    case 0: trailingCharacters = 0
    case 1: trailingCharacters = 2
    default: trailingCharacters = 3
    }
    let (total, additionOverflow) = fullTripletCharacters.addingReportingOverflow(
      trailingCharacters)
    guard !additionOverflow else { throw VaultSyncCodecError.invalidSnapshot }
    return total
  }

  private func snapshotChecksum(envelopeData: Data, version: Int, cryptoVersion: Int) -> String {
    if cryptoVersion == 1 {
      // Backward-compatible checksum used by legacy snapshots.
      return Data(SHA256.hash(data: envelopeData)).hexString
    }
    var input = Data("address-atlas:sync-snapshot:v2".utf8)
    append(UInt64(version), to: &input)
    append(UInt64(envelopeData.count), to: &input)
    input.append(envelopeData)
    return Data(SHA256.hash(data: input)).hexString
  }

  private func syncAuthenticatedData(accountId: String, version: Int, schemaVersion: Int) -> Data {
    let accountData = Data(accountId.utf8)
    var data = Data("address-atlas:sync-aad:v2".utf8)
    append(UInt64(accountData.count), to: &data)
    data.append(accountData)
    append(UInt64(version), to: &data)
    append(UInt64(schemaVersion), to: &data)
    return data
  }

  private func append(_ value: UInt64, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { bytes in
      data.append(contentsOf: bytes)
    }
  }
}

private struct VaultSyncContent: Encodable {
  var schemaVersion: Int
  var preferences: Preferences
  var wallets: [WalletRecord]
  var customTokens: [CustomTokenRecord]
  var manualHoldings: [ManualHoldingRecord]
  var exchangeConnections: [ExchangeConnectionRecord]
  var scanRuns: [ScanRunRecord]

  init(_ document: VaultDocument) {
    schemaVersion = VaultDocument.currentSchemaVersion
    preferences = document.preferences
    wallets = document.wallets
    customTokens = document.customTokens
    manualHoldings = document.manualHoldings
    exchangeConnections = document.exchangeConnections
    scanRuns = document.scanRuns
  }
}

public enum SyncClientError: Error, Equatable, LocalizedError {
  case authenticationRequired(String)
  case requestFailed(Int, String)

  public var errorDescription: String? {
    switch self {
    case .authenticationRequired(let message):
      message
    case .requestFailed(_, let message):
      message
    }
  }
}

public actor ZeroKnowledgeSyncClient {
  private static let maximumWireSnapshotByteCount =
    VaultSyncCodec.maximumSnapshotByteCount + 100_000
  private static let maximumLifecycleResponseByteCount = 64_000
  private let baseURL: URL
  private let http: HTTPClient
  private var bearerToken: String?

  public init(baseURL: URL, http: HTTPClient? = nil) {
    self.baseURL = baseURL
    self.http =
      http
      ?? BoundedURLSessionHTTPClient(
        maxResponseBytes: Self.maximumWireSnapshotByteCount,
        resourceTimeout: 30
      )
  }

  public func setBearerToken(_ token: String?) {
    guard let token else {
      bearerToken = nil
      return
    }
    // Keep the public client safe even for callers that bypass SyncState's
    // decode/connect validation. Invalid values must never reach an HTTP header.
    bearerToken = SyncSessionToken.isUsable(token) ? token : nil
  }

  public func latestVault() async throws -> RemoteVaultSnapshot? {
    var request = URLRequest(url: baseURL.appending(path: "vault/latest"))
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "accept")
    if let bearerToken {
      request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "authorization")
    }
    let (data, response) = try await http.data(for: request)
    if response.statusCode == 404 {
      return nil
    }
    guard (200..<300).contains(response.statusCode) else {
      throw Self.error(statusCode: response.statusCode, data: data)
    }
    guard data.count <= Self.maximumWireSnapshotByteCount else {
      throw SyncClientError.requestFailed(413, "Sync snapshot response is too large.")
    }
    return try JSONDecoder.addressAtlas.decode(RemoteVaultSnapshot.self, from: data)
  }

  public func upload(snapshot: RemoteVaultSnapshot) async throws {
    var request = URLRequest(url: baseURL.appending(path: "vault/latest"))
    request.timeoutInterval = 30
    request.httpMethod = "PUT"
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    if let bearerToken {
      request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "authorization")
    }
    let body = try JSONEncoder.addressAtlas.encode(snapshot)
    guard body.count <= Self.maximumWireSnapshotByteCount else {
      throw SyncClientError.requestFailed(413, "Sync snapshot is too large.")
    }
    request.httpBody = body
    let (data, response) = try await http.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      throw Self.error(statusCode: response.statusCode, data: data)
    }
    _ = data
  }

  /// Revoke only the bearer grant used by this client. This operation remains
  /// available even when compatibility policy refresh is unavailable so users
  /// can always terminate an active session.
  public func revokeCurrentSession() async throws {
    try await performLifecycleDelete(path: "account/session")
  }

  /// Permanently delete the authenticated sync account. The fixed confirmation
  /// header is part of the server contract and cannot be influenced by remote
  /// configuration or user-provided text.
  public func deleteAccount(idempotencyKey: String) async throws {
    guard AccountDeletionIdempotencyKey.normalized(idempotencyKey) != nil else {
      throw SyncClientError.requestFailed(400, "Account deletion operation is invalid.")
    }
    try await performLifecycleDelete(
      path: "account",
      confirmation: (field: "x-address-atlas-confirm", value: "delete-account"),
      idempotencyKey: idempotencyKey,
      requiresBearer: false
    )
  }

  private func performLifecycleDelete(
    path: String,
    confirmation: (field: String, value: String)? = nil,
    idempotencyKey: String? = nil,
    requiresBearer: Bool = true
  ) async throws {
    guard !requiresBearer || bearerToken != nil else {
      throw SyncClientError.authenticationRequired("Authentication required.")
    }
    var request = URLRequest(url: baseURL.appending(path: path))
    request.timeoutInterval = 30
    request.httpMethod = "DELETE"
    request.setValue("application/json", forHTTPHeaderField: "accept")
    if let bearerToken {
      request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "authorization")
    }
    if let confirmation {
      request.setValue(confirmation.value, forHTTPHeaderField: confirmation.field)
    }
    if let idempotencyKey {
      request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
    }
    let (data, response) = try await http.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      throw Self.error(statusCode: response.statusCode, data: data)
    }
    guard data.count <= Self.maximumLifecycleResponseByteCount,
      let acknowledgement = try? JSONDecoder.addressAtlas.decode(
        ServerAcknowledgement.self,
        from: data
      ),
      acknowledgement.ok
    else {
      throw SyncClientError.requestFailed(502, "Sync server returned an invalid response.")
    }
  }

  private static func error(statusCode: Int, data: Data) -> SyncClientError {
    let fallback = HTTPURLResponse.localizedString(forStatusCode: statusCode)
    // Error bodies share the large snapshot response ceiling, but user-facing
    // text must not inherit that size or expose control characters and secrets.
    // Bound decode work first, then reuse the scanner's centralized sanitizer.
    let cappedData = Data(data.prefix(16_384))
    let decoded = try? JSONDecoder.addressAtlas.decode(ServerError.self, from: cappedData).error
    let message =
      decoded.map { ProviderErrorSanitizer.sanitize($0, fallback: fallback) } ?? fallback
    if statusCode == 401 {
      return .authenticationRequired(message)
    }
    return .requestFailed(statusCode, message)
  }
}

private struct ServerError: Decodable {
  var error: String
}

private struct ServerAcknowledgement: Decodable {
  var ok: Bool
}
