import Foundation
import Security

public protocol VaultKeyStore: Sendable {
  func loadVaultKey() throws -> Data?
  func saveVaultKey(_ key: Data) throws
  /// Atomically install a first-run key or return the key another process won
  /// the race to install. Unlike `saveVaultKey`, this must not replace a key.
  func saveVaultKeyIfAbsent(_ key: Data) throws -> Data
  func deleteVaultKey() throws
}

public enum KeychainVaultKeyStoreError: Error, Equatable {
  case unexpectedStatus(OSStatus)
  case invalidItem
}

public struct KeychainVaultKeyStore: VaultKeyStore {
  public let service: String
  public let account: String
  let usesDataProtectionKeychain: Bool

  public init(
    service: String = "com.addressatlas.mac.vault",
    account: String = "primary-vault-key",
    usesDataProtectionKeychain: Bool? = nil
  ) {
    self.service = service
    self.account = account
    self.usesDataProtectionKeychain = usesDataProtectionKeychain
      ?? (Bundle.main.infoDictionary?["AddressAtlasUseDataProtectionKeychain"] as? Bool == true)
  }

  public func loadVaultKey() throws -> Data? {
    guard usesDataProtectionKeychain else {
      return try loadItem(query: baseQuery(useDataProtectionKeychain: false))
    }
    if let protected = try loadItem(query: baseQuery(useDataProtectionKeychain: true)) {
      return protected
    }

    // Builds before 0.2.0 requested a ThisDeviceOnly accessibility class but
    // omitted kSecUseDataProtectionKeychain on macOS. The legacy file-keychain
    // silently ignored that accessibility class. Migrate the value before use,
    // verify the protected winner, then remove the stale legacy copy.
    guard let legacy = try loadItem(query: baseQuery(useDataProtectionKeychain: false)) else {
      return nil
    }
    guard legacy.count == VaultCrypto.vaultKeyByteCount else {
      throw KeychainVaultKeyStoreError.invalidItem
    }
    let protected = try installActiveItemIfAbsent(legacy)
    guard protected == legacy else {
      throw KeychainVaultKeyStoreError.invalidItem
    }
    try deleteLegacyItem()
    return protected
  }

  public func saveVaultKey(_ key: Data) throws {
    guard key.count == VaultCrypto.vaultKeyByteCount else {
      throw KeychainVaultKeyStoreError.invalidItem
    }
    // Mac App Store builds select Data Protection Keychain so device-only,
    // excluded-from-backup accessibility is enforced. The direct channel keeps
    // the legacy backend only for compatibility with existing unsigned builds.
    // A biometric / kSecAttrAccessControl gate is intentionally not used because
    // it would block background scan/sync while the login session is unlocked.
    // Update in place first. Deleting the old item before SecItemAdd creates a
    // destructive window where a transient Keychain error loses the only key.
    let attributes: [String: Any] = [
      kSecValueData as String: key,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let activeQuery = baseQuery(useDataProtectionKeychain: usesDataProtectionKeychain)
    let updateStatus = SecItemUpdate(activeQuery as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess {
      if usesDataProtectionKeychain { try deleteLegacyItem() }
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainVaultKeyStoreError.unexpectedStatus(updateStatus)
    }

    var item = activeQuery
    for (key, value) in attributes {
      item[key] = value
    }
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    if addStatus == errSecDuplicateItem {
      // Another process may have inserted the item between update and add.
      let retryStatus = SecItemUpdate(activeQuery as CFDictionary, attributes as CFDictionary)
      guard retryStatus == errSecSuccess else {
        throw KeychainVaultKeyStoreError.unexpectedStatus(retryStatus)
      }
      if usesDataProtectionKeychain { try deleteLegacyItem() }
      return
    }
    guard addStatus == errSecSuccess else {
      throw KeychainVaultKeyStoreError.unexpectedStatus(addStatus)
    }
    if usesDataProtectionKeychain { try deleteLegacyItem() }
  }

  public func saveVaultKeyIfAbsent(_ key: Data) throws -> Data {
    guard key.count == VaultCrypto.vaultKeyByteCount else {
      throw KeychainVaultKeyStoreError.invalidItem
    }
    if let existing = try loadVaultKey() {
      return existing
    }
    return try installActiveItemIfAbsent(key)
  }

  public func deleteVaultKey() throws {
    var firstFailure: OSStatus?
    let queries = usesDataProtectionKeychain
      ? [
        baseQuery(useDataProtectionKeychain: true),
        baseQuery(useDataProtectionKeychain: false),
      ]
      : [baseQuery(useDataProtectionKeychain: false)]
    for query in queries {
      let status = SecItemDelete(query as CFDictionary)
      if status != errSecSuccess, status != errSecItemNotFound, firstFailure == nil {
        firstFailure = status
      }
    }
    if let firstFailure {
      throw KeychainVaultKeyStoreError.unexpectedStatus(firstFailure)
    }
  }

  private func installActiveItemIfAbsent(_ key: Data) throws -> Data {
    var item = baseQuery(useDataProtectionKeychain: usesDataProtectionKeychain)
    item[kSecValueData as String] = key
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    let status = SecItemAdd(item as CFDictionary, nil)
    if status == errSecSuccess {
      return key
    }
    guard status == errSecDuplicateItem else {
      throw KeychainVaultKeyStoreError.unexpectedStatus(status)
    }
    guard
      let winner = try loadItem(
        query: baseQuery(useDataProtectionKeychain: usesDataProtectionKeychain)
      )
    else {
      // The item was removed between duplicate detection and retrieval.
      throw KeychainVaultKeyStoreError.unexpectedStatus(errSecItemNotFound)
    }
    return winner
  }

  private func loadItem(query base: [String: Any]) throws -> Data? {
    var query = base
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

  private func deleteLegacyItem() throws {
    let status = SecItemDelete(baseQuery(useDataProtectionKeychain: false) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainVaultKeyStoreError.unexpectedStatus(status)
    }
  }

  private func baseQuery(useDataProtectionKeychain: Bool) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if useDataProtectionKeychain {
      query[kSecUseDataProtectionKeychain as String] = true
    }
    return query
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
    let installed = try store.saveVaultKeyIfAbsent(generated)
    guard installed.count == VaultCrypto.vaultKeyByteCount else {
      throw VaultCryptoError.invalidKeyLength
    }
    return installed
  }
}
