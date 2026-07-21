import CryptoKit
import Darwin
import Foundation

public enum DamagedVaultRecoveryError: Error, Equatable, LocalizedError, Sendable {
  case unsafeVaultPath
  case vaultInUse
  case sourceChanged
  case quarantineCreationFailed
  case quarantineCopyFailed
  case quarantineDurabilityUnavailable
  case cleanVaultCreationFailed
  case cleanVaultPublicationFailed

  public var errorDescription: String? {
    switch self {
    case .unsafeVaultPath:
      "The damaged vault path is not a single app-owned regular file. Nothing was changed."
    case .vaultInUse:
      "Another Address Atlas process still has the local vault open. Close it before quarantining the damaged vault; nothing was changed."
    case .sourceChanged:
      "The damaged vault files changed during recovery. Nothing was replaced; close other Address Atlas processes and try again."
    case .quarantineCreationFailed:
      "Address Atlas could not create a private quarantine folder. The damaged vault was not replaced."
    case .quarantineCopyFailed:
      "The damaged vault could not be copied completely into quarantine. The original files were left in place."
    case .quarantineDurabilityUnavailable:
      "The quarantine copy could not be proven crash-durable. The original vault was left in place."
    case .cleanVaultCreationFailed:
      "The damaged vault is preserved in quarantine, but a clean local vault could not be prepared. Try again after fixing available storage."
    case .cleanVaultPublicationFailed:
      "The damaged vault is preserved in quarantine, but the clean local vault could not be activated safely. Restart Address Atlas and try again."
    }
  }
}

public struct QuarantinedDamagedVault: Sendable {
  public let quarantineDirectory: URL
  public let document: VaultDocument
  public let store: EncryptedSQLiteVaultStore

  public init(
    quarantineDirectory: URL,
    document: VaultDocument,
    store: EncryptedSQLiteVaultStore
  ) {
    self.quarantineDirectory = quarantineDirectory
    self.document = document
    self.store = store
  }
}

/// Explicit, loss-averse escape hatch for a primary SQLite file that cannot be
/// authenticated or decoded. Nothing invokes this service automatically. It
/// first publishes a byte-verified, owner-only quarantine directory containing
/// the database and every present SQLite sidecar; only then may a separately
/// prepared empty database replace the damaged primary.
public struct DamagedVaultRecoveryService {
  private struct FileSnapshot: Equatable {
    var name: String
    var device: dev_t
    var inode: ino_t
    var byteCount: off_t
    var modifiedSeconds: Int
    var modifiedNanoseconds: Int
    var changedSeconds: Int
    var changedNanoseconds: Int
  }

  private let operations: AtomicFilePublicationOperations

  public init() {
    operations = .production
  }

  init(operations: AtomicFilePublicationOperations) {
    self.operations = operations
  }

  public func quarantineAndCreateCleanVault(
    at vaultURL: URL,
    vaultKey: Data,
    crypto: VaultCrypto = VaultCrypto()
  ) throws -> QuarantinedDamagedVault {
    guard vaultURL.isFileURL, vaultKey.count == VaultCrypto.vaultKeyByteCount else {
      throw DamagedVaultRecoveryError.unsafeVaultPath
    }
    let vaultName = vaultURL.lastPathComponent
    guard !vaultName.isEmpty, vaultName != ".", vaultName != "..", !vaultName.contains("/") else {
      throw DamagedVaultRecoveryError.unsafeVaultPath
    }
    let parentURL = vaultURL.deletingLastPathComponent()
    let parentDescriptor = parentURL.path.withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard parentDescriptor >= 0 else {
      throw DamagedVaultRecoveryError.unsafeVaultPath
    }
    defer { Darwin.close(parentDescriptor) }
    guard isOwnedDirectory(parentDescriptor) else {
      throw DamagedVaultRecoveryError.unsafeVaultPath
    }
    let recoveryLease: VaultFileAccessLease
    do {
      recoveryLease = try VaultFileAccessLease.acquireExclusive(
        vaultName: vaultName,
        parentDescriptor: parentDescriptor
      )
    } catch VaultFileAccessLockError.busy {
      throw DamagedVaultRecoveryError.vaultInUse
    } catch VaultFileAccessLockError.unsafePath {
      throw DamagedVaultRecoveryError.unsafeVaultPath
    } catch {
      throw DamagedVaultRecoveryError.vaultInUse
    }
    defer { recoveryLease.release() }

    let sidecarNames = [
      vaultName,
      vaultName + "-wal",
      vaultName + "-shm",
      vaultName + "-journal",
    ]
    let sourceSnapshots = try snapshots(
      names: sidecarNames,
      requiredName: vaultName,
      directoryDescriptor: parentDescriptor
    )

    let nonce = UUID().uuidString.lowercased()
    let cleanStagingName = ".vault-clean-" + nonce + ".tmp"
    let quarantineStagingName = ".vault-quarantine-" + nonce + ".tmp"
    let quarantineName = "vault-quarantine-" + nonce
    let cleanStagingURL = parentURL.appending(path: cleanStagingName)
    let quarantineStagingURL = parentURL.appending(path: quarantineStagingName)
    let quarantineURL = parentURL.appending(path: quarantineName)
    var quarantinePublished = false
    defer {
      try? FileManager.default.removeItem(at: cleanStagingURL)
      if !quarantinePublished {
        try? FileManager.default.removeItem(at: quarantineStagingURL)
      }
    }

    let cleanDirectoryDescriptor = try createOwnedDirectory(
      named: cleanStagingName,
      parentDescriptor: parentDescriptor,
      failure: .cleanVaultCreationFailed
    )
    defer { Darwin.close(cleanDirectoryDescriptor) }
    let cleanVaultURL = cleanStagingURL.appending(path: vaultName)
    let cleanStore: EncryptedSQLiteVaultStore
    do {
      cleanStore = try EncryptedSQLiteVaultStore(
        path: cleanVaultURL,
        vaultKey: vaultKey,
        crypto: crypto
      )
      try cleanStore.initialize()
      let empty = try cleanStore.load()
      guard isCleanInitialDocument(empty) else {
        throw DamagedVaultRecoveryError.cleanVaultCreationFailed
      }
    } catch let error as DamagedVaultRecoveryError {
      throw error
    } catch {
      throw DamagedVaultRecoveryError.cleanVaultCreationFailed
    }
    let cleanDescriptor = vaultName.withCString {
      Darwin.openat(cleanDirectoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard cleanDescriptor >= 0 else {
      throw DamagedVaultRecoveryError.cleanVaultCreationFailed
    }
    let cleanIdentity = MacOSFileDurability.regularFileIdentity(cleanDescriptor)
    let cleanDurable = operations.fullSynchronize(cleanDescriptor)
    Darwin.close(cleanDescriptor)
    guard cleanIdentity != nil, cleanDurable,
      operations.synchronizeDirectory(cleanDirectoryDescriptor)
    else {
      throw DamagedVaultRecoveryError.cleanVaultCreationFailed
    }

    let quarantineDescriptor = try createOwnedDirectory(
      named: quarantineStagingName,
      parentDescriptor: parentDescriptor,
      failure: .quarantineCreationFailed
    )
    defer { Darwin.close(quarantineDescriptor) }
    for snapshot in sourceSnapshots {
      try copyAndVerify(
        snapshot,
        sourceDirectory: parentDescriptor,
        destinationDirectory: quarantineDescriptor
      )
    }
    guard try snapshots(
      names: sidecarNames,
      requiredName: vaultName,
      directoryDescriptor: parentDescriptor
    ) == sourceSnapshots else {
      throw DamagedVaultRecoveryError.sourceChanged
    }
    guard operations.synchronizeDirectory(quarantineDescriptor) else {
      throw DamagedVaultRecoveryError.quarantineDurabilityUnavailable
    }
    guard operations.rename(
      parentDescriptor,
      quarantineStagingName,
      parentDescriptor,
      quarantineName
    ) else {
      throw DamagedVaultRecoveryError.quarantineCreationFailed
    }
    quarantinePublished = true
    guard operations.synchronizeDirectory(parentDescriptor) else {
      // The published copy may be visible, but without the parent barrier it
      // is not authoritative. Originals have not been touched at this point.
      throw DamagedVaultRecoveryError.quarantineDurabilityUnavailable
    }

    // Recheck the complete group before the first destructive syscall. If a
    // second process changed or created a sidecar, keep both the originals and
    // the already-safe quarantine rather than mixing SQLite generations.
    guard try snapshots(
      names: sidecarNames,
      requiredName: vaultName,
      directoryDescriptor: parentDescriptor
    ) == sourceSnapshots else {
      throw DamagedVaultRecoveryError.sourceChanged
    }
    for sidecar in sourceSnapshots where sidecar.name != vaultName {
      guard sidecar.name.withCString({ Darwin.unlinkat(parentDescriptor, $0, 0) }) == 0 else {
        throw DamagedVaultRecoveryError.cleanVaultPublicationFailed
      }
    }
    guard operations.rename(
      cleanDirectoryDescriptor,
      vaultName,
      parentDescriptor,
      vaultName
    ) else {
      throw DamagedVaultRecoveryError.cleanVaultPublicationFailed
    }

    let publishedDescriptor = vaultName.withCString {
      Darwin.openat(parentDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard publishedDescriptor >= 0 else {
      throw DamagedVaultRecoveryError.cleanVaultPublicationFailed
    }
    let publishedIsExpected = MacOSFileDurability.regularFileIdentity(publishedDescriptor)
      == cleanIdentity
    let publishedDurable = operations.fullSynchronize(publishedDescriptor)
    let publishedStillExpected = MacOSFileDurability.regularFileIdentity(publishedDescriptor)
      == cleanIdentity
    Darwin.close(publishedDescriptor)
    guard publishedIsExpected, publishedDurable, publishedStillExpected,
      operations.synchronizeDirectory(parentDescriptor)
    else {
      throw DamagedVaultRecoveryError.cleanVaultPublicationFailed
    }

    // The path replacement is complete and durable. Drop the exclusive lease
    // before opening the newly published database through a normal store, which
    // will acquire and retain its own shared lease.
    recoveryLease.release()

    let activatedStore: EncryptedSQLiteVaultStore
    let activatedDocument: VaultDocument
    do {
      activatedStore = try EncryptedSQLiteVaultStore(
        path: vaultURL,
        vaultKey: vaultKey,
        crypto: crypto
      )
      activatedDocument = try activatedStore.load()
      guard isCleanInitialDocument(activatedDocument) else {
        throw DamagedVaultRecoveryError.cleanVaultPublicationFailed
      }
    } catch let error as DamagedVaultRecoveryError {
      throw error
    } catch {
      throw DamagedVaultRecoveryError.cleanVaultPublicationFailed
    }
    return QuarantinedDamagedVault(
      quarantineDirectory: quarantineURL,
      document: activatedDocument,
      store: activatedStore
    )
  }

  private func createOwnedDirectory(
    named name: String,
    parentDescriptor: Int32,
    failure: DamagedVaultRecoveryError
  ) throws -> Int32 {
    let created = name.withCString { Darwin.mkdirat(parentDescriptor, $0, S_IRWXU) }
    guard created == 0 else { throw failure }
    let descriptor = name.withCString {
      Darwin.openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0, isOwnedDirectory(descriptor), Darwin.fchmod(descriptor, S_IRWXU) == 0
    else {
      if descriptor >= 0 { Darwin.close(descriptor) }
      throw failure
    }
    return descriptor
  }

  private func isCleanInitialDocument(_ document: VaultDocument) -> Bool {
    document.wallets.isEmpty
      && document.customTokens.isEmpty
      && document.manualHoldings.isEmpty
      && document.exchangeConnections.isEmpty
      && document.scanRuns.isEmpty
      && document.syncState.accountId == nil
      && document.syncState.sessionToken.isEmpty
      && document.syncState.latestRemoteVersion == 0
  }

  private func isOwnedDirectory(_ descriptor: Int32) -> Bool {
    var metadata = stat()
    return Darwin.fstat(descriptor, &metadata) == 0
      && (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
      && metadata.st_uid == geteuid()
  }

  private func snapshots(
    names: [String],
    requiredName: String,
    directoryDescriptor: Int32
  ) throws -> [FileSnapshot] {
    var result: [FileSnapshot] = []
    for name in names {
      var metadata = stat()
      let status = name.withCString {
        Darwin.fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
      }
      if status != 0 {
        if errno == ENOENT, name != requiredName { continue }
        throw DamagedVaultRecoveryError.unsafeVaultPath
      }
      guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
        metadata.st_uid == geteuid(),
        metadata.st_nlink == 1,
        metadata.st_size >= 0
      else {
        throw DamagedVaultRecoveryError.unsafeVaultPath
      }
      result.append(
        FileSnapshot(
          name: name,
          device: metadata.st_dev,
          inode: metadata.st_ino,
          byteCount: metadata.st_size,
          modifiedSeconds: metadata.st_mtimespec.tv_sec,
          modifiedNanoseconds: metadata.st_mtimespec.tv_nsec,
          changedSeconds: metadata.st_ctimespec.tv_sec,
          changedNanoseconds: metadata.st_ctimespec.tv_nsec
        ))
    }
    guard result.contains(where: { $0.name == requiredName }) else {
      throw DamagedVaultRecoveryError.unsafeVaultPath
    }
    return result
  }

  private func copyAndVerify(
    _ expected: FileSnapshot,
    sourceDirectory: Int32,
    destinationDirectory: Int32
  ) throws {
    let source = expected.name.withCString {
      Darwin.openat(sourceDirectory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard source >= 0 else { throw DamagedVaultRecoveryError.sourceChanged }
    defer { Darwin.close(source) }
    guard snapshot(name: expected.name, descriptor: source) == expected else {
      throw DamagedVaultRecoveryError.sourceChanged
    }

    let destination = expected.name.withCString {
      Darwin.openat(
        destinationDirectory,
        $0,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        S_IRUSR | S_IWUSR
      )
    }
    guard destination >= 0 else {
      throw DamagedVaultRecoveryError.quarantineCopyFailed
    }
    defer { Darwin.close(destination) }
    guard Darwin.fchmod(destination, S_IRUSR | S_IWUSR) == 0 else {
      throw DamagedVaultRecoveryError.quarantineCopyFailed
    }

    var sourceHash = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let readCount = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(source, bytes.baseAddress, bytes.count)
      }
      if readCount == 0 { break }
      if readCount < 0 {
        if errno == EINTR { continue }
        throw DamagedVaultRecoveryError.quarantineCopyFailed
      }
      let chunk = Data(buffer.prefix(readCount))
      sourceHash.update(data: chunk)
      try chunk.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        var offset = 0
        while offset < readCount {
          let written = operations.write(
            destination,
            baseAddress.advanced(by: offset),
            readCount - offset
          )
          if written > 0 {
            offset += written
          } else if written < 0, errno == EINTR {
            continue
          } else {
            throw DamagedVaultRecoveryError.quarantineCopyFailed
          }
        }
      }
    }
    guard snapshot(name: expected.name, descriptor: source) == expected,
      operations.fullSynchronize(destination),
      let destinationIdentity = MacOSFileDurability.regularFileIdentity(destination),
      destinationIdentity.mode & mode_t(0o777) == mode_t(S_IRUSR | S_IWUSR)
    else {
      throw DamagedVaultRecoveryError.quarantineDurabilityUnavailable
    }

    let verifier = expected.name.withCString {
      Darwin.openat(destinationDirectory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard verifier >= 0 else {
      throw DamagedVaultRecoveryError.quarantineCopyFailed
    }
    defer { Darwin.close(verifier) }
    var destinationHash = SHA256()
    while true {
      let readCount = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(verifier, bytes.baseAddress, bytes.count)
      }
      if readCount == 0 { break }
      if readCount < 0 {
        if errno == EINTR { continue }
        throw DamagedVaultRecoveryError.quarantineCopyFailed
      }
      destinationHash.update(data: Data(buffer.prefix(readCount)))
    }
    guard Data(sourceHash.finalize()) == Data(destinationHash.finalize()),
      MacOSFileDurability.regularFileIdentity(verifier) == destinationIdentity,
      operations.fullSynchronize(verifier),
      MacOSFileDurability.regularFileIdentity(verifier) == destinationIdentity
    else {
      throw DamagedVaultRecoveryError.quarantineDurabilityUnavailable
    }
  }

  private func snapshot(name: String, descriptor: Int32) -> FileSnapshot? {
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      metadata.st_uid == geteuid(),
      metadata.st_nlink == 1,
      metadata.st_size >= 0
    else { return nil }
    return FileSnapshot(
      name: name,
      device: metadata.st_dev,
      inode: metadata.st_ino,
      byteCount: metadata.st_size,
      modifiedSeconds: metadata.st_mtimespec.tv_sec,
      modifiedNanoseconds: metadata.st_mtimespec.tv_nsec,
      changedSeconds: metadata.st_ctimespec.tv_sec,
      changedNanoseconds: metadata.st_ctimespec.tv_nsec
    )
  }
}
