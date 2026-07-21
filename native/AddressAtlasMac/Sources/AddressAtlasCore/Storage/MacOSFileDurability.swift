import Darwin
import Foundation

/// Crash-durability primitives shared by security-sensitive atomic files.
/// `fsync` alone is explicitly weaker than `F_FULLFSYNC` on macOS for regular
/// files, so callers must not substitute one for the other or treat an
/// unsupported operation as success.
enum MacOSFileDurability {
  struct RegularFileIdentity: Equatable, Sendable {
    var device: dev_t
    var inode: ino_t
    var owner: uid_t
    var mode: mode_t
    var linkCount: nlink_t
  }

  static func regularFileIdentity(_ descriptor: Int32) -> RegularFileIdentity? {
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      metadata.st_uid == geteuid(),
      metadata.st_nlink == 1
    else { return nil }
    return RegularFileIdentity(
      device: metadata.st_dev,
      inode: metadata.st_ino,
      owner: metadata.st_uid,
      mode: metadata.st_mode,
      linkCount: metadata.st_nlink
    )
  }

  static func fullSynchronizeRegularFile(_ descriptor: Int32) -> Bool {
    fullSynchronizeRegularFile(descriptor) {
      let result = Darwin.fcntl(descriptor, F_FULLFSYNC)
      return (result, result == 0 ? 0 : errno)
    }
  }

  private static func fullSynchronizeRegularFile(
    _ descriptor: Int32,
    operation: () -> (result: Int32, error: Int32)
  ) -> Bool {
    guard regularFileIdentity(descriptor) != nil else { return false }
    while true {
      let outcome = operation()
      if outcome.result == 0 { break }
      if outcome.error == EINTR { continue }
      // EINVAL/ENOTSUP are proof that the requested durability barrier was not
      // provided, never a reason to downgrade silently to ordinary fsync.
      return false
    }
    return regularFileIdentity(descriptor) != nil
  }

  static func synchronizeDirectory(_ descriptor: Int32) -> Bool {
    synchronizeDirectory(descriptor) {
      let result = Darwin.fsync(descriptor)
      return (result, result == 0 ? 0 : errno)
    }
  }

  private static func synchronizeDirectory(
    _ descriptor: Int32,
    operation: () -> (result: Int32, error: Int32)
  ) -> Bool {
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid()
    else { return false }
    while true {
      let outcome = operation()
      if outcome.result == 0 { return true }
      if outcome.error == EINTR { continue }
      // In particular, EINVAL does not make the rename crash-durable.
      return false
    }
  }

  static func fullSynchronizeRegularFileForTesting(
    _ descriptor: Int32,
    operation: () -> (result: Int32, error: Int32)
  ) -> Bool {
    fullSynchronizeRegularFile(descriptor, operation: operation)
  }

  static func synchronizeDirectoryForTesting(
    _ descriptor: Int32,
    operation: () -> (result: Int32, error: Int32)
  ) -> Bool {
    synchronizeDirectory(descriptor, operation: operation)
  }
}
