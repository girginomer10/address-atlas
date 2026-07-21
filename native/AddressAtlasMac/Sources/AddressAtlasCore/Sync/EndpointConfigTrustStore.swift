import CryptoKit
import Darwin
import Foundation

@_silgen_name("flock")
private func endpointConfigFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

public protocol EndpointConfigTrustPersisting: Sendable {
  /// Verifies a candidate against the current per-origin high-water mark
  /// without advancing durable trust. Authentication flows use this before
  /// presenting UI, then commit only after the authority is authenticated.
  func validate(_ config: NativeEndpointConfig, for serverOrigin: URL) async throws

  /// Atomically verifies and advances the per-origin endpoint-config high-water
  /// mark. The result distinguishes a crash-durable commit from a rename that is
  /// visible to this process but whose directory durability barrier failed.
  /// Callers may keep the visible policy applied in the latter state, but must
  /// fail closed for sync/auth until a later retry returns `.durable`.
  @discardableResult
  func validateAndRecord(
    _ config: NativeEndpointConfig,
    for serverOrigin: URL
  ) async throws -> EndpointConfigTrustCommitOutcome
}

public enum EndpointConfigTrustCommitOutcome: Equatable, Sendable {
  case durable
  case committedDurabilityUncertain

  public var isDurable: Bool { self == .durable }
}

public enum EndpointConfigTrustStoreError: Error, Equatable, LocalizedError {
  case invalidOrigin
  case invalidStore
  case rollback(previous: Int, received: Int)
  case equivocation(version: Int)
  case unavailable

  public var errorDescription: String? {
    switch self {
    case .invalidOrigin:
      "The sync server origin is invalid. Endpoint policy was not applied."
    case .invalidStore:
      "The saved endpoint-policy trust record is damaged. Endpoint policy was not applied."
    case .rollback:
      "The sync server returned an older endpoint policy. The previously verified policy was kept."
    case .equivocation:
      "The sync server changed endpoint policy without advancing its version. The previously verified policy was kept."
    case .unavailable:
      "The endpoint-policy trust record could not be saved securely. Endpoint policy was not applied."
    }
  }
}

/// A small, owner-only, durable trust-on-first-use store. Records are keyed by
/// canonical sync-server origin so changing servers never resets another
/// authority's rollback protection. The whole map is bounded, validated, and
/// replaced atomically before a new policy can be applied by the caller.
public actor EndpointConfigTrustStore: EndpointConfigTrustPersisting {
  // Persisted records may have been written by an older signed app whose
  // bundled endpoint policy predates this binary. Incoming responses are
  // independently required to meet the current bundled floor by
  // NativeEndpointConfigClient; loading a historical high-water mark must not
  // brick the upgrade path before it can advance to the newer version.
  private static let minimumPersistedConfigVersion = 1
  private struct Record: Codable, Equatable, Sendable {
    var version: Int
    var digest: String
  }

  private struct Document: Codable, Sendable {
    var schemaVersion: Int
    var records: [String: Record]
  }

  private static let maximumOrigins = 32
  private static let maximumDocumentByteCount = 128_000
  private let fileURL: URL
  private let regularFileSync: @Sendable (Int32) -> Bool
  private let postRenameDirectorySync: @Sendable (Int32) -> Bool
  private let postOpenReadHook: @Sendable () -> Void

  public init(fileURL: URL) {
    self.fileURL = fileURL
    self.regularFileSync = { descriptor in
      MacOSFileDurability.fullSynchronizeRegularFile(descriptor)
    }
    self.postRenameDirectorySync = { descriptor in
      MacOSFileDurability.synchronizeDirectory(descriptor)
    }
    self.postOpenReadHook = {}
  }

  init(
    fileURL: URL,
    regularFileSync: @escaping @Sendable (Int32) -> Bool =
      { descriptor in MacOSFileDurability.fullSynchronizeRegularFile(descriptor) },
    postRenameDirectorySync: @escaping @Sendable (Int32) -> Bool,
    postOpenReadHook: @escaping @Sendable () -> Void = {}
  ) {
    self.fileURL = fileURL
    self.regularFileSync = regularFileSync
    self.postRenameDirectorySync = postRenameDirectorySync
    self.postOpenReadHook = postOpenReadHook
  }

  public func validate(
    _ config: NativeEndpointConfig,
    for serverOrigin: URL
  ) throws {
    let candidate = try Self.candidate(config, for: serverOrigin)
    return try withExclusiveFileLock {
      let document = try load()
      try Self.validate(candidate, against: document.records[candidate.origin])
    }
  }

  @discardableResult
  public func validateAndRecord(
    _ config: NativeEndpointConfig,
    for serverOrigin: URL
  ) throws -> EndpointConfigTrustCommitOutcome {
    try Task.checkCancellation()
    let candidate = try Self.candidate(config, for: serverOrigin)

    return try withExclusiveFileLock {
      try Task.checkCancellation()
      var document = try load()
      if let previous = document.records[candidate.origin] {
        try Self.validate(candidate, against: previous)
        if candidate.version == previous.version {
          // Visibility is not proof that the rename survived a crash. Always
          // re-run the directory barrier for an exact-record retry, including
          // after process relaunch when no in-memory uncertainty marker exists.
          return try synchronizeCurrentCommit()
        }
      } else {
        guard document.records.count < Self.maximumOrigins else {
          throw EndpointConfigTrustStoreError.invalidStore
        }
      }

      // Generation/server invalidation cancels the shared refresh task. Check
      // at the last side-effect-free boundary so a stale request cannot advance
      // the durable high-water mark while queued behind another file-lock user.
      try Task.checkCancellation()
      document.records[candidate.origin] = Record(
        version: candidate.version,
        digest: candidate.digest
      )
      return try persist(document)
    }
  }

  private func withExclusiveFileLock<T>(_ operation: () throws -> T) throws -> T {
    do {
      let directory = fileURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: directory.path
      )
      var directoryInfo = stat()
      guard lstat(directory.path, &directoryInfo) == 0,
        (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
        directoryInfo.st_uid == getuid(),
        (directoryInfo.st_mode & 0o077) == 0
      else {
        throw EndpointConfigTrustStoreError.unavailable
      }

      let lockURL = directory.appending(path: ".endpoint-config-trust.lock")
      let descriptor = Darwin.open(
        lockURL.path,
        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
        mode_t(S_IRUSR | S_IWUSR)
      )
      guard descriptor >= 0 else { throw EndpointConfigTrustStoreError.unavailable }
      defer { Darwin.close(descriptor) }
      var lockInfo = stat()
      guard fstat(descriptor, &lockInfo) == 0,
        (lockInfo.st_mode & S_IFMT) == S_IFREG,
        lockInfo.st_uid == getuid(),
        lockInfo.st_nlink == 1,
        fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0
      else {
        throw EndpointConfigTrustStoreError.unavailable
      }
      while endpointConfigFlock(descriptor, LOCK_EX) != 0 {
        guard errno == EINTR else { throw EndpointConfigTrustStoreError.unavailable }
      }
      defer { _ = endpointConfigFlock(descriptor, LOCK_UN) }
      return try operation()
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as EndpointConfigTrustStoreError {
      throw error
    } catch {
      throw EndpointConfigTrustStoreError.unavailable
    }
  }

  private func load() throws -> Document {
    do {
      let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      if descriptor < 0, errno == ENOENT {
        return Document(schemaVersion: 1, records: [:])
      }
      guard descriptor >= 0 else {
        throw EndpointConfigTrustStoreError.invalidStore
      }
      defer { Darwin.close(descriptor) }

      var before = stat()
      guard fstat(descriptor, &before) == 0,
        Self.isSecureTrustFile(before),
        before.st_size >= 0,
        before.st_size <= Self.maximumDocumentByteCount
      else {
        throw EndpointConfigTrustStoreError.invalidStore
      }
      postOpenReadHook()
      let data = try Self.readBounded(
        descriptor,
        maximumByteCount: Self.maximumDocumentByteCount
      )
      var after = stat()
      var path = stat()
      guard fstat(descriptor, &after) == 0,
        Self.sameReadIdentity(before, after),
        after.st_size == data.count,
        lstat(fileURL.path, &path) == 0,
        Self.samePublishedIdentity(after, path)
      else {
        throw EndpointConfigTrustStoreError.invalidStore
      }
      let document = try JSONDecoder().decode(Document.self, from: data)
      guard document.schemaVersion == 1,
        document.records.count <= Self.maximumOrigins,
        document.records.allSatisfy({ origin, record in
          SyncServerURL.validatedOrigin(origin)?.absoluteString == origin
            && (Self.minimumPersistedConfigVersion...NativeEndpointConfig.maximumConfigVersion)
              .contains(record.version)
            && record.digest.count == 64
            && record.digest.unicodeScalars.allSatisfy { scalar in
              (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
            }
        })
      else {
        throw EndpointConfigTrustStoreError.invalidStore
      }
      return document
    } catch let error as EndpointConfigTrustStoreError {
      throw error
    } catch {
      throw EndpointConfigTrustStoreError.invalidStore
    }
  }

  private static func isSecureTrustFile(_ metadata: stat) -> Bool {
    (metadata.st_mode & S_IFMT) == S_IFREG
      && metadata.st_uid == getuid()
      && metadata.st_nlink == 1
      && (metadata.st_mode & 0o077) == 0
  }

  private static func sameReadIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    isSecureTrustFile(rhs)
      && lhs.st_dev == rhs.st_dev
      && lhs.st_ino == rhs.st_ino
      && lhs.st_uid == rhs.st_uid
      && lhs.st_nlink == rhs.st_nlink
      && lhs.st_mode == rhs.st_mode
      && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  private static func samePublishedIdentity(_ descriptor: stat, _ path: stat) -> Bool {
    isSecureTrustFile(path)
      && descriptor.st_dev == path.st_dev
      && descriptor.st_ino == path.st_ino
      && descriptor.st_uid == path.st_uid
      && descriptor.st_nlink == path.st_nlink
      && descriptor.st_mode == path.st_mode
  }

  private static func readBounded(_ descriptor: Int32, maximumByteCount: Int) throws -> Data {
    var data = Data()
    data.reserveCapacity(min(maximumByteCount, 8_192))
    var buffer = [UInt8](repeating: 0, count: 8_192)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw EndpointConfigTrustStoreError.invalidStore }
      if count == 0 { return data }
      guard data.count <= maximumByteCount - count else {
        throw EndpointConfigTrustStoreError.invalidStore
      }
      data.append(buffer, count: count)
    }
  }

  private func persist(_ document: Document) throws -> EndpointConfigTrustCommitOutcome {
    do {
      let directory = fileURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: directory.path
      )
      let directoryDescriptor = Darwin.open(
        directory.path,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
      )
      guard directoryDescriptor >= 0 else { throw EndpointConfigTrustStoreError.unavailable }
      defer { Darwin.close(directoryDescriptor) }
      let data = try JSONEncoder.addressAtlas.encode(document)
      let temporaryURL = directory.appending(
        path: ".endpoint-config-trust.\(UUID().uuidString).tmp"
      )
      let descriptor = Darwin.open(
        temporaryURL.path,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        mode_t(S_IRUSR | S_IWUSR)
      )
      guard descriptor >= 0 else { throw EndpointConfigTrustStoreError.unavailable }
      var shouldRemoveTemporary = true
      defer {
        Darwin.close(descriptor)
        if shouldRemoveTemporary { _ = unlink(temporaryURL.path) }
      }
      try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var written = 0
        while written < rawBuffer.count {
          let count = Darwin.write(
            descriptor,
            baseAddress.advanced(by: written),
            rawBuffer.count - written
          )
          if count < 0, errno == EINTR { continue }
          guard count > 0 else { throw EndpointConfigTrustStoreError.unavailable }
          written += count
        }
      }
      guard let expectedIdentity = MacOSFileDurability.regularFileIdentity(descriptor),
        regularFileSync(descriptor)
      else {
        throw EndpointConfigTrustStoreError.unavailable
      }
      guard rename(temporaryURL.path, fileURL.path) == 0 else {
        throw EndpointConfigTrustStoreError.unavailable
      }
      shouldRemoveTemporary = false
      // rename(2) is the visibility commit point. The separate result prevents
      // callers from mistaking visibility for crash durability while also
      // avoiding the false claim that the already-published record rolled back.
      return synchronizePublishedFile(expectedIdentity: expectedIdentity)
        && postRenameDirectorySync(directoryDescriptor)
        ? .durable
        : .committedDurabilityUncertain
    } catch {
      throw EndpointConfigTrustStoreError.unavailable
    }
  }

  private func synchronizeCurrentCommit() throws -> EndpointConfigTrustCommitOutcome {
    let directory = fileURL.deletingLastPathComponent()
    let descriptor = Darwin.open(
      directory.path,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else { throw EndpointConfigTrustStoreError.unavailable }
    defer { Darwin.close(descriptor) }
    return synchronizePublishedFile(expectedIdentity: nil)
      && postRenameDirectorySync(descriptor)
      ? .durable
      : .committedDurabilityUncertain
  }

  private func synchronizePublishedFile(
    expectedIdentity: MacOSFileDurability.RegularFileIdentity?
  ) -> Bool {
    let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    guard let before = MacOSFileDurability.regularFileIdentity(descriptor),
      expectedIdentity == nil || before == expectedIdentity,
      regularFileSync(descriptor),
      let after = MacOSFileDurability.regularFileIdentity(descriptor),
      after == before
    else { return false }

    // Re-check the directory entry after the file barrier. A concurrent rename
    // must not let us certify a now-unreachable inode as the published record.
    var pathMetadata = stat()
    guard lstat(fileURL.path, &pathMetadata) == 0 else { return false }
    return pathMetadata.st_dev == after.device
      && pathMetadata.st_ino == after.inode
      && pathMetadata.st_uid == after.owner
      && pathMetadata.st_nlink == after.linkCount
      && pathMetadata.st_mode == after.mode
  }

  private static func digest(_ config: NativeEndpointConfig) throws -> String {
    let data = try JSONEncoder.addressAtlas.encode(config)
    return Data(SHA256.hash(data: data)).hexString
  }

  private static func candidate(
    _ config: NativeEndpointConfig,
    for serverOrigin: URL
  ) throws -> (origin: String, version: Int, digest: String) {
    guard let origin = SyncServerURL.validatedOrigin(serverOrigin.absoluteString) else {
      throw EndpointConfigTrustStoreError.invalidOrigin
    }
    return (
      origin.absoluteString,
      config.configVersion,
      try digest(config)
    )
  }

  private static func validate(
    _ candidate: (origin: String, version: Int, digest: String),
    against previous: Record?
  ) throws {
    guard let previous else { return }
    guard candidate.version >= previous.version else {
      throw EndpointConfigTrustStoreError.rollback(
        previous: previous.version,
        received: candidate.version
      )
    }
    guard candidate.version != previous.version || candidate.digest == previous.digest else {
      throw EndpointConfigTrustStoreError.equivocation(version: candidate.version)
    }
  }
}

/// Deterministic test/default seam for callers that intentionally do not want
/// filesystem state. Production AppState installs EndpointConfigTrustStore.
public actor EphemeralEndpointConfigTrustStore: EndpointConfigTrustPersisting {
  private var records: [String: (version: Int, digest: String)] = [:]

  public init() {}

  public func validate(
    _ config: NativeEndpointConfig,
    for serverOrigin: URL
  ) throws {
    let candidate = try Self.candidate(config, for: serverOrigin)
    try Self.validate(candidate, against: records[candidate.origin])
  }

  @discardableResult
  public func validateAndRecord(
    _ config: NativeEndpointConfig,
    for serverOrigin: URL
  ) throws -> EndpointConfigTrustCommitOutcome {
    try Task.checkCancellation()
    let candidate = try Self.candidate(config, for: serverOrigin)
    try Self.validate(candidate, against: records[candidate.origin])
    try Task.checkCancellation()
    records[candidate.origin] = (candidate.version, candidate.digest)
    return .durable
  }

  private static func candidate(
    _ config: NativeEndpointConfig,
    for serverOrigin: URL
  ) throws -> (origin: String, version: Int, digest: String) {
    guard let origin = SyncServerURL.validatedOrigin(serverOrigin.absoluteString) else {
      throw EndpointConfigTrustStoreError.invalidOrigin
    }
    let data = try JSONEncoder.addressAtlas.encode(config)
    return (
      origin.absoluteString,
      config.configVersion,
      Data(SHA256.hash(data: data)).hexString
    )
  }

  private static func validate(
    _ candidate: (origin: String, version: Int, digest: String),
    against previous: (version: Int, digest: String)?
  ) throws {
    guard let previous else { return }
    guard candidate.version >= previous.version else {
      throw EndpointConfigTrustStoreError.rollback(
        previous: previous.version,
        received: candidate.version
      )
    }
    guard candidate.version != previous.version || candidate.digest == previous.digest else {
      throw EndpointConfigTrustStoreError.equivocation(version: candidate.version)
    }
  }
}
