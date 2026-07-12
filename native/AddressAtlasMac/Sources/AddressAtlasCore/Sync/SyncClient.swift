import CryptoKit
import Foundation

public struct RemoteVaultSnapshot: Codable, Equatable, Sendable {
  public var version: Int
  public var envelope: EncryptedVaultEnvelope
  public var byteSize: Int
  public var checksum: String
  public var updatedAt: Date

  public init(version: Int, envelope: EncryptedVaultEnvelope, byteSize: Int, checksum: String, updatedAt: Date = Date()) {
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

public struct VaultSyncCodec: Sendable {
  public static let maximumSnapshotByteCount = 8_000_000
  private static let maximumVersion = 2_000_000_000
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
    let key = try crypto.deriveKey(from: vaultKey, purpose: .syncBlob)
    var remoteDocument = document
    remoteDocument.schemaVersion = VaultDocument.currentSchemaVersion
    remoteDocument.syncState.accountId = accountId
    // A bearer token grants server access but provides no value inside the
    // encrypted backup. Never preserve a live token in historical snapshots.
    remoteDocument.syncState.sessionToken = ""
    remoteDocument.syncState.serverURL = ""
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
    guard !encoded.isEmpty, encoded.count <= Self.maximumSnapshotByteCount else {
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

  public func open(
    snapshot: RemoteVaultSnapshot,
    vaultKey: Data,
    expectedAccountId: String
  ) throws -> OpenedVaultSnapshot {
    let accountId = try validatedAccountId(expectedAccountId)
    try validateSnapshot(snapshot)
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
      guard document.syncState.accountId == accountId else {
        throw VaultSyncCodecError.accountMismatch
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

  private func validateSnapshot(_ snapshot: RemoteVaultSnapshot) throws {
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

  private func validatedAccountId(_ accountId: String) throws -> String {
    let trimmed = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 200 else {
      throw VaultSyncCodecError.invalidAccount
    }
    return trimmed
  }

  private func validateVersion(_ version: Int) throws {
    guard (1...Self.maximumVersion).contains(version) else {
      throw VaultSyncCodecError.invalidVersion
    }
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

public struct PasskeyOptionsResponse: Codable, Sendable {
  public var mode: String
  public var challengeToken: String
  public var publicKey: [String: AnyCodable]

  public init(mode: String, challengeToken: String, publicKey: [String: AnyCodable]) {
    self.mode = mode
    self.challengeToken = challengeToken
    self.publicKey = publicKey
  }
}

public struct AnyCodable: Codable, Equatable, Sendable {
  public var value: SendableValue

  public init(_ value: SendableValue) {
    self.value = value
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      value = .null
    } else if let bool = try? container.decode(Bool.self) {
      value = .bool(bool)
    } else if let number = try? container.decode(Double.self) {
      value = .number(number)
    } else if let string = try? container.decode(String.self) {
      value = .string(string)
    } else if let array = try? container.decode([AnyCodable].self) {
      value = .array(array.map(\.value))
    } else {
      let object = try container.decode([String: AnyCodable].self)
      value = .object(object.mapValues(\.value))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch value {
    case .null:
      try container.encodeNil()
    case .bool(let bool):
      try container.encode(bool)
    case .number(let number):
      try container.encode(number)
    case .string(let string):
      try container.encode(string)
    case .array(let values):
      try container.encode(values.map(AnyCodable.init))
    case .object(let values):
      try container.encode(values.mapValues(AnyCodable.init))
    }
  }
}

public enum SendableValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([SendableValue])
  case object([String: SendableValue])
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
  private static let maximumWireSnapshotByteCount = VaultSyncCodec.maximumSnapshotByteCount + 100_000
  private let baseURL: URL
  private let http: HTTPClient
  private var bearerToken: String?

  public init(baseURL: URL, http: HTTPClient = URLSession.shared) {
    self.baseURL = baseURL
    self.http = http
  }

  public func setBearerToken(_ token: String?) {
    bearerToken = token
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

  private static func error(statusCode: Int, data: Data) -> SyncClientError {
    let message = (try? JSONDecoder.addressAtlas.decode(ServerError.self, from: data).error)
      ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
    if statusCode == 401 {
      return .authenticationRequired(message)
    }
    return .requestFailed(statusCode, message)
  }
}

private struct ServerError: Decodable {
  var error: String
}
