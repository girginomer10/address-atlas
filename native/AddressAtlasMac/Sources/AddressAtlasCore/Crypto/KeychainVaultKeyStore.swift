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
    guard key.count == VaultCrypto.vaultKeyByteCount else {
      throw KeychainVaultKeyStoreError.invalidItem
    }
    // Design decision (2026-06-22, won't-fix): device-only, excluded from
    // iCloud/backups is the deliberate posture for a software vault key. A
    // biometric / kSecAttrAccessControl gate is intentionally NOT used because
    // it would block background scan/sync. Do not re-flag as "missing biometric".
    // Update in place first. Deleting the old item before SecItemAdd creates a
    // destructive window where a transient Keychain error loses the only key.
    let attributes: [String: Any] = [
      kSecValueData as String: key,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ]
    let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainVaultKeyStoreError.unexpectedStatus(updateStatus)
    }

    var item = baseQuery()
    attributes.forEach { item[$0.key] = $0.value }
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    if addStatus == errSecDuplicateItem {
      // Another process may have inserted the item between update and add.
      let retryStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
      guard retryStatus == errSecSuccess else {
        throw KeychainVaultKeyStoreError.unexpectedStatus(retryStatus)
      }
      return
    }
    guard addStatus == errSecSuccess else {
      throw KeychainVaultKeyStoreError.unexpectedStatus(addStatus)
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

public enum VaultKeyManagerError: Error, Equatable, LocalizedError {
  case recoveryRequired

  public var errorDescription: String? {
    switch self {
    case .recoveryRequired:
      "The existing vault key is missing. Restore a recovery kit to unlock this vault."
    }
  }
}

public actor VaultKeyManager {
  private let store: VaultKeyStore
  private let crypto: VaultCrypto

  public init(store: VaultKeyStore, crypto: VaultCrypto = VaultCrypto()) {
    self.store = store
    self.crypto = crypto
  }

  /// Load the existing key or create one only when there is no vault on disk.
  /// This prevents a missing Keychain item from being silently replaced with
  /// an unrelated key that can never decrypt an existing database.
  public func loadOrCreateVaultKey(existingVaultAt vaultURL: URL) throws -> Data {
    if let existing = try store.loadVaultKey() {
      guard existing.count == VaultCrypto.vaultKeyByteCount else {
        throw VaultCryptoError.invalidKeyLength
      }
      return existing
    }
    if FileManager.default.fileExists(atPath: vaultURL.path) {
      throw VaultKeyManagerError.recoveryRequired
    }
    let generated = try crypto.generateVaultKey()
    try store.saveVaultKey(generated)
    return generated
  }
}
