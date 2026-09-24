import AddressAtlasCore
@preconcurrency import CloudKit
import CryptoKit
import Foundation
import Security

enum ICloudVaultError: LocalizedError {
  case unavailable, accountChanged, conflict, missing, missingKey, malformed, keychain
  var errorDescription: String? {
    switch self {
    case .unavailable: "iCloud is unavailable. Use a signed iCloud-enabled build and sign in to iCloud in \(PlatformCopy.iCloudSettingsLocation)."
    case .accountChanged: "The iCloud account changed. No local data was replaced. Use the original Apple Account or explicitly start a new iCloud copy."
    case .conflict: "The iCloud copy changed on another \(PlatformCopy.deviceNoun). Restore it before saving again. Export local changes first if you need to keep both versions."
    case .missing: "No Address Atlas copy was found in this iCloud account."
    case .missingKey: "The encryption key has not arrived through iCloud Keychain. Enable Passwords & Keychain on both \(PlatformCopy.deviceNounPlural) and try again. The existing iCloud copy will not be overwritten."
    case .malformed: "The iCloud copy could not be verified. Your local vault has not been replaced."
    case .keychain: "iCloud Keychain could not safely save or read the encryption key. Try again after unlocking this \(PlatformCopy.deviceNoun)."
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

  #if os(macOS)
    static var isConfigured: Bool {
      guard let task = SecTaskCreateFromSelf(nil),
        let containers = SecTaskCopyValueForEntitlement(task,
          "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String]
      else { return false }
      return containers.contains(containerIdentifier)
    }
  #else
    /// The iOS SDK has no SecTask API, so the running build's entitlements are
    /// read from the executable itself (simulator builds embed them in a
    /// `__TEXT,__entitlements` section) or from the embedded provisioning
    /// profile (device, TestFlight, and App Store builds). Anything else fails
    /// closed so CloudKit is never initialized without the container grant.
    static var isConfigured: Bool {
      EmbeddedEntitlements.iCloudContainerIdentifiers().contains(containerIdentifier)
    }
  #endif

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

#if !os(macOS)
  import MachO

  /// Reads the running iOS build's code-signing entitlements without SecTask.
  /// Only the two sources Xcode actually produces are consulted; a missing or
  /// unparseable source yields an empty result so callers fail closed.
  enum EmbeddedEntitlements {
    static let iCloudContainersKey = "com.apple.developer.icloud-container-identifiers"

    static func iCloudContainerIdentifiers() -> [String] {
      if let entitlements = executableEntitlements() {
        return entitlements[iCloudContainersKey] as? [String] ?? []
      }
      if let entitlements = provisioningProfileEntitlements() {
        return entitlements[iCloudContainersKey] as? [String] ?? []
      }
      return []
    }

    /// Simulator builds carry the signed entitlements plist in a
    /// `__TEXT,__entitlements` section of the main executable. The executable's
    /// Mach-O header is located through `dladdr` on a symbol that lives in this
    /// binary, which avoids comparing dyld image paths against Foundation paths
    /// (they differ by a `/private` prefix on devices).
    static func executableEntitlements() -> [String: Any]? {
      guard let header = mainExecutableHeader() else { return nil }
      var size: UInt = 0
      let plist = header.withMemoryRebound(to: mach_header_64.self, capacity: 1) {
        header64 -> Data? in
        guard
          let pointer = getsectiondata(header64, "__TEXT", "__entitlements", &size),
          size > 0
        else { return nil }
        return Data(bytes: pointer, count: Int(size))
      }
      guard let plist else { return nil }
      return parsePlist(plist)
    }

    /// Never read or written; only its address matters.
    nonisolated(unsafe) private static var imageAnchor: UInt8 = 0

    private static func mainExecutableHeader() -> UnsafePointer<mach_header>? {
      var info = Dl_info()
      let found = withUnsafePointer(to: &imageAnchor) { anchor in
        dladdr(UnsafeRawPointer(anchor), &info) != 0
      }
      guard found, let base = info.dli_fbase else {
        // Fall back to dyld's image list, where the main executable is image 0.
        return _dyld_get_image_header(0)
      }
      return UnsafeRawPointer(base).assumingMemoryBound(to: mach_header.self)
    }

    /// Device, TestFlight, and App Store builds embed the provisioning profile
    /// (a CMS envelope around an XML plist) whose `Entitlements` dictionary
    /// mirrors the signed entitlements.
    static func provisioningProfileEntitlements() -> [String: Any]? {
      guard
        let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
        let raw = try? Data(contentsOf: url),
        let plist = extractPlist(from: raw)
      else { return nil }
      return plist["Entitlements"] as? [String: Any]
    }

    static func extractPlist(from raw: Data) -> [String: Any]? {
      let opening = Data("<?xml".utf8)
      let closing = Data("</plist>".utf8)
      guard let start = raw.range(of: opening),
        let end = raw.range(of: closing, in: start.lowerBound..<raw.endIndex)
      else { return nil }
      return parsePlist(raw[start.lowerBound..<end.upperBound])
    }

    private static func parsePlist(_ data: Data) -> [String: Any]? {
      guard
        let object = try? PropertyListSerialization.propertyList(
          from: data, options: [], format: nil)
      else { return nil }
      return object as? [String: Any]
    }
  }
#endif
