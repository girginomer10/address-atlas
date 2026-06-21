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

  public func seal(_ plaintext: Data, with key: SymmetricKey, keyId: String, schemaVersion: Int = 1) throws -> EncryptedVaultEnvelope {
    let sealed = try AES.GCM.seal(plaintext, using: key)
    let nonce = sealed.nonce.dataRepresentation
    let body = sealed.ciphertext + sealed.tag
    let checksum = SHA256.hash(data: checksumInput(schemaVersion: schemaVersion, cryptoVersion: 1, keyId: keyId, nonce: nonce, ciphertext: body))
    return EncryptedVaultEnvelope(
      schemaVersion: schemaVersion,
      cryptoVersion: 1,
      keyId: keyId,
      nonce: Base64URL.encode(nonce),
      ciphertext: Base64URL.encode(body),
      checksum: Data(checksum).hexString
    )
  }

  public func open(_ envelope: EncryptedVaultEnvelope, with key: SymmetricKey) throws -> Data {
    guard envelope.cryptoVersion == 1 else {
      throw VaultCryptoError.invalidEnvelope
    }
    let nonceData = try Base64URL.decode(envelope.nonce)
    let body = try Base64URL.decode(envelope.ciphertext)
    guard nonceData.count == 12, body.count > 16 else {
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
      return try AES.GCM.open(box, using: key)
    } catch {
      // Surface the same error as a checksum mismatch so the failure mode can't
      // be used to tell "wrong key" apart from "corrupt ciphertext" (uniform
      // decrypt failure, matching RecoveryKit.open).
      throw VaultCryptoError.authenticationFailed
    }
  }

  public func sealJSON<T: Encodable>(_ value: T, with key: SymmetricKey, keyId: String, encoder: JSONEncoder = .addressAtlas) throws -> EncryptedVaultEnvelope {
    try seal(encoder.encode(value), with: key, keyId: keyId)
  }

  public func openJSON<T: Decodable>(_ type: T.Type, envelope: EncryptedVaultEnvelope, with key: SymmetricKey, decoder: JSONDecoder = .addressAtlas) throws -> T {
    try decoder.decode(type, from: open(envelope, with: key))
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
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
