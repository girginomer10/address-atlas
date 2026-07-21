import Foundation

public struct VaultPersistenceResult: Sendable {
  public var document: VaultDocument
  public var removedScanRunCount: Int
  public var hasLocalChanges: Bool

  public init(
    document: VaultDocument,
    removedScanRunCount: Int,
    hasLocalChanges: Bool
  ) {
    self.document = document
    self.removedScanRunCount = removedScanRunCount
    self.hasLocalChanges = hasLocalChanges
  }
}

/// Serializes whole-document JSON/checksum/encryption/SQLite work away from
/// MainActor. The underlying store still performs a disk CAS, while callers
/// additionally compare their in-memory revision before applying the result.
public actor VaultPersistenceCoordinator {
  private let store: EncryptedSQLiteVaultStore
  private let syncCodec: VaultSyncCodec
  private let syncSnapshotByteLimit: Int

  public init(
    store: EncryptedSQLiteVaultStore,
    syncSnapshotByteLimit: Int = VaultSyncCodec.maximumSnapshotByteCount,
    syncCodec: VaultSyncCodec = VaultSyncCodec()
  ) {
    precondition((1...VaultSyncCodec.maximumSnapshotByteCount).contains(syncSnapshotByteLimit))
    self.store = store
    self.syncSnapshotByteLimit = syncSnapshotByteLimit
    self.syncCodec = syncCodec
  }

  public func load() throws -> VaultPersistenceResult {
    let document = try store.load()
    return VaultPersistenceResult(
      document: document,
      removedScanRunCount: 0,
      hasLocalChanges: try syncCodec.hasLocalChanges(in: document)
    )
  }

  public func save(
    _ input: VaultDocument,
    projectedSyncVersion: Int? = nil
  ) throws -> VaultPersistenceResult {
    // Local persistence is lossless. The sync byte limit is a wire concern and
    // may only produce a temporary upload projection.
    let persisted = try store.saveReturningPersistedDocument(input)
    return VaultPersistenceResult(
      document: persisted,
      removedScanRunCount: 0,
      hasLocalChanges: try syncCodec.hasLocalChanges(in: persisted)
    )
  }

  /// Save an exact already-prepared document. Used where pruning or changing
  /// sync metadata before a remote side effect would violate the caller's
  /// transaction ordering.
  public func saveExactly(_ document: VaultDocument) throws -> VaultPersistenceResult {
    let persisted = try store.saveReturningPersistedDocument(document)
    return VaultPersistenceResult(
      document: persisted,
      removedScanRunCount: 0,
      hasLocalChanges: try syncCodec.hasLocalChanges(in: persisted)
    )
  }

  public func contentChecksum(for document: VaultDocument) throws -> String {
    try syncCodec.contentChecksum(for: document)
  }

  public func hasLocalChanges(in document: VaultDocument) throws -> Bool {
    try syncCodec.hasLocalChanges(in: document)
  }

  public func sealSyncSnapshot(
    document: VaultDocument,
    vaultKey: Data,
    version: Int,
    accountId: String
  ) throws -> (snapshot: RemoteVaultSnapshot, contentChecksum: String) {
    let checksum = try syncCodec.contentChecksum(for: document)
    let snapshot = try syncCodec.seal(
      document: document,
      vaultKey: vaultKey,
      version: version,
      accountId: accountId
    )
    return (snapshot, checksum)
  }

  public func openSyncSnapshot(
    _ snapshot: RemoteVaultSnapshot,
    vaultKey: Data,
    expectedAccountId: String
  ) throws -> OpenedVaultSnapshot {
    try syncCodec.open(
      snapshot: snapshot,
      vaultKey: vaultKey,
      expectedAccountId: expectedAccountId
    )
  }

  public func validateRemoteSnapshot(_ snapshot: RemoteVaultSnapshot) throws {
    try syncCodec.validateRemoteSnapshot(snapshot)
  }

  public func savePendingVaultUpload(
    _ upload: PendingVaultUpload,
    vaultKey: Data
  ) throws {
    try validatePendingVaultUpload(upload, vaultKey: vaultKey)
    try store.savePendingVaultUpload(upload)
  }

  public func loadPendingVaultUpload(vaultKey: Data) throws -> PendingVaultUpload? {
    guard let upload = try store.loadPendingVaultUpload() else { return nil }
    try validatePendingVaultUpload(upload, vaultKey: vaultKey)
    return upload
  }

  public func completePendingVaultUpload(
    _ upload: PendingVaultUpload,
    currentDocument: VaultDocument,
    vaultKey: Data,
    localSessionToken: String? = nil
  ) throws -> VaultPersistenceResult {
    try validatePendingVaultUpload(upload, vaultKey: vaultKey)
    guard try syncCodec.contentChecksum(for: currentDocument) == upload.baseLocalContentChecksum
    else {
      throw PendingVaultUploadError.localDocumentChanged
    }
    if let localSessionToken {
      guard SyncSessionToken.isValid(localSessionToken) else {
        throw PendingVaultUploadError.invalidOperation
      }
    }
    let persisted = try store.completePendingVaultUpload(
      upload,
      localSessionToken: localSessionToken
    )
    return VaultPersistenceResult(
      document: persisted,
      removedScanRunCount: upload.removedScanRunCount,
      hasLocalChanges: try syncCodec.hasLocalChanges(in: persisted)
    )
  }

  public func abandonPendingVaultUpload(
    _ upload: PendingVaultUpload,
    currentDocument: VaultDocument,
    vaultKey: Data
  ) throws -> VaultPersistenceResult {
    try validatePendingVaultUpload(upload, vaultKey: vaultKey)
    guard try syncCodec.contentChecksum(for: currentDocument) == upload.baseLocalContentChecksum
    else {
      throw PendingVaultUploadError.localDocumentChanged
    }
    let persisted = try store.abandonPendingVaultUpload(upload)
    return VaultPersistenceResult(
      document: persisted,
      removedScanRunCount: 0,
      hasLocalChanges: try syncCodec.hasLocalChanges(in: persisted)
    )
  }

  public func cancelPendingVaultUploadBeforeUpload(
    _ upload: PendingVaultUpload,
    vaultKey: Data
  ) throws {
    try validatePendingVaultUpload(upload, vaultKey: vaultKey)
    try store.cancelPendingVaultUploadBeforeUpload(upload)
  }

  public func markingSynced(
    _ document: VaultDocument,
    snapshot: RemoteVaultSnapshot
  ) throws -> VaultDocument {
    var updated = document
    try syncCodec.markSynced(document: &updated, snapshot: snapshot)
    return updated
  }

  public func prepareForSyncPersistence(
    _ input: VaultDocument,
    projectedVersion: Int? = nil
  ) throws -> (document: VaultDocument, removedScanRunCount: Int) {
    guard let accountId = input.syncState.accountId,
      syncCodec.isValidAccountId(accountId)
    else {
      return (input, 0)
    }

    let version =
      try projectedVersion
      ?? syncCodec.versionForNextSyncSizeProjection(
        after: input.syncState.latestRemoteVersion
      )
    func projectedByteCount(_ document: VaultDocument) throws -> Int {
      let current = try syncCodec.encodedSnapshotByteCount(
        document: document,
        accountId: accountId
      )
      let afterMarkSynced = try syncCodec.projectedPostSyncSnapshotByteCount(
        document: document,
        version: version,
        accountId: accountId
      )
      return max(current, afterMarkSynced)
    }

    let fullByteCount = try projectedByteCount(input)
    guard fullByteCount > syncSnapshotByteLimit else { return (input, 0) }

    let newestFirst = input.scanRuns.sorted { lhs, rhs in
      if lhs.generatedAt != rhs.generatedAt { return lhs.generatedAt > rhs.generatedAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }
    guard let newest = newestFirst.first else {
      throw VaultSyncSnapshotTooLargeError(
        actualByteCount: fullByteCount,
        maximumByteCount: syncSnapshotByteLimit
      )
    }

    var newestOnly = input
    newestOnly.scanRuns = [newest]
    let minimumByteCount = try projectedByteCount(newestOnly)
    guard minimumByteCount <= syncSnapshotByteLimit else {
      throw VaultSyncSnapshotTooLargeError(
        actualByteCount: minimumByteCount,
        maximumByteCount: syncSnapshotByteLimit
      )
    }

    var bestKeptCount = 1
    var lowerBound = 2
    var upperBound = newestFirst.count - 1
    while lowerBound <= upperBound {
      let midpoint = lowerBound + (upperBound - lowerBound) / 2
      var candidate = input
      candidate.scanRuns = Array(newestFirst.prefix(midpoint))
      if try projectedByteCount(candidate) <= syncSnapshotByteLimit {
        bestKeptCount = midpoint
        lowerBound = midpoint + 1
      } else {
        upperBound = midpoint - 1
      }
    }

    var pruned = input
    pruned.scanRuns = Array(newestFirst.prefix(bestKeptCount))
    return (pruned, newestFirst.count - bestKeptCount)
  }

  private func validatePendingVaultUpload(
    _ upload: PendingVaultUpload,
    vaultKey: Data
  ) throws {
    let canonicalOrigin = SyncServerURL.validatedOrigin(upload.serverOrigin)
    let normalizedAccount = SyncAccountIdentifier.normalized(upload.accountId)
    let expectedMetadataIsPaired =
      (upload.expectedRemoteVersion == nil) == (upload.expectedRemoteChecksum == nil)
    let expectedVersionIsExact: Bool
    if let expectedRemoteVersion = upload.expectedRemoteVersion,
      let expectedRemoteChecksum = upload.expectedRemoteChecksum
    {
      expectedVersionIsExact =
        (try? syncCodec.nextVersion(after: expectedRemoteVersion)) == upload.snapshot.version
        && expectedRemoteChecksum != upload.snapshot.checksum
    } else {
      expectedVersionIsExact = upload.snapshot.version == 1
    }
    guard
      upload.schemaVersion == PendingVaultUpload.currentSchemaVersion,
      let operationUUID = UUID(uuidString: upload.operationId),
      operationUUID.uuidString.lowercased() == upload.operationId,
      canonicalOrigin?.absoluteString == upload.serverOrigin,
      normalizedAccount == upload.accountId,
      expectedMetadataIsPaired,
      expectedVersionIsExact,
      upload.expectedRemoteChecksum.map(Self.isChecksum) ?? true,
      Self.isChecksum(upload.baseLocalContentChecksum),
      upload.removedScanRunCount >= 0,
      upload.createdAt.timeIntervalSince1970.isFinite,
      upload.postCommitDocument.syncState.accountId == upload.accountId,
      SyncServerURL.validatedOrigin(upload.postCommitDocument.syncState.serverURL)?.absoluteString
        == upload.serverOrigin,
      upload.postCommitDocument.syncState.latestRemoteVersion == upload.snapshot.version,
      upload.postCommitDocument.syncState.lastChecksum == upload.snapshot.checksum,
      SyncSessionToken.isValid(upload.postCommitDocument.syncState.sessionToken),
      upload.postCommitDocument.syncState.lastSyncedContentChecksum
        == (try syncCodec.contentChecksum(for: upload.postCommitDocument))
    else {
      throw PendingVaultUploadError.invalidOperation
    }
    try syncCodec.validateRemoteSnapshot(upload.snapshot)
    let opened = try syncCodec.open(
      snapshot: upload.snapshot,
      vaultKey: vaultKey,
      expectedAccountId: upload.accountId
    )
    guard
      !opened.requiresV2Upgrade,
      try syncCodec.contentChecksum(for: opened.document)
        == upload.postCommitDocument.syncState.lastSyncedContentChecksum
    else {
      throw PendingVaultUploadError.invalidOperation
    }
  }

  private static func isChecksum(_ value: String) -> Bool {
    value.count == 64
      && value.unicodeScalars.allSatisfy { scalar in
        (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
      }
  }
}
