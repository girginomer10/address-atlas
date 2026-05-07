import CryptoKit
import Foundation
import SQLite3

public enum EncryptedSQLiteVaultStoreError: Error, Equatable {
  case openFailed(String)
  case prepareFailed(String)
  case stepFailed(String)
  case bindFailed(String)
  case missingDocument
  case invalidRow
}

public final class EncryptedSQLiteVaultStore: @unchecked Sendable {
  private let path: URL
  private let crypto: VaultCrypto
  private let key: SymmetricKey

  public init(path: URL, vaultKey: Data, crypto: VaultCrypto = VaultCrypto()) throws {
    self.path = path
    self.crypto = crypto
    self.key = try crypto.deriveKey(from: vaultKey, purpose: .localDatabase)
  }

  public func initialize() throws {
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let db = try openDatabase()
    defer { sqlite3_close(db) }
    try exec(
      """
      CREATE TABLE IF NOT EXISTS encrypted_vault_documents (
        id TEXT PRIMARY KEY NOT NULL,
        envelope_json BLOB NOT NULL,
        updated_at TEXT NOT NULL
      );
      """,
      db: db
    )
  }

  public func load() throws -> VaultDocument {
    try initialize()
    let db = try openDatabase()
    defer { sqlite3_close(db) }

    let sql = "SELECT envelope_json FROM encrypted_vault_documents WHERE id = 'primary' LIMIT 1;"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw EncryptedSQLiteVaultStoreError.prepareFailed(errorMessage(db))
    }
    defer { sqlite3_finalize(statement) }

    let status = sqlite3_step(statement)
    if status == SQLITE_DONE {
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
    return try crypto.openJSON(VaultDocument.self, envelope: envelope, with: key)
  }

  public func save(_ document: VaultDocument) throws {
    try initialize()
    var next = document
    next.updatedAt = Date()
    let envelope = try crypto.sealJSON(next, with: key, keyId: "local-db")
    let encoded = try JSONEncoder.addressAtlas.encode(envelope)

    let db = try openDatabase()
    defer { sqlite3_close(db) }

    let sql = """
    INSERT INTO encrypted_vault_documents (id, envelope_json, updated_at)
    VALUES ('primary', ?, ?)
    ON CONFLICT(id) DO UPDATE SET envelope_json = excluded.envelope_json, updated_at = excluded.updated_at;
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
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(errorMessage(db))
    }
  }

  public func rawStoredEnvelopeBytes() throws -> Data? {
    try initialize()
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
    var db: OpaquePointer?
    let status = sqlite3_open_v2(path.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    guard status == SQLITE_OK, let db else {
      throw EncryptedSQLiteVaultStoreError.openFailed(db.map(errorMessage) ?? "unknown")
    }
    return db
  }

  private func exec(_ sql: String, db: OpaquePointer) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(errorMessage(db))
    }
  }

  private func errorMessage(_ db: OpaquePointer) -> String {
    String(cString: sqlite3_errmsg(db))
  }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
