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

  public var errorDescription: String? {
    switch self {
    case .staleDocument:
      return "The local vault changed in another Address Atlas process. Reopen the app before saving again."
    default:
      return nil
    }
  }
}

public final class EncryptedSQLiteVaultStore: @unchecked Sendable {
  private let path: URL
  private let crypto: VaultCrypto
  private let key: SymmetricKey
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
  }

  public func initialize() throws {
    operationLock.lock()
    defer { operationLock.unlock() }
    try initializeLocked()
  }

  private func initializeLocked() throws {
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
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
  }

  public func load() throws -> VaultDocument {
    operationLock.lock()
    defer { operationLock.unlock() }
    try initializeLocked()
    let db = try openDatabase()
    defer { sqlite3_close(db) }

    let sql = "SELECT envelope_json, revision FROM encrypted_vault_documents WHERE id = 'primary' LIMIT 1;"
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

  public func save(_ document: VaultDocument) throws {
    operationLock.lock()
    defer { operationLock.unlock() }
    try initializeLocked()
    var next = document
    next.updatedAt = Date()
    let envelope = try crypto.sealJSON(
      next,
      with: key,
      keyId: "local-db",
      schemaVersion: next.schemaVersion
    )
    let encoded = try JSONEncoder.addressAtlas.encode(envelope)

    let db = try openDatabase()
    defer { sqlite3_close(db) }
    let revision: Int
    if let expectedRevision {
      revision = expectedRevision
    } else {
      let current = try currentRevision(db)
      // Adopting an existing row's latest revision without first loading its
      // contents would make an unrelated whole-document value look current.
      // Allow direct saves only for a genuinely empty store.
      guard current == 0 else {
        throw EncryptedSQLiteVaultStoreError.staleDocument
      }
      revision = current
    }

    let sql = revision == 0
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

    let bindDataStatus = encoded.withUnsafeBytes { buffer in
      sqlite3_bind_blob(statement, 1, buffer.baseAddress, Int32(encoded.count), SQLITE_TRANSIENT)
    }
    guard bindDataStatus == SQLITE_OK else {
      throw EncryptedSQLiteVaultStoreError.bindFailed(errorMessage(db))
    }
    let timestamp = ISO8601DateFormatter().string(from: next.updatedAt)
    guard sqlite3_bind_text(statement, 2, timestamp, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
      throw EncryptedSQLiteVaultStoreError.bindFailed(errorMessage(db))
    }
    if revision > 0,
       sqlite3_bind_int64(statement, 3, Int64(revision)) != SQLITE_OK {
      throw EncryptedSQLiteVaultStoreError.bindFailed(errorMessage(db))
    }
    if revision > 0 {
      guard let expectedEnvelopeBytes else {
        throw EncryptedSQLiteVaultStoreError.staleDocument
      }
      let bindExpectedStatus = expectedEnvelopeBytes.withUnsafeBytes { buffer in
        sqlite3_bind_blob(statement, 4, buffer.baseAddress, Int32(expectedEnvelopeBytes.count), SQLITE_TRANSIENT)
      }
      guard bindExpectedStatus == SQLITE_OK else {
        throw EncryptedSQLiteVaultStoreError.bindFailed(errorMessage(db))
      }
    }
    let status = sqlite3_step(statement)
    if status == SQLITE_DONE {
      throw EncryptedSQLiteVaultStoreError.staleDocument
    }
    guard status == SQLITE_ROW else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(errorMessage(db))
    }
    let storedRevision = sqlite3_column_int64(statement, 0)
    guard storedRevision >= 1,
          storedRevision <= Int64(Int.max),
          sqlite3_step(statement) == SQLITE_DONE
    else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(errorMessage(db))
    }
    expectedRevision = Int(storedRevision)
    expectedEnvelopeBytes = encoded
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

  private func openDatabase() throws -> OpaquePointer {
    try secureDatabaseFile()
    var db: OpaquePointer?
    let status = sqlite3_open_v2(path.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
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
    guard sqlite3_prepare_v2(db, "PRAGMA table_info(encrypted_vault_documents);", -1, &statement, nil) == SQLITE_OK else {
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

  private func currentRevision(_ db: OpaquePointer) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
      db,
      "SELECT revision FROM encrypted_vault_documents WHERE id = 'primary' LIMIT 1;",
      -1,
      &statement,
      nil
    ) == SQLITE_OK else {
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

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
