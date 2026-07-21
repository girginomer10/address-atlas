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

public enum PendingVaultUploadError: Error, Equatable, LocalizedError, Sendable {
  case invalidOperation
  case operationAlreadyPending
  case operationMissing
  case operationMismatch
  case localDocumentChanged
  case remoteConflict

  public var errorDescription: String? {
    switch self {
    case .invalidOperation:
      "The saved upload recovery record is invalid. The local vault was not changed."
    case .operationAlreadyPending:
      "Another encrypted vault upload is already pending recovery."
    case .operationMissing:
      "The pending upload recovery record is missing. The local vault was not changed."
    case .operationMismatch:
      "The pending upload recovery record changed unexpectedly. The local vault was not changed."
    case .localDocumentChanged:
      "The local vault changed while an upload was pending. Recovery stopped without overwriting it."
    case .remoteConflict:
      "The remote vault diverged while an upload was pending. Recovery stopped without overwriting either vault."
    }
  }
}
