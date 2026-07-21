import Darwin
import Foundation

public enum AtomicFilePublicationError: Error, Equatable, LocalizedError, Sendable {
  case unsafeDestination
  case temporaryFileCreationFailed
  case writeFailed
  case durabilityUnavailable
  case publishFailed
  case publishedFileVerificationFailed

  public var errorDescription: String? {
    switch self {
    case .unsafeDestination:
      "The selected destination is not a safe, app-owned file location. Choose another folder."
    case .temporaryFileCreationFailed:
      "Address Atlas could not create an owner-only temporary recovery file at that location."
    case .writeFailed:
      "The recovery file could not be written completely. No recovery code was revealed."
    case .durabilityUnavailable:
      "The recovery file could not be proven crash-durable. No recovery code was revealed."
    case .publishFailed:
      "The recovery file could not be published atomically. No recovery code was revealed."
    case .publishedFileVerificationFailed:
      "The published recovery file changed unexpectedly. No recovery code was revealed."
    }
  }
}

/// Injectable only inside AddressAtlasCore tests. Production call sites always
/// use the kernel operations below; keeping the seam at the syscall boundary
/// lets failure-ordering tests prove that no success/code escapes early.
// The hooks are immutable during every publication and invoked synchronously
// on the calling thread. Tests finish configuring a value before passing it to
// the publisher; no closure or captured mutable state is shared afterward.
struct AtomicFilePublicationOperations: @unchecked Sendable {
  var write: (_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int
  var fullSynchronize: (_ descriptor: Int32) -> Bool
  var rename: (
    _ sourceDirectory: Int32,
    _ sourceName: String,
    _ destinationDirectory: Int32,
    _ destinationName: String
  ) -> Bool
  var synchronizeDirectory: (_ descriptor: Int32) -> Bool

  static let production = AtomicFilePublicationOperations(
    write: { descriptor, bytes, count in
      Darwin.write(descriptor, bytes, count)
    },
    fullSynchronize: { descriptor in
      MacOSFileDurability.fullSynchronizeRegularFile(descriptor)
    },
    rename: { sourceDirectory, sourceName, destinationDirectory, destinationName in
      sourceName.withCString { source in
        destinationName.withCString { destination in
          Darwin.renameat(sourceDirectory, source, destinationDirectory, destination) == 0
        }
      }
    },
    synchronizeDirectory: { descriptor in
      MacOSFileDurability.synchronizeDirectory(descriptor)
    }
  )
}

/// Publishes a small security-sensitive file with an explicit macOS durability
/// contract. A successful return means the exact owner-only inode was fully
/// synchronized both before and after its atomic rename, and the containing
/// directory metadata reached a durability barrier.
enum AtomicFilePublisher {
  static func publish(
    _ data: Data,
    to destination: URL,
    operations: AtomicFilePublicationOperations = .production
  ) throws {
    guard destination.isFileURL else {
      throw AtomicFilePublicationError.unsafeDestination
    }
    let destinationName = destination.lastPathComponent
    guard !destinationName.isEmpty, destinationName != ".", destinationName != "..",
      !destinationName.contains("/")
    else {
      throw AtomicFilePublicationError.unsafeDestination
    }

    let directoryURL = destination.deletingLastPathComponent()
    let directoryDescriptor = directoryURL.path.withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard directoryDescriptor >= 0 else {
      throw AtomicFilePublicationError.unsafeDestination
    }
    defer { Darwin.close(directoryDescriptor) }

    var directoryMetadata = stat()
    guard Darwin.fstat(directoryDescriptor, &directoryMetadata) == 0,
      (directoryMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
      directoryMetadata.st_uid == geteuid()
    else {
      throw AtomicFilePublicationError.unsafeDestination
    }
    try validateExistingDestination(
      named: destinationName,
      directoryDescriptor: directoryDescriptor
    )

    let temporaryName = ".address-atlas-" + UUID().uuidString.lowercased() + ".tmp"
    let permissions = mode_t(S_IRUSR | S_IWUSR)
    let temporaryDescriptor = temporaryName.withCString {
      Darwin.openat(
        directoryDescriptor,
        $0,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        permissions
      )
    }
    guard temporaryDescriptor >= 0 else {
      throw AtomicFilePublicationError.temporaryFileCreationFailed
    }

    var didRename = false
    defer {
      Darwin.close(temporaryDescriptor)
      if !didRename {
        temporaryName.withCString { _ = Darwin.unlinkat(directoryDescriptor, $0, 0) }
      }
    }
    guard Darwin.fchmod(temporaryDescriptor, permissions) == 0 else {
      throw AtomicFilePublicationError.temporaryFileCreationFailed
    }

    try writeAll(data, to: temporaryDescriptor, operation: operations.write)
    guard let expectedIdentity = MacOSFileDurability.regularFileIdentity(temporaryDescriptor),
      expectedIdentity.mode & mode_t(0o777) == permissions,
      operations.fullSynchronize(temporaryDescriptor),
      MacOSFileDurability.regularFileIdentity(temporaryDescriptor) == expectedIdentity
    else {
      throw AtomicFilePublicationError.durabilityUnavailable
    }

    guard operations.rename(
      directoryDescriptor,
      temporaryName,
      directoryDescriptor,
      destinationName
    ) else {
      throw AtomicFilePublicationError.publishFailed
    }
    didRename = true

    let publishedDescriptor = destinationName.withCString {
      Darwin.openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard publishedDescriptor >= 0 else {
      throw AtomicFilePublicationError.publishedFileVerificationFailed
    }
    defer { Darwin.close(publishedDescriptor) }
    guard MacOSFileDurability.regularFileIdentity(publishedDescriptor) == expectedIdentity,
      operations.fullSynchronize(publishedDescriptor),
      MacOSFileDurability.regularFileIdentity(publishedDescriptor) == expectedIdentity
    else {
      throw AtomicFilePublicationError.publishedFileVerificationFailed
    }
    guard operations.synchronizeDirectory(directoryDescriptor) else {
      throw AtomicFilePublicationError.durabilityUnavailable
    }
  }

  private static func validateExistingDestination(
    named name: String,
    directoryDescriptor: Int32
  ) throws {
    var metadata = stat()
    let status = name.withCString {
      Darwin.fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
    }
    if status != 0 {
      guard errno == ENOENT else {
        throw AtomicFilePublicationError.unsafeDestination
      }
      return
    }
    guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      metadata.st_uid == geteuid(),
      metadata.st_nlink == 1
    else {
      throw AtomicFilePublicationError.unsafeDestination
    }
  }

  private static func writeAll(
    _ data: Data,
    to descriptor: Int32,
    operation: (_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int
  ) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      var offset = 0
      while offset < rawBuffer.count {
        let result = operation(
          descriptor,
          baseAddress.advanced(by: offset),
          rawBuffer.count - offset
        )
        if result > 0 {
          offset += result
          continue
        }
        if result < 0, errno == EINTR { continue }
        throw AtomicFilePublicationError.writeFailed
      }
    }
  }
}
