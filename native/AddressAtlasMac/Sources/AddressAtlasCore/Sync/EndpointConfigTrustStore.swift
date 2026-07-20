import CryptoKit
import Darwin
import Foundation

@_silgen_name("flock")
private func endpointConfigFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

public protocol EndpointConfigTrustPersisting: Sendable {
  /// Atomically verifies and advances the per-origin endpoint-config high-water
  /// mark. A return means the config may be applied; every storage, rollback,
  /// or equivocation failure must be treated as a fail-closed rejection.
  func validateAndRecord(_ config: NativeEndpointConfig, for serverOrigin: URL) async throws
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

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func validateAndRecord(
    _ config: NativeEndpointConfig,
    for serverOrigin: URL
  ) throws {
    guard let origin = SyncServerURL.validatedOrigin(serverOrigin.absoluteString) else {
      throw EndpointConfigTrustStoreError.invalidOrigin
    }
    let originKey = origin.absoluteString
    let digest = try Self.digest(config)

    try withExclusiveFileLock {
      var document = try load()
      if let previous = document.records[originKey] {
        guard config.configVersion >= previous.version else {
          throw EndpointConfigTrustStoreError.rollback(
            previous: previous.version,
            received: config.configVersion
          )
        }
        guard config.configVersion != previous.version || digest == previous.digest else {
          throw EndpointConfigTrustStoreError.equivocation(version: config.configVersion)
        }
        if config.configVersion == previous.version {
          return
        }
      } else {
        guard document.records.count < Self.maximumOrigins else {
          throw EndpointConfigTrustStoreError.invalidStore
        }
      }

      document.records[originKey] = Record(version: config.configVersion, digest: digest)
      try persist(document)
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

  private func persist(_ document: Document) throws {
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
      let directoryDescriptor = Darwin.open(
        directory.path,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
      )
      guard directoryDescriptor >= 0 else { throw EndpointConfigTrustStoreError.unavailable }
      defer { Darwin.close(directoryDescriptor) }
      guard Darwin.fsync(directoryDescriptor) == 0 || errno == EINVAL else {
        throw EndpointConfigTrustStoreError.unavailable
      }
    } catch {
      throw EndpointConfigTrustStoreError.unavailable
    }
  }

  private static func digest(_ config: NativeEndpointConfig) throws -> String {
    let data = try JSONEncoder.addressAtlas.encode(config)
    return Data(SHA256.hash(data: data)).hexString
  }
}

/// Deterministic test/default seam for callers that intentionally do not want
/// filesystem state. Production AppState installs EndpointConfigTrustStore.
public actor EphemeralEndpointConfigTrustStore: EndpointConfigTrustPersisting {
  private var records: [String: (version: Int, digest: String)] = [:]

  public init() {}

  public func validateAndRecord(
    _ config: NativeEndpointConfig,
    for serverOrigin: URL
  ) throws {
    guard let origin = SyncServerURL.validatedOrigin(serverOrigin.absoluteString) else {
      throw EndpointConfigTrustStoreError.invalidOrigin
    }
    let data = try JSONEncoder.addressAtlas.encode(config)
    let digest = Data(SHA256.hash(data: data)).hexString
    if let previous = records[origin.absoluteString] {
      guard config.configVersion >= previous.version else {
        throw EndpointConfigTrustStoreError.rollback(
          previous: previous.version, received: config.configVersion)
      }
      guard config.configVersion != previous.version || digest == previous.digest else {
        throw EndpointConfigTrustStoreError.equivocation(version: config.configVersion)
      }
    }
    records[origin.absoluteString] = (config.configVersion, digest)
  }
}
