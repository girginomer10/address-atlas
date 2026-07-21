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
  private let fileURL: URL
  private let postRenameDirectorySync: @Sendable (Int32) -> Bool

  public init(fileURL: URL) {
    self.fileURL = fileURL
    self.postRenameDirectorySync = { descriptor in
      Self.synchronizeDirectory(descriptor)
    }
  }

  init(
    fileURL: URL,
    postRenameDirectorySync: @escaping @Sendable (Int32) -> Bool
  ) {
    self.fileURL = fileURL
    self.postRenameDirectorySync = postRenameDirectorySync
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
          return try synchronizeCurrentDirectory()
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
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return Document(schemaVersion: 1, records: [:])
    }
    do {
      var fileInfo = stat()
      guard lstat(fileURL.path, &fileInfo) == 0,
        (fileInfo.st_mode & S_IFMT) == S_IFREG,
        fileInfo.st_uid == getuid(),
        fileInfo.st_nlink == 1,
        (fileInfo.st_mode & 0o077) == 0
      else {
        throw EndpointConfigTrustStoreError.invalidStore
      }
      let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
      if let size = attributes[.size] as? NSNumber, size.intValue > 128_000 {
        throw EndpointConfigTrustStoreError.invalidStore
      }
      let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
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
      guard Darwin.fsync(descriptor) == 0,
        rename(temporaryURL.path, fileURL.path) == 0
      else {
        throw EndpointConfigTrustStoreError.unavailable
      }
      shouldRemoveTemporary = false
      // rename(2) is the visibility commit point. The separate result prevents
      // callers from mistaking visibility for crash durability while also
      // avoiding the false claim that the already-published record rolled back.
      return postRenameDirectorySync(directoryDescriptor)
        ? .durable
        : .committedDurabilityUncertain
    } catch {
      throw EndpointConfigTrustStoreError.unavailable
    }
  }

  private func synchronizeCurrentDirectory() throws -> EndpointConfigTrustCommitOutcome {
    let directory = fileURL.deletingLastPathComponent()
    let descriptor = Darwin.open(
      directory.path,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else { throw EndpointConfigTrustStoreError.unavailable }
    defer { Darwin.close(descriptor) }
    return postRenameDirectorySync(descriptor)
      ? .durable
      : .committedDurabilityUncertain
  }

  private static func synchronizeDirectory(_ descriptor: Int32) -> Bool {
    while Darwin.fsync(descriptor) != 0 {
      if errno == EINTR { continue }
      return errno == EINVAL
    }
    return true
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
