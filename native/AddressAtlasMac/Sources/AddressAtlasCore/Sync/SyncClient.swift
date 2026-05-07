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

public struct VaultSyncCodec: Sendable {
  private let crypto: VaultCrypto

  public init(crypto: VaultCrypto = VaultCrypto()) {
    self.crypto = crypto
  }

  public func seal(document: VaultDocument, vaultKey: Data, version: Int) throws -> RemoteVaultSnapshot {
    let key = try crypto.deriveKey(from: vaultKey, purpose: .syncBlob)
    let envelope = try crypto.sealJSON(document, with: key, keyId: "sync-v1")
    let encoded = try JSONEncoder.addressAtlas.encode(envelope)
    let checksum = SHA256.hash(data: encoded)
    return RemoteVaultSnapshot(
      version: version,
      envelope: envelope,
      byteSize: encoded.count,
      checksum: Data(checksum).hexString
    )
  }

  public func open(snapshot: RemoteVaultSnapshot, vaultKey: Data) throws -> VaultDocument {
    let encoded = try JSONEncoder.addressAtlas.encode(snapshot.envelope)
    let checksum = SHA256.hash(data: encoded)
    guard Data(checksum).hexString == snapshot.checksum, encoded.count == snapshot.byteSize else {
      throw VaultCryptoError.authenticationFailed
    }
    let key = try crypto.deriveKey(from: vaultKey, purpose: .syncBlob)
    return try crypto.openJSON(VaultDocument.self, envelope: snapshot.envelope, with: key)
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

public actor ZeroKnowledgeSyncClient {
  private let baseURL: URL
  private let http: JSONHTTPClient
  private var bearerToken: String?

  public init(baseURL: URL, http: JSONHTTPClient = JSONHTTPClient()) {
    self.baseURL = baseURL
    self.http = http
  }

  public func setBearerToken(_ token: String?) {
    bearerToken = token
  }

  public func latestVault() async throws -> RemoteVaultSnapshot? {
    var request = URLRequest(url: baseURL.appending(path: "vault/latest"))
    request.setValue("application/json", forHTTPHeaderField: "accept")
    if let bearerToken {
      request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "authorization")
    }
    let client = URLSession.shared
    let (data, response) = try await client.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    if http.statusCode == 404 {
      return nil
    }
    guard (200..<300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return try JSONDecoder.addressAtlas.decode(RemoteVaultSnapshot.self, from: data)
  }

  public func upload(snapshot: RemoteVaultSnapshot) async throws {
    var request = URLRequest(url: baseURL.appending(path: "vault/latest"))
    request.httpMethod = "PUT"
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    if let bearerToken {
      request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "authorization")
    }
    request.httpBody = try JSONEncoder.addressAtlas.encode(snapshot)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    _ = data
  }
}
