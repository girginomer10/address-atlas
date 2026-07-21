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
    case .staleDocument:
      return
        "The local vault changed in another Address Atlas process. Reopen the app before saving again."
    case .pendingUploadExists:
      return "Another encrypted vault upload is already pending recovery."
    case .pendingUploadMissing, .pendingUploadMismatch:
      return "The encrypted upload recovery record changed unexpectedly."
    default:
      return nil
    }
  }
}

public final class EncryptedSQLiteVaultStore: @unchecked Sendable {
  private struct PreparedDocument {
    var document: VaultDocument
    var envelopeBytes: Data
    var timestamp: String
  }

  private static let pendingUploadRowId = "vault-upload"
  private static let pendingUploadKeyId = "local-sync-operation-v1"
  private static let pendingUploadAuthenticatedData = Data(
    "address-atlas:pending-vault-upload:v1".utf8
  )

  private let path: URL
  private let crypto: VaultCrypto
  private let key: SymmetricKey
  private let syncOperationKey: SymmetricKey
  private let operationLock = NSLock()
  /// Revision observed by this store instance. Zero represents an observed
  /// empty table; nil means the caller has not loaded through this instance.
  private var expectedRevision: Int?
  /// Keep the exact encrypted baseline as a second CAS predicate. A pre-CAS
  /// app binary can update the row without incrementing `revision`; comparing
  /// the blob still detects that mixed-version writer.
  private var expectedEnvelopeBytes: Data?

  public init(path: URL, vaultKey: Data, crypto: VaultCrypto = VaultCrypto()) throws {
    self.path = path
    self.crypto = crypto
    self.key = try crypto.deriveKey(from: vaultKey, purpose: .localDatabase)
    self.syncOperationKey = try crypto.deriveKey(from: vaultKey, purpose: .syncOperation)
  }

  public func initialize() throws {
    operationLock.lock()
    defer { operationLock.unlock() }
    try initializeLocked()
  }

  private func initializeLocked() throws {
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
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
    guard let blob = sqlite3_column_blob(statement, 0) else {
      throw EncryptedSQLiteVaultStoreError.invalidRow
    }
    let count = Int(sqlite3_column_bytes(statement, 0))
    let data = Data(bytes: blob, count: count)
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
    guard sqlite3_step(statement) == SQLITE_ROW else {
      return nil
    }
    guard let blob = sqlite3_column_blob(statement, 0) else {
      throw EncryptedSQLiteVaultStoreError.invalidRow
    }
    return Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
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
    guard status == SQLITE_ROW, let blob = sqlite3_column_blob(statement, 0) else {
      throw EncryptedSQLiteVaultStoreError.invalidRow
    }
    return Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
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
    try secureDatabaseFile()
    var db: OpaquePointer?
    let status = sqlite3_open_v2(
      path.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    guard status == SQLITE_OK, let opened = db else {
      let message = db.map(errorMessage) ?? "unknown"
      if let db { sqlite3_close(db) }
      throw EncryptedSQLiteVaultStoreError.openFailed(message)
    }
    guard sqlite3_busy_timeout(opened, 5_000) == SQLITE_OK else {
      let message = errorMessage(opened)
      sqlite3_close(opened)
      throw EncryptedSQLiteVaultStoreError.openFailed(message)
    }
    return opened
  }

  /// Pre-create new databases as owner-only and repair permissions on an
  /// existing database before SQLite opens it. Using a file descriptor avoids
  /// a group/world-readable creation window caused by the process umask.
  private func secureDatabaseFile() throws {
    let permissions = mode_t(S_IRUSR | S_IWUSR)
    let descriptor = Darwin.open(path.path, O_RDWR | O_CREAT | O_CLOEXEC, permissions)
    guard descriptor >= 0 else {
      throw EncryptedSQLiteVaultStoreError.openFailed(String(cString: strerror(errno)))
    }
    defer { Darwin.close(descriptor) }
    guard fchmod(descriptor, permissions) == 0 else {
      throw EncryptedSQLiteVaultStoreError.filePermissionsFailed(String(cString: strerror(errno)))
    }
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
    guard
      status == SQLITE_ROW,
      let blob = sqlite3_column_blob(statement, 0),
      sqlite3_column_int64(statement, 1) == Int64(expectedRevision),
      let expectedEnvelopeBytes
    else {
      throw EncryptedSQLiteVaultStoreError.staleDocument
    }
    let currentEnvelope = Data(
      bytes: blob,
      count: Int(sqlite3_column_bytes(statement, 0))
    )
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
