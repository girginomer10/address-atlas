import Darwin
import Foundation

enum VaultFileAccessLockError: Error, Equatable {
  case unsafePath
  case busy
  case unavailable
}

/// A process-wide advisory lease shared by every current Address Atlas vault
/// store. Normal stores retain a shared lease for their lifetime; maintenance
/// that can replace the SQLite inode requires the matching exclusive lease.
/// This closes the gap that SQLite transactions cannot cover once the primary
/// path and its sidecars are about to be renamed or unlinked.
final class VaultFileAccessLease: @unchecked Sendable {
  private var descriptor: Int32

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit {
    release()
  }

  static func acquireShared(for vaultURL: URL) throws -> VaultFileAccessLease {
    guard vaultURL.isFileURL else { throw VaultFileAccessLockError.unsafePath }
    let vaultName = try validatedVaultName(vaultURL.lastPathComponent)
    let parentURL = vaultURL.deletingLastPathComponent()
    let parentDescriptor = parentURL.path.withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard parentDescriptor >= 0 else { throw VaultFileAccessLockError.unsafePath }
    defer { Darwin.close(parentDescriptor) }
    guard isOwnedDirectory(parentDescriptor) else {
      throw VaultFileAccessLockError.unsafePath
    }
    return try acquire(
      vaultName: vaultName,
      parentDescriptor: parentDescriptor,
      operation: LOCK_SH | LOCK_NB
    )
  }

  static func acquireExclusive(
    vaultName: String,
    parentDescriptor: Int32
  ) throws -> VaultFileAccessLease {
    let vaultName = try validatedVaultName(vaultName)
    guard isOwnedDirectory(parentDescriptor) else {
      throw VaultFileAccessLockError.unsafePath
    }
    return try acquire(
      vaultName: vaultName,
      parentDescriptor: parentDescriptor,
      operation: LOCK_EX | LOCK_NB
    )
  }

  func release() {
    guard descriptor >= 0 else { return }
    _ = flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
    descriptor = -1
  }

  private static func acquire(
    vaultName: String,
    parentDescriptor: Int32,
    operation: Int32
  ) throws -> VaultFileAccessLease {
    let lockName = "." + vaultName + ".address-atlas.lock"
    guard lockName.utf8.count <= Int(NAME_MAX) else {
      throw VaultFileAccessLockError.unsafePath
    }
    let descriptor = lockName.withCString {
      Darwin.openat(
        parentDescriptor,
        $0,
        O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
        S_IRUSR | S_IWUSR
      )
    }
    guard descriptor >= 0 else {
      if errno == ELOOP { throw VaultFileAccessLockError.unsafePath }
      throw VaultFileAccessLockError.unavailable
    }
    var shouldClose = true
    defer {
      if shouldClose { Darwin.close(descriptor) }
    }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      metadata.st_uid == geteuid(),
      metadata.st_nlink == 1,
      Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
    else {
      throw VaultFileAccessLockError.unsafePath
    }

    while flock(descriptor, operation) != 0 {
      if errno == EINTR { continue }
      if errno == EWOULDBLOCK || errno == EAGAIN {
        throw VaultFileAccessLockError.busy
      }
      throw VaultFileAccessLockError.unavailable
    }
    shouldClose = false
    return VaultFileAccessLease(descriptor: descriptor)
  }

  private static func validatedVaultName(_ candidate: String) throws -> String {
    guard !candidate.isEmpty, candidate != ".", candidate != "..", !candidate.contains("/") else {
      throw VaultFileAccessLockError.unsafePath
    }
    return candidate
  }

  private static func isOwnedDirectory(_ descriptor: Int32) -> Bool {
    var metadata = stat()
    return Darwin.fstat(descriptor, &metadata) == 0
      && (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
      && metadata.st_uid == geteuid()
  }
}
