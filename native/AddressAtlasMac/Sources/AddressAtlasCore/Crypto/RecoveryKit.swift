import CryptoKit
import Foundation
import Security

public enum RecoveryKitError: Error, Equatable, LocalizedError {
  case invalidCode
  case invalidDocument
  case checksumMismatch
  case invalidVaultKey

  public var errorDescription: String? {
    switch self {
    case .invalidCode:
      "Recovery code is invalid."
    case .invalidDocument:
      "Recovery file is invalid."
    case .checksumMismatch:
      "Recovery file checksum does not match."
    case .invalidVaultKey:
      "Recovery file did not contain a valid vault key."
    }
  }
}

public struct RecoveryKitDocument: Codable, Equatable, Sendable {
  public var version: Int
  public var salt: String
  public var nonce: String
  public var wrappedVaultKey: String
  public var checksum: String
  public var createdAt: Date

  public init(
    version: Int = 1,
    salt: String,
    nonce: String,
    wrappedVaultKey: String,
    checksum: String,
    createdAt: Date = Date()
  ) {
    self.version = version
    self.salt = salt
    self.nonce = nonce
    self.wrappedVaultKey = wrappedVaultKey
    self.checksum = checksum
    self.createdAt = createdAt
  }
}

public struct RecoveryKitExport: Equatable, Sendable {
  public var document: RecoveryKitDocument
  public var recoveryCode: String
}

public struct RecoveryKitCodec: Sendable {
  public init() {}

  public func create(vaultKey: Data) throws -> RecoveryKitExport {
    guard vaultKey.count == VaultCrypto.vaultKeyByteCount else {
      throw RecoveryKitError.invalidVaultKey
    }
    let codeBytes = try randomBytes(count: 32)
    let salt = try randomBytes(count: 32)
    let recoveryCode = Self.formatRecoveryCode(codeBytes.hexString.uppercased())
    let wrappingKey = try deriveWrappingKey(codeBytes: codeBytes, salt: salt)
    let sealed = try AES.GCM.seal(vaultKey, using: wrappingKey)
    let nonce = sealed.nonce.dataRepresentation
    let wrapped = sealed.ciphertext + sealed.tag
    let checksum = Self.checksum(version: 1, salt: salt, nonce: nonce, wrappedVaultKey: wrapped)
    return RecoveryKitExport(
      document: RecoveryKitDocument(
        salt: Base64URL.encode(salt),
        nonce: Base64URL.encode(nonce),
        wrappedVaultKey: Base64URL.encode(wrapped),
        checksum: checksum
      ),
      recoveryCode: recoveryCode
    )
  }

  public func open(_ document: RecoveryKitDocument, recoveryCode: String) throws -> Data {
    guard document.version == 1 else { throw RecoveryKitError.invalidDocument }
    let salt = try Base64URL.decode(document.salt)
    let nonce = try Base64URL.decode(document.nonce)
    let wrapped = try Base64URL.decode(document.wrappedVaultKey)
    guard nonce.count == 12, wrapped.count > 16 else { throw RecoveryKitError.invalidDocument }
    guard Self.checksum(version: document.version, salt: salt, nonce: nonce, wrappedVaultKey: wrapped) == document.checksum else {
      throw RecoveryKitError.checksumMismatch
    }
    let codeBytes = try Self.recoveryCodeBytes(recoveryCode)
    let key = try deriveWrappingKey(codeBytes: codeBytes, salt: salt)
    let box = try AES.GCM.SealedBox(
      nonce: try AES.GCM.Nonce(data: nonce),
      ciphertext: Data(wrapped.dropLast(16)),
      tag: Data(wrapped.suffix(16))
    )
    let vaultKey: Data
    do {
      vaultKey = try AES.GCM.open(box, using: key)
    } catch {
      throw RecoveryKitError.invalidCode
    }
    guard vaultKey.count == VaultCrypto.vaultKeyByteCount else {
      throw RecoveryKitError.invalidVaultKey
    }
    return vaultKey
  }

  public static func recoveryCodeBytes(_ recoveryCode: String) throws -> Data {
    let compact = recoveryCode.filter(\.isHexDigit)
    guard compact.count == 64 else { throw RecoveryKitError.invalidCode }
    do {
      return try Data(hex: compact)
    } catch {
      throw RecoveryKitError.invalidCode
    }
  }

  public static func formatRecoveryCode(_ hex: String) -> String {
    let compact = hex.filter(\.isHexDigit).uppercased()
    var groups: [String] = []
    var index = compact.startIndex
    while index < compact.endIndex {
      let next = compact.index(index, offsetBy: 4, limitedBy: compact.endIndex) ?? compact.endIndex
      groups.append(String(compact[index..<next]))
      index = next
    }
    return groups.joined(separator: "-")
  }

  private func deriveWrappingKey(codeBytes: Data, salt: Data) throws -> SymmetricKey {
    guard codeBytes.count == 32, salt.count == 32 else {
      throw RecoveryKitError.invalidCode
    }
    return HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: codeBytes),
      salt: salt,
      info: Data("address-atlas:recovery-kit:v1".utf8),
      outputByteCount: VaultCrypto.vaultKeyByteCount
    )
  }

  private func randomBytes(count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw VaultCryptoError.authenticationFailed
    }
    return Data(bytes)
  }

  private static func checksum(version: Int, salt: Data, nonce: Data, wrappedVaultKey: Data) -> String {
    var data = Data("recovery-kit:\(version)|".utf8)
    data.append(salt)
    data.append(nonce)
    data.append(wrappedVaultKey)
    return Data(SHA256.hash(data: data)).hexString
  }
}
