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
    let prepared = try prepareForSyncPersistence(
      input,
      projectedVersion: projectedSyncVersion
    )
    let persisted = try store.saveReturningPersistedDocument(prepared.document)
    return VaultPersistenceResult(
      document: persisted,
      removedScanRunCount: prepared.removedScanRunCount,
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
}
