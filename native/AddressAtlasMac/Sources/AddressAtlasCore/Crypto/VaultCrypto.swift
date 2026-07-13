import CryptoKit
import Foundation
import Security

public enum VaultCryptoError: Error, Equatable {
  case invalidBase64
  case invalidHex
  case invalidKeyLength
  case invalidEnvelope
  case authenticationFailed
}

public struct EncryptedVaultEnvelope: Codable, Equatable, Hashable, Sendable {
  public var schemaVersion: Int
  public var cryptoVersion: Int
  public var keyId: String
  public var nonce: String
  public var ciphertext: String
  public var checksum: String
  public var createdAt: Date

  public init(
    schemaVersion: Int = 1,
    cryptoVersion: Int = 1,
    keyId: String,
    nonce: String,
    ciphertext: String,
    checksum: String,
    createdAt: Date = Date()
  ) {
    self.schemaVersion = schemaVersion
    self.cryptoVersion = cryptoVersion
    self.keyId = keyId
    self.nonce = nonce
    self.ciphertext = ciphertext
    self.checksum = checksum
    self.createdAt = createdAt
  }
}

public enum VaultSubkey: String, CaseIterable, Sendable {
  case localDatabase = "local-db"
  case syncBlob = "sync-blob"
  case exchangeCredentials = "exchange-credentials"
}

public struct VaultCrypto: Sendable {
  public static let vaultKeyByteCount = 32
  public static let maximumEnvelopeBodyByteCount = 64_000_000
  private let salt = Data("address-atlas-v1".utf8)

  public init() {}

  public func generateVaultKey() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: Self.vaultKeyByteCount)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw VaultCryptoError.authenticationFailed
    }
    return Data(bytes)
  }

  public func deriveKey(from vaultKey: Data, purpose: VaultSubkey) throws -> SymmetricKey {
    guard vaultKey.count == Self.vaultKeyByteCount else {
      throw VaultCryptoError.invalidKeyLength
    }
    return HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: vaultKey),
      salt: salt,
      info: Data("address-atlas:\(purpose.rawValue)".utf8),
      outputByteCount: Self.vaultKeyByteCount
    )
  }

  public func seal(
    _ plaintext: Data,
    with key: SymmetricKey,
    keyId: String,
    schemaVersion: Int = 1,
    authenticatedData: Data? = nil
  ) throws -> EncryptedVaultEnvelope {
    try validateMetadata(schemaVersion: schemaVersion, keyId: keyId)
    let cryptoVersion = authenticatedData == nil ? 1 : 2
    let sealed = try AES.GCM.seal(
      plaintext,
      using: key,
      authenticating: authenticatedData ?? Data()
    )
    let nonce = sealed.nonce.dataRepresentation
    let body = sealed.ciphertext + sealed.tag
    let checksum = SHA256.hash(
      data: checksumInput(
        schemaVersion: schemaVersion,
        cryptoVersion: cryptoVersion,
        keyId: keyId,
        nonce: nonce,
        ciphertext: body
      )
    )
    return EncryptedVaultEnvelope(
      schemaVersion: schemaVersion,
      cryptoVersion: cryptoVersion,
      keyId: keyId,
      nonce: Base64URL.encode(nonce),
      ciphertext: Base64URL.encode(body),
      checksum: Data(checksum).hexString
    )
  }

  public func open(
    _ envelope: EncryptedVaultEnvelope,
    with key: SymmetricKey,
    authenticatedData: Data? = nil
  ) throws -> Data {
    guard envelope.cryptoVersion == 1 || envelope.cryptoVersion == 2 else {
      throw VaultCryptoError.invalidEnvelope
    }
    if envelope.cryptoVersion == 1, authenticatedData != nil {
      throw VaultCryptoError.invalidEnvelope
    }
    if envelope.cryptoVersion == 2, authenticatedData == nil {
      throw VaultCryptoError.invalidEnvelope
    }
    try validateMetadata(schemaVersion: envelope.schemaVersion, keyId: envelope.keyId)
    guard envelope.checksum.count == 64,
          envelope.checksum.unicodeScalars.allSatisfy({ scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
          })
    else {
      throw VaultCryptoError.invalidEnvelope
    }
    let nonceData = try Base64URL.decode(envelope.nonce)
    let body = try Base64URL.decode(envelope.ciphertext)
    guard nonceData.count == 12,
          body.count >= 16,
          body.count <= Self.maximumEnvelopeBodyByteCount
    else {
      throw VaultCryptoError.invalidEnvelope
    }
    let expected = SHA256.hash(
      data: checksumInput(
        schemaVersion: envelope.schemaVersion,
        cryptoVersion: envelope.cryptoVersion,
        keyId: envelope.keyId,
        nonce: nonceData,
        ciphertext: body
      )
    )
    guard Data(expected).hexString == envelope.checksum else {
      throw VaultCryptoError.authenticationFailed
    }
    let ciphertext = body.dropLast(16)
    let tag = body.suffix(16)
    do {
      let nonce = try AES.GCM.Nonce(data: nonceData)
      let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(ciphertext), tag: Data(tag))
      return try AES.GCM.open(box, using: key, authenticating: authenticatedData ?? Data())
    } catch {
      // Surface the same error as a checksum mismatch so the failure mode can't
      // be used to tell "wrong key" apart from "corrupt ciphertext" (uniform
      // decrypt failure, matching RecoveryKit.open).
      throw VaultCryptoError.authenticationFailed
    }
  }

  public func sealJSON<T: Encodable>(
    _ value: T,
    with key: SymmetricKey,
    keyId: String,
    schemaVersion: Int = 1,
    authenticatedData: Data? = nil,
    encoder: JSONEncoder = .addressAtlas
  ) throws -> EncryptedVaultEnvelope {
    try seal(
      encoder.encode(value),
      with: key,
      keyId: keyId,
      schemaVersion: schemaVersion,
      authenticatedData: authenticatedData
    )
  }

  public func openJSON<T: Decodable>(
    _ type: T.Type,
    envelope: EncryptedVaultEnvelope,
    with key: SymmetricKey,
    authenticatedData: Data? = nil,
    decoder: JSONDecoder = .addressAtlas
  ) throws -> T {
    try decoder.decode(type, from: open(envelope, with: key, authenticatedData: authenticatedData))
  }

  private func validateMetadata(schemaVersion: Int, keyId: String) throws {
    guard (1...VaultDocument.currentSchemaVersion).contains(schemaVersion),
          (3...80).contains(keyId.count),
          keyId.unicodeScalars.allSatisfy({ scalar in
            (65...90).contains(scalar.value)
              || (97...122).contains(scalar.value)
              || (48...57).contains(scalar.value)
              || scalar == "-"
              || scalar == "_"
              || scalar == "."
              || scalar == ":"
          })
    else {
      throw VaultCryptoError.invalidEnvelope
    }
  }

  private func checksumInput(schemaVersion: Int, cryptoVersion: Int, keyId: String, nonce: Data, ciphertext: Data) -> Data {
    var data = Data()
    data.append(Data("schema:\(schemaVersion)|crypto:\(cryptoVersion)|key:\(keyId)|".utf8))
    data.append(nonce)
    data.append(ciphertext)
    return data
  }
}

extension AES.GCM.Nonce {
  var dataRepresentation: Data {
    withUnsafeBytes { Data($0) }
  }
}

extension JSONEncoder {
  public static var addressAtlas: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  public static var addressAtlas: JSONDecoder {
    let decoder = JSONDecoder()
    // Foundation's built-in `.iso8601` strategy on macOS 14 rejects the
    // fractional seconds emitted by JavaScript's `Date.toISOString()`. Keep
    // accepting the second-precision dates produced by our encoder while also
    // accepting the server's RFC 3339 timestamps.
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let wholeSecondsFormatter = ISO8601DateFormatter()
    wholeSecondsFormatter.formatOptions = [.withInternetDateTime]
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      if let date = fractionalFormatter.date(from: value) ?? wholeSecondsFormatter.date(from: value) {
        return date
      }
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Expected an ISO 8601 date with optional fractional seconds."
      )
    }
    return decoder
  }
}
