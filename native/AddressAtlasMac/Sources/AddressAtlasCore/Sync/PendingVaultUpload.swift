import Foundation

/// Durable, encrypted intent for the only ambiguous sync side effect: an
/// upload whose response may be lost after the server commits it. The exact
/// sealed snapshot is retained so recovery can replay byte-for-byte rather
/// than producing a new nonce and an unrelated checksum.
public struct PendingVaultUpload: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var operationId: String
  public var serverOrigin: String
  public var accountId: String
  public var expectedRemoteVersion: Int?
  public var expectedRemoteChecksum: String?
  public var snapshot: RemoteVaultSnapshot
  public var postCommitDocument: VaultDocument
  public var baseLocalContentChecksum: String
  public var removedScanRunCount: Int
  public var createdAt: Date

  public init(
    schemaVersion: Int = PendingVaultUpload.currentSchemaVersion,
    operationId: String = UUID().uuidString.lowercased(),
    serverOrigin: String,
    accountId: String,
    expectedRemoteVersion: Int?,
    expectedRemoteChecksum: String?,
    snapshot: RemoteVaultSnapshot,
    postCommitDocument: VaultDocument,
    baseLocalContentChecksum: String,
    removedScanRunCount: Int,
    createdAt: Date = Date()
  ) {
    self.schemaVersion = schemaVersion
    self.operationId = operationId
    self.serverOrigin = serverOrigin
    self.accountId = accountId
    self.expectedRemoteVersion = expectedRemoteVersion
    self.expectedRemoteChecksum = expectedRemoteChecksum
    self.snapshot = snapshot
    self.postCommitDocument = postCommitDocument
    self.baseLocalContentChecksum = baseLocalContentChecksum
    self.removedScanRunCount = removedScanRunCount
    self.createdAt = createdAt
  }
}

/// Non-secret identity for an opaque journal row that could not be safely
/// decoded or authenticated. The encrypted bytes remain untouched in SQLite;
/// this fingerprint only protects an explicit discard from racing replacement.
public struct QuarantinedPendingVaultUpload: Codable, Equatable, Sendable {
  public var encryptedRowSHA256: String
  public var encryptedByteCount: Int

  public init(encryptedRowSHA256: String, encryptedByteCount: Int) {
    self.encryptedRowSHA256 = encryptedRowSHA256
    self.encryptedByteCount = encryptedByteCount
  }
}

public enum PendingVaultUploadInspection: Equatable, Sendable {
  case none
  case pending(PendingVaultUpload, QuarantinedPendingVaultUpload)
  case quarantined(QuarantinedPendingVaultUpload)
}

public enum PendingVaultUploadError: Error, Equatable, LocalizedError, Sendable {
  case invalidOperation
  case operationAlreadyPending
  case operationMissing
  case operationMismatch
  case quarantinedOperation
  case localDocumentChanged
  case remoteConflict

  public var errorDescription: String? {
    switch self {
    case .invalidOperation:
      "The record of the unfinished upload isn't valid. Your saved portfolio wasn't changed."
    case .operationAlreadyPending:
      "Another upload is already waiting for recovery."
    case .operationMissing:
      "The record of the unfinished upload is missing. Your saved portfolio wasn't changed."
    case .operationMismatch:
      "The record of the unfinished upload changed unexpectedly. Your saved portfolio wasn't changed."
    case .quarantinedOperation:
      "The record of the unfinished upload is damaged and was set aside. Your saved portfolio is still available, but read-only."
    case .localDocumentChanged:
      "Your portfolio changed while an upload was unfinished. Recovery stopped, and nothing was overwritten."
    case .remoteConflict:
      "The copy on the sync server changed while an upload was unfinished. Recovery stopped, and neither copy was overwritten."
    }
  }
}
