import Foundation
import Security

public protocol VaultKeyStore: Sendable {
  func loadVaultKey() throws -> Data?
  func saveVaultKey(_ key: Data) throws
  func deleteVaultKey() throws
}

public enum KeychainVaultKeyStoreError: Error, Equatable {
  case unexpectedStatus(OSStatus)
  case invalidItem
}

public struct KeychainVaultKeyStore: VaultKeyStore {
  public let service: String
  public let account: String

  public init(service: String = "com.addressatlas.mac.vault", account: String = "primary-vault-key") {
    self.service = service
    self.account = account
  }

  public func loadVaultKey() throws -> Data? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw KeychainVaultKeyStoreError.unexpectedStatus(status)
    }
    guard let data = result as? Data else {
      throw KeychainVaultKeyStoreError.invalidItem
    }
    return data
  }

  public func saveVaultKey(_ key: Data) throws {
    try deleteVaultKey()
    var item = baseQuery()
    item[kSecValueData as String] = key
    // Design decision (2026-06-22, won't-fix): device-only, excluded from
    // iCloud/backups is the deliberate posture for a software vault key. A
    // biometric / kSecAttrAccessControl gate is intentionally NOT used because
    // it would block background scan/sync. Do not re-flag as "missing biometric".
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw KeychainVaultKeyStoreError.unexpectedStatus(status)
    }
  }

  public func deleteVaultKey() throws {
    let status = SecItemDelete(baseQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainVaultKeyStoreError.unexpectedStatus(status)
    }
  }

  private func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
  }
}

public actor VaultKeyManager {
  private let store: VaultKeyStore
  private let crypto: VaultCrypto

  public init(store: VaultKeyStore, crypto: VaultCrypto = VaultCrypto()) {
    self.store = store
    self.crypto = crypto
  }

  public func loadOrCreateVaultKey() throws -> Data {
    if let existing = try store.loadVaultKey() {
      guard existing.count == VaultCrypto.vaultKeyByteCount else {
        throw VaultCryptoError.invalidKeyLength
      }
      return existing
    }
    let generated = try crypto.generateVaultKey()
    try store.saveVaultKey(generated)
    return generated
  }
}
