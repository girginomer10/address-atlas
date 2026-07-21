import CryptoKit
import Darwin
import Foundation
import SQLite3

public enum EncryptedSQLiteVaultStoreError: Error, Equatable, LocalizedError {
  case openFailed(String)
  case prepareFailed(String)
  case stepFailed(String)
  case bindFailed(String)
  case filePermissionsFailed(String)
  case missingDocument
  case invalidRow
  case staleDocument
  case pendingUploadExists
  case pendingUploadMissing
  case pendingUploadMismatch

  public var errorDescription: String? {
    switch self {
    case .openFailed:
      return
        "The encrypted local vault could not be opened safely. Verify that the app's data folder is available and try again."
    case .prepareFailed, .stepFailed, .bindFailed:
      return
        "The encrypted local vault storage operation failed safely. No unconfirmed changes were applied."
    case .filePermissionsFailed:
      return
        "The local vault's owner-only file protection could not be verified. Address Atlas did not open or modify the unsafe path."
    case .missingDocument:
      return "The requested encrypted local vault or rollback checkpoint is no longer available."
    case .invalidRow:
      return
        "The encrypted local vault contains invalid or oversized data. Address Atlas stopped before loading it into memory."
    case .staleDocument:
      return
        "The local vault changed in another Address Atlas process. Reopen the app before saving again."
    case .pendingUploadExists:
      return "Another encrypted vault upload is already pending recovery."
    case .pendingUploadMissing, .pendingUploadMismatch:
      return "The encrypted upload recovery record changed unexpectedly."
    }
  }
}

public final class EncryptedSQLiteVaultStore: @unchecked Sendable {
  private struct DatabaseFileIdentity {
    var device: dev_t
    var inode: ino_t
  }

  private struct PreparedDocument {
    var document: VaultDocument
    var envelopeBytes: Data
    var timestamp: String
  }

  private static let pendingUploadRowId = "vault-upload"
  private static let rollbackCheckpointRowId = "pre-destructive-sync"
  private static let pendingUploadKeyId = "local-sync-operation-v1"
  private static let pendingUploadAuthenticatedData = Data(
    "address-atlas:pending-vault-upload:v1".utf8
  )
  /// The encrypted body is base64url-encoded inside a small JSON envelope.
  /// Bound the SQLite value itself so a substituted/legacy row cannot force an
  /// unbounded allocation before `VaultCrypto` validates the decoded body.
  static let maximumStoredEnvelopeByteCount =
    ((VaultCrypto.maximumEnvelopeBodyByteCount + 2) / 3) * 4 + 16_384

  private let path: URL
  private let crypto: VaultCrypto
  private let key: SymmetricKey
  private let syncOperationKey: SymmetricKey
  private let storedEnvelopeByteLimit: Int
  private let operationLock = NSLock()
  /// Revision observed by this store instance. Zero represents an observed
  /// empty table; nil means the caller has not loaded through this instance.
  private var expectedRevision: Int?
  /// Keep the exact encrypted baseline as a second CAS predicate. A pre-CAS
  /// app binary can update the row without incrementing `revision`; comparing
  /// the blob still detects that mixed-version writer.
  private var expectedEnvelopeBytes: Data?

  public convenience init(
    path: URL,
    vaultKey: Data,
    crypto: VaultCrypto = VaultCrypto()
  ) throws {
    try self.init(
      path: path,
      vaultKey: vaultKey,
      crypto: crypto,
      maximumStoredEnvelopeByteCount: Self.maximumStoredEnvelopeByteCount
    )
  }

  /// Focused test seam that can only tighten the production encoded-row cap.
  init(
    path: URL,
    vaultKey: Data,
    crypto: VaultCrypto,
    maximumStoredEnvelopeByteCount: Int
  ) throws {
    precondition(
      (1_024...Self.maximumStoredEnvelopeByteCount)
        .contains(maximumStoredEnvelopeByteCount)
    )
    self.path = path
    self.crypto = crypto
    self.key = try crypto.deriveKey(from: vaultKey, purpose: .localDatabase)
    self.syncOperationKey = try crypto.deriveKey(from: vaultKey, purpose: .syncOperation)
    self.storedEnvelopeByteLimit = maximumStoredEnvelopeByteCount
  }

  public func initialize() throws {
    operationLock.lock()
    defer { operationLock.unlock() }
    try initializeLocked()
  }

  private func initializeLocked() throws {
    try prepareDatabaseDirectory()
    let db = try openDatabase()
    defer { sqlite3_close(db) }
    try exec(
      """
      CREATE TABLE IF NOT EXISTS encrypted_vault_documents (
        id TEXT PRIMARY KEY NOT NULL,
        envelope_json BLOB NOT NULL,
        updated_at TEXT NOT NULL,
        revision INTEGER NOT NULL DEFAULT 1
      );
      """,
      db: db
    )
    try exec(
      """
      CREATE TABLE IF NOT EXISTS encrypted_pending_sync_operations (
        id TEXT PRIMARY KEY NOT NULL,
        envelope_json BLOB NOT NULL,
        updated_at TEXT NOT NULL
      );
      """,
      db: db
    )
    try exec(
      """
      CREATE TABLE IF NOT EXISTS encrypted_vault_checkpoints (
        id TEXT PRIMARY KEY NOT NULL,
        envelope_json BLOB NOT NULL,
        created_at TEXT NOT NULL
      );
      """,
      db: db
    )
    if try !hasRevisionColumn(db) {
      let migrationStatus = sqlite3_exec(
        db,
        "ALTER TABLE encrypted_vault_documents ADD COLUMN revision INTEGER NOT NULL DEFAULT 1;",
        nil,
        nil,
        nil
      )
      // A second process may have completed the same migration while this one
      // waited for SQLite's write lock. Treat that race as success only after
      // re-reading the authoritative schema.
      if migrationStatus != SQLITE_OK {
        guard try hasRevisionColumn(db) else {
          throw EncryptedSQLiteVaultStoreError.stepFailed(errorMessage(db))
        }
      }
    }
    // A pre-CAS app binary updates the whole encrypted row without mentioning
    // `revision`. Reject such mixed-version writes after migration so an older
    // process can fail visibly but can never overwrite a newer process's save.
    try exec(
      """
      CREATE TRIGGER IF NOT EXISTS encrypted_vault_documents_revision_guard
      BEFORE UPDATE OF envelope_json ON encrypted_vault_documents
      FOR EACH ROW
      WHEN NEW.envelope_json IS NOT OLD.envelope_json
        AND NEW.revision != OLD.revision + 1
      BEGIN
        SELECT RAISE(ABORT, 'vault revision must advance with envelope update');
      END;
      """,
      db: db
    )
    // Once an exact remote upload can be in flight, no process may mutate the
    // primary document outside the atomic completion transaction. These
    // database-level guards also stop older app processes that know nothing
    // about the in-memory pending flag.
    try exec(
      """
      CREATE TRIGGER IF NOT EXISTS encrypted_vault_documents_pending_insert_guard
      BEFORE INSERT ON encrypted_vault_documents
      WHEN EXISTS (
        SELECT 1 FROM encrypted_pending_sync_operations WHERE id = 'vault-upload'
      )
      BEGIN
        SELECT RAISE(ABORT, 'vault upload recovery is pending');
      END;

      CREATE TRIGGER IF NOT EXISTS encrypted_vault_documents_pending_update_guard
      BEFORE UPDATE ON encrypted_vault_documents
      WHEN EXISTS (
        SELECT 1 FROM encrypted_pending_sync_operations WHERE id = 'vault-upload'
      )
      BEGIN
        SELECT RAISE(ABORT, 'vault upload recovery is pending');
      END;

      CREATE TRIGGER IF NOT EXISTS encrypted_vault_documents_pending_delete_guard
      BEFORE DELETE ON encrypted_vault_documents
      WHEN EXISTS (
        SELECT 1 FROM encrypted_pending_sync_operations WHERE id = 'vault-upload'
      )
      BEGIN
        SELECT RAISE(ABORT, 'vault upload recovery is pending');
      END;
      """,
      db: db
    )
  }

  public func load() throws -> VaultDocument {
    operationLock.lock()
    defer { operationLock.unlock() }
    try initializeLocked()
    let db = try openDatabase()
    defer { sqlite3_close(db) }

    let sql =
      "SELECT envelope_json, revision FROM encrypted_vault_documents WHERE id = 'primary' LIMIT 1;"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw EncryptedSQLiteVaultStoreError.prepareFailed(errorMessage(db))
    }
    defer { sqlite3_finalize(statement) }

    let status = sqlite3_step(statement)
    if status == SQLITE_DONE {
      expectedRevision = 0
      expectedEnvelopeBytes = nil
      return VaultDocument()
    }
    guard status == SQLITE_ROW else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(errorMessage(db))
    }
    let data = try boundedBlob(from: statement, index: 0)
    let envelope = try JSONDecoder.addressAtlas.decode(EncryptedVaultEnvelope.self, from: data)
    let revision = sqlite3_column_int64(statement, 1)
    guard revision >= 1, revision <= Int64(Int.max) else {
      throw EncryptedSQLiteVaultStoreError.invalidRow
    }
    let document = try crypto.openJSON(VaultDocument.self, envelope: envelope, with: key)
    expectedRevision = Int(revision)
    expectedEnvelopeBytes = data
    return document
  }

  /// Preserve the original public source contract for callers that only need
  /// durability. Internal callers that mirror the canonical persisted
  /// timestamp back into memory use `saveReturningPersistedDocument`.
  public func save(_ document: VaultDocument) throws {
    _ = try saveReturningPersistedDocument(document)
  }

  @discardableResult
  public func saveReturningPersistedDocument(_ document: VaultDocument) throws -> VaultDocument {
    operationLock.lock()
    defer { operationLock.unlock() }
    try initializeLocked()
    let prepared = try prepareDocument(document)
    let db = try openDatabase()
    defer { sqlite3_close(db) }
    let storedRevision = try persistPreparedDocument(prepared, db: db)
    expectedRevision = storedRevision
    expectedEnvelopeBytes = prepared.envelopeBytes
    return prepared.document
  }

  /// Insert a durable upload intent before the first PUT. Existing intent is
  /// never overwritten: two processes must reconcile the same operation rather
  /// than silently replacing one exact snapshot with another.
  public func savePendingVaultUpload(_ upload: PendingVaultUpload) throws {
    operationLock.lock()
    defer { operationLock.unlock() }
    try initializeLocked()
    let canonical = try canonicalPendingUpload(upload)
    let envelope = try crypto.sealJSON(
      canonical,
      with: syncOperationKey,
      keyId: Self.pendingUploadKeyId,
      schemaVersion: PendingVaultUpload.currentSchemaVersion,
      authenticatedData: Self.pendingUploadAuthenticatedData
    )
    let encoded = try JSONEncoder.addressAtlas.encode(envelope)
    let db = try openDatabase()
    defer { sqlite3_close(db) }
    try beginImmediate(db)
    var committed = false
    defer {
      if !committed { rollback(db) }
    }
    try validateCurrentDocumentBaseline(db)
    if let existing = try loadPendingVaultUpload(db: db) {
      guard existing == canonical else {
        throw EncryptedSQLiteVaultStoreError.pendingUploadExists
      }
      try commit(db)
      committed = true
      return
    }

    let sql = """
      INSERT INTO encrypted_pending_sync_operations (id, envelope_json, updated_at)
      VALUES (?, ?, ?);
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw EncryptedSQLiteVaultStoreError.prepareFailed(errorMessage(db))
    }
    defer { sqlite3_finalize(statement) }
    guard
      sqlite3_bind_text(
        statement, 1, Self.pendingUploadRowId, -1, sqliteTransientDestructor
      ) == SQLITE_OK
    else {
      throw EncryptedSQLiteVaultStoreError.bindFailed(errorMessage(db))
    }
    try bind(encoded, to: statement, index: 2, db: db)
    let timestamp = ISO8601DateFormatter().string(from: canonical.createdAt)
    guard sqlite3_bind_text(statement, 3, timestamp, -1, sqliteTransientDestructor) == SQLITE_OK
    else {
      throw EncryptedSQLiteVaultStoreError.bindFailed(errorMessage(db))
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(errorMessage(db))
    }
    try commit(db)
    committed = true
  }

  public func loadPendingVaultUpload() throws -> PendingVaultUpload? {
    operationLock.lock()
    defer { operationLock.unlock() }
    try initializeLocked()
    let db = try openDatabase()
    defer { sqlite3_close(db) }
    return try loadPendingVaultUpload(db: db)
  }

  /// Explicitly abandon replay while preserving the primary local document.
  /// Callers must obtain user confirmation; this only removes the operation
  /// lock and never downloads, uploads, or replaces vault content.
  @discardableResult
  public func abandonPendingVaultUpload(
    _ expectedUpload: PendingVaultUpload
  ) throws -> VaultDocument {
    operationLock.lock()
    defer { operationLock.unlock() }
    try initializeLocked()
    let db = try openDatabase()
    defer { sqlite3_close(db) }
    try beginImmediate(db)
    var committed = false
    defer {
      if !committed { rollback(db) }
    }
    try validateCurrentDocumentBaseline(db)
    guard let pending = try loadPendingVaultUpload(db: db), pending == expectedUpload else {
      throw EncryptedSQLiteVaultStoreError.pendingUploadMismatch
    }
    var uncertainDocument = try documentAtExpectedBaseline()
    uncertainDocument.syncState.lastSyncedContentChecksum = nil
    uncertainDocument.syncState.remoteOutcomeUncertain = true
    let prepared = try prepareDocument(uncertainDocument)
    try deletePendingVaultUpload(db: db)
    let storedRevision = try persistPreparedDocument(prepared, db: db)
    try commit(db)
    committed = true
    expectedRevision = storedRevision
    expectedEnvelopeBytes = prepared.envelopeBytes
    return prepared.document
  }

  /// Remove an intent only when the caller proves no PUT has started. Unlike
  /// user abandonment after an ambiguous network outcome, this does not mark
  /// the remote baseline uncertain because there was no remote side effect.
  public func cancelPendingVaultUploadBeforeUpload(
    _ expectedUpload: PendingVaultUpload
  ) throws {
    operationLock.lock()
    defer { operationLock.unlock() }
    try initializeLocked()
    let db = try openDatabase()
    defer { sqlite3_close(db) }
    try beginImmediate(db)
    var committed = false
    defer {
      if !committed { rollback(db) }
    }
    try validateCurrentDocumentBaseline(db)
    guard let pending = try loadPendingVaultUpload(db: db), pending == expectedUpload else {
      throw EncryptedSQLiteVaultStoreError.pendingUploadMismatch
    }
    try deletePendingVaultUpload(db: db)
    try commit(db)
    committed = true
  }

  /// Commit the exact post-upload candidate and consume its intent in one
  /// SQLite transaction. The document CAS and intent identity checks make a
  /// competing-process write fail without deleting either recovery artifact.
  @discardableResult
  public func completePendingVaultUpload(
    _ expectedUpload: PendingVaultUpload,
    localSessionToken: String? = nil
  ) throws -> VaultDocument {
    operationLock.lock()
    defer { operationLock.unlock() }
    try initializeLocked()
    let db = try openDatabase()
    defer { sqlite3_close(db) }
    try beginImmediate(db)
    var committed = false
    defer {
      if !committed { rollback(db) }
    }
    guard let pending = try loadPendingVaultUpload(db: db) else {
      throw EncryptedSQLiteVaultStoreError.pendingUploadMissing
    }
    guard pending == expectedUpload else {
      throw EncryptedSQLiteVaultStoreError.pendingUploadMismatch
    }
    try validateCurrentDocumentBaseline(db)
    var completionDocument = pending.postCommitDocument
    if let localSessionToken {
      completionDocument.syncState.sessionToken = localSessionToken
    }
    let prepared = try prepareDocument(completionDocument)
    try deletePendingVaultUpload(db: db)
    // Deleting first intentionally opens the trigger gate only inside this
    // transaction. A CAS failure rolls the delete back and preserves recovery.
    let storedRevision = try persistPreparedDocument(prepared, db: db)
    try commit(db)
    committed = true
    expectedRevision = storedRevision
    expectedEnvelopeBytes = prepared.envelopeBytes
    return prepared.document
  }

  public func rawStoredPendingVaultUploadEnvelopeBytes() throws -> Data? {
    operationLock.lock()
    defer { operationLock.unlock() }
    try initializeLocked()
    let db = try openDatabase()
    defer { sqlite3_close(db) }
    return try pendingUploadEnvelopeBytes(db: db)
  }

  /// Persist one verified, full-fidelity encrypted rollback point before a
  /// remote snapshot is allowed to replace local state. The checkpoint uses
  /// the same local-database subkey as the primary row and never exposes
  /// plaintext credentials or bearer material to the filesystem.
  @discardableResult
  public func saveRollbackCheckpoint(_ document: VaultDocument) throws -> Date {
    operationLock.lock()
    defer { operationLock.unlock() }
    try initializeLocked()
    let prepared = try prepareDocument(document)
    let db = try openDatabase()
    defer { sqlite3_close(db) }
    try beginImmediate(db)
    var committed = false
    defer {
      if !committed { rollback(db) }
    }
    try validateCurrentDocumentBaseline(db)
    if expectedRevision != 0 {
      guard try documentAtExpectedBaseline() == document else {
        throw EncryptedSQLiteVaultStoreError.staleDocument
      }
    }

    let createdAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        db,
        """
        INSERT INTO encrypted_vault_checkpoints (id, envelope_json, created_at)
        VALUES (?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          envelope_json = excluded.envelope_json,
          created_at = excluded.created_at;
        """,
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw EncryptedSQLiteVaultStoreError.prepareFailed(errorMessage(db))
    }
    defer { sqlite3_finalize(statement) }
    guard
      sqlite3_bind_text(
        statement, 1, Self.rollbackCheckpointRowId, -1, sqliteTransientDestructor
      ) == SQLITE_OK
    else {
      throw EncryptedSQLiteVaultStoreError.bindFailed(errorMessage(db))
    }
    try bind(prepared.envelopeBytes, to: statement, index: 2, db: db)
    let timestamp = ISO8601DateFormatter().string(from: createdAt)
    guard
      sqlite3_bind_text(statement, 3, timestamp, -1, sqliteTransientDestructor) == SQLITE_OK,
      sqlite3_step(statement) == SQLITE_DONE
    else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(errorMessage(db))
    }
    try commit(db)
    committed = true
    return createdAt
  }

  public func loadRollbackCheckpoint() throws -> VaultDocument? {
    operationLock.lock()
    defer { operationLock.unlock() }
    try initializeLocked()
    let db = try openDatabase()
    defer { sqlite3_close(db) }
    guard let data = try rollbackCheckpointEnvelopeBytes(db: db) else { return nil }
    let envelope = try JSONDecoder.addressAtlas.decode(EncryptedVaultEnvelope.self, from: data)
    return try crypto.openJSON(VaultDocument.self, envelope: envelope, with: key)
  }

  public func containsRollbackCheckpoint() throws -> Bool {
    operationLock.lock()
    defer { operationLock.unlock() }
    try initializeLocked()
    let db = try openDatabase()
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        db,
        "SELECT 1 FROM encrypted_vault_checkpoints WHERE id = ? LIMIT 1;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw EncryptedSQLiteVaultStoreError.prepareFailed(errorMessage(db))
    }
    defer { sqlite3_finalize(statement) }
    guard
      sqlite3_bind_text(
        statement, 1, Self.rollbackCheckpointRowId, -1, sqliteTransientDestructor
      ) == SQLITE_OK
    else {
      throw EncryptedSQLiteVaultStoreError.bindFailed(errorMessage(db))
    }
    let status = sqlite3_step(statement)
    if status == SQLITE_DONE { return false }
    guard status == SQLITE_ROW else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(errorMessage(db))
    }
    return true
  }

  /// Remove an obsolete rollback point before the caller clears or changes
  /// the sync-account binding. Baseline validation prevents a stale process
  /// from deleting recovery state that belongs to a newer local document.
  public func discardRollbackCheckpoint() throws {
    operationLock.lock()
    defer { operationLock.unlock() }
    try initializeLocked()
    let db = try openDatabase()
    defer { sqlite3_close(db) }
    try beginImmediate(db)
    var committed = false
    defer {
      if !committed { rollback(db) }
    }
    try validateCurrentDocumentBaseline(db)
    try deleteRollbackCheckpointIfPresent(db: db)
    try commit(db)
    committed = true
  }

  /// Atomically restore the checkpoint's user-controlled vault content while
  /// retaining the current primary row's sync authority, bearer grant, and
  /// authenticated remote baseline. Rewinding that baseline would make the
  /// restored content impossible to upload over the snapshot that caused the
  /// rollback. Consume the checkpoint only after the replacement commits.
  public func restoreRollbackCheckpoint() throws -> VaultDocument {
    operationLock.lock()
    defer { operationLock.unlock() }
    try initializeLocked()
    let db = try openDatabase()
    defer { sqlite3_close(db) }
    try beginImmediate(db)
    var committed = false
    defer {
      if !committed { rollback(db) }
    }
    try validateCurrentDocumentBaseline(db)
    let current = try documentAtExpectedBaseline()
    guard let data = try rollbackCheckpointEnvelopeBytes(db: db) else {
      throw EncryptedSQLiteVaultStoreError.missingDocument
    }
    let envelope = try JSONDecoder.addressAtlas.decode(EncryptedVaultEnvelope.self, from: data)
    var checkpoint = try crypto.openJSON(VaultDocument.self, envelope: envelope, with: key)
    checkpoint.syncState = current.syncState
    let prepared = try prepareDocument(checkpoint)
    let storedRevision = try persistPreparedDocument(prepared, db: db)
    try deleteRollbackCheckpoint(db: db)
    try commit(db)
    committed = true
    expectedRevision = storedRevision
    expectedEnvelopeBytes = prepared.envelopeBytes
    return prepared.document
  }

  public func rawStoredEnvelopeBytes() throws -> Data? {
    operationLock.lock()
    defer { operationLock.unlock() }
    try initializeLocked()
    let db = try openDatabase()
    defer { sqlite3_close(db) }
    let sql = "SELECT envelope_json FROM encrypted_vault_documents WHERE id = 'primary' LIMIT 1;"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw EncryptedSQLiteVaultStoreError.prepareFailed(errorMessage(db))
    }
    defer { sqlite3_finalize(statement) }
    let status = sqlite3_step(statement)
    if status == SQLITE_DONE { return nil }
    guard status == SQLITE_ROW else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(errorMessage(db))
    }
    return try boundedBlob(from: statement, index: 0)
  }

  private func prepareDocument(_ document: VaultDocument) throws -> PreparedDocument {
    var next = document
    // JSONEncoder.addressAtlas persists ISO-8601 dates at whole-second
    // precision. Canonicalize before writing so the returned updatedAt value
    // exactly matches a subsequent load.
    next.updatedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let envelope = try crypto.sealJSON(
      next,
      with: key,
      keyId: "local-db",
      schemaVersion: next.schemaVersion
    )
    // Canonicalize every nested Date as well as the root timestamp.
    let canonicalDocument = try crypto.openJSON(
      VaultDocument.self,
      envelope: envelope,
      with: key
    )
    return PreparedDocument(
      document: canonicalDocument,
      envelopeBytes: try JSONEncoder.addressAtlas.encode(envelope),
      timestamp: ISO8601DateFormatter().string(from: canonicalDocument.updatedAt)
    )
  }

  private func documentAtExpectedBaseline() throws -> VaultDocument {
    guard let expectedRevision else {
      throw EncryptedSQLiteVaultStoreError.staleDocument
    }
    if expectedRevision == 0 {
      guard expectedEnvelopeBytes == nil else {
        throw EncryptedSQLiteVaultStoreError.staleDocument
      }
      return VaultDocument()
    }
    guard let expectedEnvelopeBytes else {
      throw EncryptedSQLiteVaultStoreError.staleDocument
    }
    let envelope = try JSONDecoder.addressAtlas.decode(
      EncryptedVaultEnvelope.self,
      from: expectedEnvelopeBytes
    )
    return try crypto.openJSON(VaultDocument.self, envelope: envelope, with: key)
  }

  private func persistPreparedDocument(
    _ prepared: PreparedDocument,
    db: OpaquePointer
  ) throws -> Int {
    let revision: Int
    if let expectedRevision {
      revision = expectedRevision
    } else {
      let current = try currentRevision(db)
      // Never adopt a document that this store instance did not load.
      guard current == 0 else {
        throw EncryptedSQLiteVaultStoreError.staleDocument
      }
      revision = current
    }
    let sql =
      revision == 0
      ? """
      INSERT INTO encrypted_vault_documents (id, envelope_json, updated_at, revision)
      VALUES ('primary', ?, ?, 1)
      ON CONFLICT(id) DO NOTHING
      RETURNING revision;
      """
      : """
      UPDATE encrypted_vault_documents
      SET envelope_json = ?, updated_at = ?, revision = revision + 1
      WHERE id = 'primary'
        AND revision = ?
        AND envelope_json = ?
        AND revision < 9223372036854775807
      RETURNING revision;
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw EncryptedSQLiteVaultStoreError.prepareFailed(errorMessage(db))
    }
    defer { sqlite3_finalize(statement) }
    try bind(prepared.envelopeBytes, to: statement, index: 1, db: db)
    guard
      sqlite3_bind_text(
        statement, 2, prepared.timestamp, -1, sqliteTransientDestructor
      ) == SQLITE_OK
    else {
      throw EncryptedSQLiteVaultStoreError.bindFailed(errorMessage(db))
    }
    if revision > 0,
      sqlite3_bind_int64(statement, 3, Int64(revision)) != SQLITE_OK
    {
      throw EncryptedSQLiteVaultStoreError.bindFailed(errorMessage(db))
    }
    if revision > 0 {
      guard let expectedEnvelopeBytes else {
        throw EncryptedSQLiteVaultStoreError.staleDocument
      }
      try bind(expectedEnvelopeBytes, to: statement, index: 4, db: db)
    }
    let status = sqlite3_step(statement)
    if status == SQLITE_DONE {
      throw EncryptedSQLiteVaultStoreError.staleDocument
    }
    guard status == SQLITE_ROW else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(errorMessage(db))
    }
    let storedRevision = sqlite3_column_int64(statement, 0)
    guard
      storedRevision >= 1,
      storedRevision <= Int64(Int.max),
      sqlite3_step(statement) == SQLITE_DONE
    else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(errorMessage(db))
    }
    return Int(storedRevision)
  }

  private func canonicalPendingUpload(
    _ upload: PendingVaultUpload
  ) throws -> PendingVaultUpload {
    let encoded = try JSONEncoder.addressAtlas.encode(upload)
    return try JSONDecoder.addressAtlas.decode(PendingVaultUpload.self, from: encoded)
  }

  private func loadPendingVaultUpload(db: OpaquePointer) throws -> PendingVaultUpload? {
    guard let data = try pendingUploadEnvelopeBytes(db: db) else { return nil }
    let envelope = try JSONDecoder.addressAtlas.decode(EncryptedVaultEnvelope.self, from: data)
    guard
      envelope.schemaVersion == PendingVaultUpload.currentSchemaVersion,
      envelope.cryptoVersion == 2,
      envelope.keyId == Self.pendingUploadKeyId
    else {
      throw EncryptedSQLiteVaultStoreError.invalidRow
    }
    return try crypto.openJSON(
      PendingVaultUpload.self,
      envelope: envelope,
      with: syncOperationKey,
      authenticatedData: Self.pendingUploadAuthenticatedData
    )
  }

  private func pendingUploadEnvelopeBytes(db: OpaquePointer) throws -> Data? {
    let sql =
      "SELECT envelope_json FROM encrypted_pending_sync_operations WHERE id = ? LIMIT 1;"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw EncryptedSQLiteVaultStoreError.prepareFailed(errorMessage(db))
    }
    defer { sqlite3_finalize(statement) }
    guard
      sqlite3_bind_text(
        statement, 1, Self.pendingUploadRowId, -1, sqliteTransientDestructor
      ) == SQLITE_OK
    else {
      throw EncryptedSQLiteVaultStoreError.bindFailed(errorMessage(db))
    }
    let status = sqlite3_step(statement)
    if status == SQLITE_DONE { return nil }
    guard status == SQLITE_ROW else {
      throw EncryptedSQLiteVaultStoreError.invalidRow
    }
    return try boundedBlob(from: statement, index: 0)
  }

  private func rollbackCheckpointEnvelopeBytes(db: OpaquePointer) throws -> Data? {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        db,
        "SELECT envelope_json FROM encrypted_vault_checkpoints WHERE id = ? LIMIT 1;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw EncryptedSQLiteVaultStoreError.prepareFailed(errorMessage(db))
    }
    defer { sqlite3_finalize(statement) }
    guard
      sqlite3_bind_text(
        statement, 1, Self.rollbackCheckpointRowId, -1, sqliteTransientDestructor
      ) == SQLITE_OK
    else {
      throw EncryptedSQLiteVaultStoreError.bindFailed(errorMessage(db))
    }
    let status = sqlite3_step(statement)
    if status == SQLITE_DONE { return nil }
    guard status == SQLITE_ROW else {
      throw EncryptedSQLiteVaultStoreError.invalidRow
    }
    return try boundedBlob(from: statement, index: 0)
  }

  private func deleteRollbackCheckpoint(db: OpaquePointer) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        db,
        "DELETE FROM encrypted_vault_checkpoints WHERE id = ?;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw EncryptedSQLiteVaultStoreError.prepareFailed(errorMessage(db))
    }
    defer { sqlite3_finalize(statement) }
    guard
      sqlite3_bind_text(
        statement, 1, Self.rollbackCheckpointRowId, -1, sqliteTransientDestructor
      ) == SQLITE_OK,
      sqlite3_step(statement) == SQLITE_DONE,
      sqlite3_changes(db) == 1
    else {
      throw EncryptedSQLiteVaultStoreError.missingDocument
    }
  }

  private func deleteRollbackCheckpointIfPresent(db: OpaquePointer) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        db,
        "DELETE FROM encrypted_vault_checkpoints WHERE id = ?;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw EncryptedSQLiteVaultStoreError.prepareFailed(errorMessage(db))
    }
    defer { sqlite3_finalize(statement) }
    guard
      sqlite3_bind_text(
        statement, 1, Self.rollbackCheckpointRowId, -1, sqliteTransientDestructor
      ) == SQLITE_OK,
      sqlite3_step(statement) == SQLITE_DONE
    else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(errorMessage(db))
    }
  }

  private func deletePendingVaultUpload(db: OpaquePointer) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        db,
        "DELETE FROM encrypted_pending_sync_operations WHERE id = ?;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw EncryptedSQLiteVaultStoreError.prepareFailed(errorMessage(db))
    }
    defer { sqlite3_finalize(statement) }
    guard
      sqlite3_bind_text(
        statement, 1, Self.pendingUploadRowId, -1, sqliteTransientDestructor
      ) == SQLITE_OK,
      sqlite3_step(statement) == SQLITE_DONE,
      sqlite3_changes(db) == 1
    else {
      throw EncryptedSQLiteVaultStoreError.pendingUploadMismatch
    }
  }

  private func bind(
    _ data: Data,
    to statement: OpaquePointer?,
    index: Int32,
    db: OpaquePointer
  ) throws {
    let status = data.withUnsafeBytes { buffer in
      sqlite3_bind_blob(
        statement,
        index,
        buffer.baseAddress,
        Int32(data.count),
        sqliteTransientDestructor
      )
    }
    guard status == SQLITE_OK else {
      throw EncryptedSQLiteVaultStoreError.bindFailed(errorMessage(db))
    }
  }

  private func beginImmediate(_ db: OpaquePointer) throws {
    try exec("BEGIN IMMEDIATE TRANSACTION;", db: db)
  }

  private func commit(_ db: OpaquePointer) throws {
    try exec("COMMIT;", db: db)
  }

  private func rollback(_ db: OpaquePointer) {
    _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
  }

  private func openDatabase() throws -> OpaquePointer {
    let securedIdentity = try secureDatabaseFile()
    // macOS exposes its temporary directory through the system `/var`
    // symlink. Resolve only the already-validated parent; retaining the leaf
    // filename lets SQLITE_OPEN_NOFOLLOW continue to reject a substituted
    // database path without breaking that standard system layout.
    let sqlitePath = try canonicalDatabasePath()
    var db: OpaquePointer?
    let status = sqlite3_open_v2(
      sqlitePath,
      &db,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
      nil
    )
    guard status == SQLITE_OK, let opened = db else {
      let message = db.map(errorMessage) ?? "unknown"
      if let db { sqlite3_close(db) }
      throw EncryptedSQLiteVaultStoreError.openFailed(message)
    }
    guard databaseFile(at: sqlitePath, matches: securedIdentity) else {
      sqlite3_close(opened)
      throw EncryptedSQLiteVaultStoreError.filePermissionsFailed(
        "The vault database changed while it was being opened."
      )
    }
    _ = sqlite3_limit(opened, SQLITE_LIMIT_LENGTH, Int32(storedEnvelopeByteLimit))
    guard
      Int(sqlite3_limit(opened, SQLITE_LIMIT_LENGTH, -1)) <= storedEnvelopeByteLimit
    else {
      sqlite3_close(opened)
      throw EncryptedSQLiteVaultStoreError.openFailed("Could not enforce the vault row-size limit.")
    }
    guard sqlite3_busy_timeout(opened, 5_000) == SQLITE_OK else {
      let message = errorMessage(opened)
      sqlite3_close(opened)
      throw EncryptedSQLiteVaultStoreError.openFailed(message)
    }
    return opened
  }

  private func canonicalDatabasePath() throws -> String {
    let directory = path.deletingLastPathComponent()
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let resolved = directory.path.withCString { source in
      buffer.withUnsafeMutableBufferPointer { destination in
        Darwin.realpath(source, destination.baseAddress)
      }
    }
    guard resolved != nil else {
      throw EncryptedSQLiteVaultStoreError.openFailed(String(cString: strerror(errno)))
    }
    return URL(filePath: String(cString: buffer))
      .appending(path: path.lastPathComponent)
      .path
  }

  /// Create or validate only the app-owned leaf directory. Rejecting a
  /// symlinked leaf keeps SQLite and its journal files inside the intended
  /// owner-only container.
  private func prepareDatabaseDirectory() throws {
    let directory = path.deletingLastPathComponent()
    var metadata = stat()
    let status = directory.path.withCString { Darwin.lstat($0, &metadata) }
    if status == 0 {
      guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
        metadata.st_uid == geteuid()
      else {
        throw EncryptedSQLiteVaultStoreError.filePermissionsFailed(
          "The vault directory is not an app-owned directory."
        )
      }
    } else if errno == ENOENT {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } else {
      throw EncryptedSQLiteVaultStoreError.filePermissionsFailed(
        String(cString: strerror(errno))
      )
    }

    let descriptor = directory.path.withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
      throw EncryptedSQLiteVaultStoreError.filePermissionsFailed(
        String(cString: strerror(errno))
      )
    }
    defer { Darwin.close(descriptor) }
    var openedMetadata = stat()
    guard Darwin.fstat(descriptor, &openedMetadata) == 0,
      (openedMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
      openedMetadata.st_uid == geteuid(),
      Darwin.fchmod(descriptor, S_IRWXU) == 0
    else {
      throw EncryptedSQLiteVaultStoreError.filePermissionsFailed(
        String(cString: strerror(errno))
      )
    }
  }

  /// Pre-create new databases as owner-only and repair permissions on an
  /// existing database before SQLite opens it. Using a file descriptor avoids
  /// a group/world-readable creation window caused by the process umask.
  private func secureDatabaseFile() throws -> DatabaseFileIdentity {
    let permissions = mode_t(S_IRUSR | S_IWUSR)
    let descriptor = Darwin.open(
      path.path,
      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
      permissions
    )
    guard descriptor >= 0 else {
      throw EncryptedSQLiteVaultStoreError.openFailed(String(cString: strerror(errno)))
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      metadata.st_uid == geteuid(),
      metadata.st_nlink == 1
    else {
      throw EncryptedSQLiteVaultStoreError.filePermissionsFailed(
        "The vault database is not a single app-owned regular file."
      )
    }
    guard fchmod(descriptor, permissions) == 0 else {
      throw EncryptedSQLiteVaultStoreError.filePermissionsFailed(String(cString: strerror(errno)))
    }
    return DatabaseFileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
  }

  private func databaseFile(
    at canonicalPath: String,
    matches identity: DatabaseFileIdentity
  ) -> Bool {
    var metadata = stat()
    return canonicalPath.withCString { Darwin.lstat($0, &metadata) } == 0
      && (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
      && metadata.st_uid == geteuid()
      && metadata.st_nlink == 1
      && metadata.st_dev == identity.device
      && metadata.st_ino == identity.inode
  }

  private func boundedBlob(
    from statement: OpaquePointer?,
    index: Int32
  ) throws -> Data {
    let byteCount = Int(sqlite3_column_bytes(statement, index))
    guard byteCount > 0,
      byteCount <= storedEnvelopeByteLimit,
      let blob = sqlite3_column_blob(statement, index)
    else {
      throw EncryptedSQLiteVaultStoreError.invalidRow
    }
    return Data(bytes: blob, count: byteCount)
  }

  private func exec(_ sql: String, db: OpaquePointer) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(errorMessage(db))
    }
  }

  private func hasRevisionColumn(_ db: OpaquePointer) throws -> Bool {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(db, "PRAGMA table_info(encrypted_vault_documents);", -1, &statement, nil)
        == SQLITE_OK
    else {
      throw EncryptedSQLiteVaultStoreError.prepareFailed(errorMessage(db))
    }
    defer { sqlite3_finalize(statement) }
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        if let name = sqlite3_column_text(statement, 1), String(cString: name) == "revision" {
          return true
        }
      case SQLITE_DONE:
        return false
      default:
        throw EncryptedSQLiteVaultStoreError.stepFailed(errorMessage(db))
      }
    }
  }

  private func validateCurrentDocumentBaseline(_ db: OpaquePointer) throws {
    guard let expectedRevision else {
      throw EncryptedSQLiteVaultStoreError.staleDocument
    }
    let sql =
      "SELECT envelope_json, revision FROM encrypted_vault_documents WHERE id = 'primary' LIMIT 1;"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw EncryptedSQLiteVaultStoreError.prepareFailed(errorMessage(db))
    }
    defer { sqlite3_finalize(statement) }
    let status = sqlite3_step(statement)
    if expectedRevision == 0 {
      guard status == SQLITE_DONE, expectedEnvelopeBytes == nil else {
        throw EncryptedSQLiteVaultStoreError.staleDocument
      }
      return
    }
    guard status == SQLITE_ROW,
      sqlite3_column_int64(statement, 1) == Int64(expectedRevision),
      let expectedEnvelopeBytes
    else {
      throw EncryptedSQLiteVaultStoreError.staleDocument
    }
    let currentEnvelope = try boundedBlob(from: statement, index: 0)
    guard currentEnvelope == expectedEnvelopeBytes else {
      throw EncryptedSQLiteVaultStoreError.staleDocument
    }
  }

  private func currentRevision(_ db: OpaquePointer) throws -> Int {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        db,
        "SELECT revision FROM encrypted_vault_documents WHERE id = 'primary' LIMIT 1;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else {
      throw EncryptedSQLiteVaultStoreError.prepareFailed(errorMessage(db))
    }
    defer { sqlite3_finalize(statement) }
    let status = sqlite3_step(statement)
    if status == SQLITE_DONE { return 0 }
    guard status == SQLITE_ROW else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(errorMessage(db))
    }
    let revision = sqlite3_column_int64(statement, 0)
    guard revision >= 1, revision <= Int64(Int.max) else {
      throw EncryptedSQLiteVaultStoreError.invalidRow
    }
    return Int(revision)
  }

  private func errorMessage(_ db: OpaquePointer) -> String {
    String(cString: sqlite3_errmsg(db))
  }
}

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
