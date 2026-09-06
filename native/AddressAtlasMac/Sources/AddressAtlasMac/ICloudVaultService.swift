import AddressAtlasCore
@preconcurrency import CloudKit
import CryptoKit
import Foundation
import Security

enum ICloudVaultError: LocalizedError {
  case unavailable, accountChanged, conflict, missing, missingKey, malformed, keychain
  var errorDescription: String? {
    switch self {
    case .unavailable: "iCloud is unavailable. Use a signed iCloud-enabled build and sign in to iCloud in System Settings."
    case .accountChanged: "The iCloud account changed. No local data was replaced. Use the original Apple Account or explicitly start a new iCloud copy."
    case .conflict: "The iCloud copy changed on another Mac. Restore it before saving again. Export local changes first if you need to keep both versions."
    case .missing: "No Address Atlas copy was found in this iCloud account."
    case .missingKey: "The encryption key has not arrived through iCloud Keychain. Enable Passwords & Keychain on both Macs and try again. The existing iCloud copy will not be overwritten."
    case .malformed: "The iCloud copy could not be verified. Your local vault has not been replaced."
    case .keychain: "iCloud Keychain could not safely save or read the encryption key. Try again after unlocking this Mac."
    }
  }
}

/// Created lazily only for an explicit user action; unsigned local builds must
/// never initialize CloudKit, which can terminate a process lacking entitlements.
protocol ICloudVaultSyncing: Sendable {
  func save(_ document: VaultDocument, localKey: Data) async throws -> ICloudVaultState
  func restore(localKey: Data, expectedAccount: String?) async throws -> VaultDocument
  func delete(expectedAccount: String?) async throws
}

actor ICloudVaultService: ICloudVaultSyncing {
  static let containerIdentifier = "iCloud.com.addressatlas.mac"
  private let container: CKContainer
  private let recordID = CKRecord.ID(recordName: "primary-vault-v1")

  init() { container = CKContainer(identifier: Self.containerIdentifier) }

  static var isConfigured: Bool {
    guard let task = SecTaskCreateFromSelf(nil),
      let containers = SecTaskCopyValueForEntitlement(task,
        "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String]
    else { return false }
    return containers.contains(containerIdentifier)
  }

  func save(_ document: VaultDocument, localKey: Data) async throws -> ICloudVaultState {
    let account = try await accountIdentifier()
    if let baseline = document.iCloudState, baseline.account != account {
      throw ICloudVaultError.accountChanged
    }
    let existing = try await fetch()
    if let existing {
      guard let baseline = document.iCloudState,
        baseline.revision == existing["revision"] as? String else {
        throw ICloudVaultError.conflict
      }
    } else if document.iCloudState != nil {
      // A deleted cloud copy is not silently resurrected by a stale device.
      throw ICloudVaultError.missing
    }
    let keyID = try existing.map { try metadata($0).keyID } ?? UUID().uuidString
    let key = try cloudKey(account: account, keyID: keyID, create: existing == nil)
    let revision = UUID().uuidString
    let data = try ICloudVaultCodec().seal(document, localKey: localKey,
      cloudKey: key, account: account, revision: revision)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("vault.encrypted")
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let record = existing ?? CKRecord(recordType: "EncryptedVault", recordID: recordID)
    record["revision"] = revision as CKRecordValue
    record["keyID"] = keyID as CKRecordValue
    record["payload"] = CKAsset(fileURL: file)
    guard try await accountIdentifier() == account else { throw ICloudVaultError.accountChanged }
    let result = try await container.privateCloudDatabase.modifyRecords(
      saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
    guard let saved = result.saveResults[recordID] else { throw ICloudVaultError.malformed }
    do { _ = try saved.get() }
    catch let error as CKError where error.code == .serverRecordChanged {
      throw ICloudVaultError.conflict
    }
    guard try await accountIdentifier() == account else { throw ICloudVaultError.accountChanged }
    return ICloudVaultState(account: account, revision: revision)
  }

  func restore(localKey: Data, expectedAccount: String?) async throws -> VaultDocument {
    let account = try await accountIdentifier()
    if let expectedAccount, expectedAccount != account { throw ICloudVaultError.accountChanged }
    guard let record = try await fetch() else { throw ICloudVaultError.missing }
    let meta = try metadata(record)
    guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL else {
      throw ICloudVaultError.malformed
    }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
    guard size <= ICloudVaultCodec.maximumAssetBytes else { throw ICloudVaultError.malformed }
    let key = try cloudKey(account: account, keyID: meta.keyID, create: false)
    let document = try ICloudVaultCodec().open(Data(contentsOf: url), localKey: localKey,
      cloudKey: key, account: account, revision: meta.revision)
    guard try await accountIdentifier() == account else { throw ICloudVaultError.accountChanged }
    return document
  }

  func delete(expectedAccount: String?) async throws {
    let account = try await accountIdentifier()
    if let expectedAccount, expectedAccount != account { throw ICloudVaultError.accountChanged }
    // Delete only this app's private snapshot, never other iCloud records.
    do { _ = try await container.privateCloudDatabase.deleteRecord(withID: recordID) }
    catch let error as CKError where error.code == .unknownItem { }
    guard try await accountIdentifier() == account else { throw ICloudVaultError.accountChanged }
    // Retain the small Keychain item so in-flight restores can still decrypt.
  }

  private func accountIdentifier() async throws -> String {
    guard try await container.accountStatus() == .available else { throw ICloudVaultError.unavailable }
    let id = try await container.userRecordID().recordName
    return SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func fetch() async throws -> CKRecord? {
    do { return try await container.privateCloudDatabase.record(for: recordID) }
    catch let error as CKError where error.code == .unknownItem { return nil }
  }

  private func metadata(_ record: CKRecord) throws -> (keyID: String, revision: String) {
    guard let keyID = record["keyID"] as? String, UUID(uuidString: keyID) != nil,
      let revision = record["revision"] as? String, UUID(uuidString: revision) != nil else {
      throw ICloudVaultError.malformed
    }
    return (keyID, revision)
  }

  private func cloudKey(account: String, keyID: String, create: Bool) throws -> Data {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.addressatlas.mac.icloud-v1",
      kSecAttrAccount as String: "\(account)/\(keyID)",
      kSecAttrSynchronizable as String: true,
      kSecUseDataProtectionKeychain as String: true,
    ]
    var read = query
    read[kSecReturnData as String] = true
    read[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(read as CFDictionary, &result)
    if status == errSecSuccess {
      guard let key = result as? Data, key.count == 32 else { throw ICloudVaultError.keychain }
      return key
    }
    guard status == errSecItemNotFound else { throw ICloudVaultError.keychain }
    guard create else { throw ICloudVaultError.missingKey }
    let key = try VaultCrypto().generateVaultKey()
    var item = query
    item[kSecValueData as String] = key
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    let added = SecItemAdd(item as CFDictionary, nil)
    guard added == errSecSuccess || added == errSecDuplicateItem else {
      throw ICloudVaultError.keychain
    }
    // Re-read the winner; never overwrite an existing synchronizable key.
    return try cloudKey(account: account, keyID: keyID, create: false)
  }
}
