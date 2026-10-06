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
    /// read from the executable itself: simulator builds embed them in a
    /// `__TEXT,__entitlements` section, and every device build (development,
    /// TestFlight, App Store) carries them in its code signature. App Store and
    /// TestFlight builds have no embedded provisioning profile (Apple TN3125),
    /// so the profile is only a last resort. Anything else fails closed so
    /// CloudKit is never initialized without the container grant.
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
  /// Only sources the signing toolchain actually produces are consulted; a
  /// missing or unparseable source yields an empty result so callers fail
  /// closed.
  enum EmbeddedEntitlements {
    static let iCloudContainersKey = "com.apple.developer.icloud-container-identifiers"

    static func iCloudContainerIdentifiers() -> [String] {
      if let entitlements = executableEntitlements() {
        return entitlements[iCloudContainersKey] as? [String] ?? []
      }
      if let containers = codeSignatureICloudContainers {
        return containers
      }
      if let entitlements = provisioningProfileEntitlements() {
        return entitlements[iCloudContainersKey] as? [String] ?? []
      }
      return []
    }

    /// The signature cannot change while the process runs, so the executable
    /// is parsed once.
    private static let codeSignatureICloudContainers: [String]? = {
      guard let entitlements = codeSignatureEntitlements(), !entitlements.isEmpty else {
        return nil
      }
      return entitlements[iCloudContainersKey] as? [String] ?? []
    }()

    /// Device builds: the entitlements blob (`CSSLOT_ENTITLEMENTS`, magic
    /// `0xfade7171`) inside the code-signature superblob that the main
    /// executable's `LC_CODE_SIGNATURE` load command points at. The file on
    /// disk is the one the kernel validated at launch.
    static func codeSignatureEntitlements() -> [String: Any]? {
      guard let url = Bundle.main.executableURL,
        let file = try? Data(contentsOf: url, options: .alwaysMapped)
      else { return nil }
      let cpuType = mainExecutableHeader()?.pointee.cputype
      return codeSignatureEntitlements(inExecutable: file, cpuType: cpuType)
    }

    static func codeSignatureEntitlements(inExecutable file: Data, cpuType: cpu_type_t?)
      -> [String: Any]?
    {
      let bytes = [UInt8](file)
      guard let slice = machOSlice(bytes, cpuType: cpuType),
        let signature = codeSignatureRange(bytes, slice: slice),
        let blob = entitlementsBlob(bytes, superblob: signature)
      else { return nil }
      return parsePlist(Data(bytes[blob]))
    }

    private static func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
      guard offset >= 0, offset + 4 <= bytes.count else { return nil }
      return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
        | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func readBE32(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
      guard offset >= 0, offset + 4 <= bytes.count else { return nil }
      return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
        | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    /// The thin 64-bit Mach-O image, or the slice of a universal binary that
    /// matches the running CPU type.
    private static func machOSlice(_ bytes: [UInt8], cpuType: cpu_type_t?) -> Range<Int>? {
      guard let magic = readBE32(bytes, 0) else { return nil }
      if magic == FAT_MAGIC || magic == FAT_MAGIC_64 {
        guard let count = readBE32(bytes, 4), count > 0, count < 64 else { return nil }
        let entrySize = magic == FAT_MAGIC_64 ? 32 : 20
        for index in 0..<Int(count) {
          let entry = 8 + index * entrySize
          guard let type = readBE32(bytes, entry) else { return nil }
          let offset: Int
          let size: Int
          if magic == FAT_MAGIC_64 {
            guard let offHigh = readBE32(bytes, entry + 8), let offLow = readBE32(bytes, entry + 12),
              let sizeHigh = readBE32(bytes, entry + 16), let sizeLow = readBE32(bytes, entry + 20)
            else { return nil }
            offset = Int(UInt64(offHigh) << 32 | UInt64(offLow))
            size = Int(UInt64(sizeHigh) << 32 | UInt64(sizeLow))
          } else {
            guard let off = readBE32(bytes, entry + 8), let length = readBE32(bytes, entry + 12)
            else { return nil }
            offset = Int(off)
            size = Int(length)
          }
          guard cpuType == nil || cpu_type_t(bitPattern: type) == cpuType else { continue }
          guard offset >= 0, size > 0, offset <= bytes.count - size else { return nil }
          return offset..<(offset + size)
        }
        return nil
      }
      guard readLE32(bytes, 0) == MH_MAGIC_64 else { return nil }
      return 0..<bytes.count
    }

    /// Absolute byte range of the code-signature superblob in the file.
    private static func codeSignatureRange(_ bytes: [UInt8], slice: Range<Int>) -> Range<Int>? {
      let base = slice.lowerBound
      guard readLE32(bytes, base) == MH_MAGIC_64,
        let commandCount = readLE32(bytes, base + 16), commandCount < 4096
      else { return nil }
      var cursor = base + MemoryLayout<mach_header_64>.size
      for _ in 0..<Int(commandCount) {
        guard let command = readLE32(bytes, cursor), let size = readLE32(bytes, cursor + 4),
          size >= 8, cursor + Int(size) <= slice.upperBound
        else { return nil }
        if command == UInt32(LC_CODE_SIGNATURE) {
          guard let dataOffset = readLE32(bytes, cursor + 8),
            let dataSize = readLE32(bytes, cursor + 12)
          else { return nil }
          let start = base + Int(dataOffset)
          let end = start + Int(dataSize)
          guard dataSize > 0, start >= base, end <= slice.upperBound else { return nil }
          return start..<end
        }
        cursor += Int(size)
      }
      return nil
    }

    /// The XML payload of the entitlements blob inside the superblob.
    private static func entitlementsBlob(_ bytes: [UInt8], superblob: Range<Int>) -> Range<Int>? {
      let base = superblob.lowerBound
      guard readBE32(bytes, base) == 0xfade_0cc0,
        let length = readBE32(bytes, base + 4), Int(length) <= superblob.count,
        let count = readBE32(bytes, base + 8), count < 64
      else { return nil }
      for index in 0..<Int(count) {
        let entry = base + 12 + index * 8
        guard entry + 8 <= base + Int(length), let type = readBE32(bytes, entry),
          let offset = readBE32(bytes, entry + 4)
        else { return nil }
        guard type == 5 else { continue }
        let blob = base + Int(offset)
        guard readBE32(bytes, blob) == 0xfade_7171,
          let blobLength = readBE32(bytes, blob + 4), blobLength > 8,
          blob + Int(blobLength) <= base + Int(length)
        else { return nil }
        return (blob + 8)..<(blob + Int(blobLength))
      }
      return nil
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
