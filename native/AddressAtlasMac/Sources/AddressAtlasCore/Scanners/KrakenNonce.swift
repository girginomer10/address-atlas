import CryptoKit
import Darwin
import Foundation

// Swift's Darwin overlay exposes struct flock but not the same-named BSD
// function on every toolchain. Bind the stable libc symbol explicitly.
@_silgen_name("flock")
private func addressAtlasFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

public enum KrakenNonceError: Error, Equatable, LocalizedError, Sendable {
  case invalidClock
  case exhausted
  case localStateUnavailable
  case localStateChanged

  public var errorDescription: String? {
    switch self {
    case .invalidClock:
      return
        "The system clock cannot produce a safe Kraken nonce. Correct the Mac's date and time before retrying."
    case .exhausted:
      return
        "The Kraken nonce range is exhausted for this API key. Create a new read-only Kraken API key."
    case .localStateUnavailable:
      return "Kraken's protected local nonce state is unavailable. No Kraken request was sent."
    case .localStateChanged:
      return
        "Kraken's local device state changed. Remove this connection and add a new read-only Kraken API key created only for this Mac."
    }
  }
}

protocol KrakenInstallationSecretStore: Sendable {
  func loadSecret() throws -> Data?
  /// Atomically installs the first secret or returns the value installed by a
  /// competing process. Implementations must never replace an existing value.
  func saveSecretIfAbsent(_ secret: Data) throws -> Data
}

/// The Kraken state-binding key is deliberately separate from both the vault
/// key and the cloneable Application Support state. The underlying Keychain
/// item is `WhenUnlockedThisDeviceOnly`, so it is neither synced nor restored
/// onto a different Mac. No per-request user-presence prompt is used because
/// scans can run unattended while the user's login session is unlocked.
private struct KeychainKrakenInstallationSecretStore: KrakenInstallationSecretStore {
  private let backingStore = KeychainVaultKeyStore(
    service: "com.addressatlas.mac.kraken-installation",
    account: "nonce-state-binding-v1"
  )

  func loadSecret() throws -> Data? {
    try backingStore.loadVaultKey()
  }

  func saveSecretIfAbsent(_ secret: Data) throws -> Data {
    try backingStore.saveVaultKeyIfAbsent(secret)
  }
}

public enum KrakenDeviceIdentity {
  public static func currentIdentifier(
    storageURL: URL = KrakenNonceGenerator.defaultStorageURL
  ) throws -> String {
    try currentIdentifier(
      storageURL: storageURL,
      installationSecretStore: KeychainKrakenInstallationSecretStore()
    )
  }

  static func currentIdentifier(
    storageURL: URL,
    installationSecretStore: any KrakenInstallationSecretStore
  ) throws -> String {
    do {
      return try KrakenLocalNonceStore.withLockedState(
        at: storageURL,
        installationSecretStore: installationSecretStore
      ) { state, _ in
        state.deviceIdentifier
      }
    } catch let error as KrakenNonceError {
      throw error
    } catch {
      throw KrakenNonceError.localStateUnavailable
    }
  }

  public static func normalizedIdentifier(_ candidate: String) -> String? {
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count == 36,
      let parsed = UUID(uuidString: trimmed),
      parsed.uuidString.lowercased() == trimmed.lowercased()
    else { return nil }
    return parsed.uuidString.lowercased()
  }
}

/// Kraken requires a strictly increasing nonce per API key. Every update is
/// serialized across processes with `flock` and durably replaced before the
/// signed request is allowed to leave the process. A device-only Keychain
/// secret authenticates the cloneable state file and derives its opaque
/// HMAC(apiKey) identifiers; neither the secret nor an API key is stored there.
public actor KrakenNonceGenerator {
  public static var defaultStorageURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "AddressAtlas", directoryHint: .isDirectory)
      .appending(path: "kraken-nonce-state.json")
  }

  public static let shared = KrakenNonceGenerator(storageURL: defaultStorageURL)
  private let storageURL: URL
  private let installationSecretStore: any KrakenInstallationSecretStore

  public init(storageURL: URL = KrakenNonceGenerator.defaultStorageURL) {
    self.storageURL = storageURL
    self.installationSecretStore = KeychainKrakenInstallationSecretStore()
  }

  init(
    storageURL: URL,
    installationSecretStore: any KrakenInstallationSecretStore
  ) {
    self.storageURL = storageURL
    self.installationSecretStore = installationSecretStore
  }

  public func deviceIdentifier() throws -> String {
    try KrakenDeviceIdentity.currentIdentifier(
      storageURL: storageURL,
      installationSecretStore: installationSecretStore
    )
  }

  func next(
    apiKey: String,
    at date: Date,
    expectedDeviceIdentifier: String? = nil
  ) throws -> String {
    let rawMilliseconds = date.timeIntervalSince1970 * 1_000
    guard rawMilliseconds.isFinite,
      rawMilliseconds > 0,
      rawMilliseconds < Double(Int64.max)
    else {
      throw KrakenNonceError.invalidClock
    }
    let currentMilliseconds = Int64(rawMilliseconds.rounded(.down))

    do {
      return try KrakenLocalNonceStore.withLockedState(
        at: storageURL,
        installationSecretStore: installationSecretStore
      ) { state, installationSecret in
        if let expectedDeviceIdentifier {
          guard
            KrakenDeviceIdentity.normalizedIdentifier(expectedDeviceIdentifier)
              == state.deviceIdentifier
          else {
            throw KrakenNonceError.localStateChanged
          }
        }
        let identifier = try state.credentialIdentifier(
          for: apiKey,
          installationSecret: installationSecret
        )
        let previous = state.lastNonceByCredential[identifier].flatMap(Int64.init)
        guard
          previous != nil
            || state.lastNonceByCredential.count < KrakenLocalNonceState.maximumCredentialCount
        else {
          throw KrakenNonceError.localStateUnavailable
        }
        let next: Int64
        if let previous, previous >= currentMilliseconds {
          guard previous < Int64.max else { throw KrakenNonceError.exhausted }
          next = previous + 1
        } else {
          next = currentMilliseconds
        }
        state.lastNonceByCredential[identifier] = String(next)
        return String(next)
      }
    } catch let error as KrakenNonceError {
      throw error
    } catch {
      throw KrakenNonceError.localStateUnavailable
    }
  }
}

private struct KrakenLocalNonceState: Codable {
  static let currentVersion = 2
  static let maximumCredentialCount = 1_024
  static let installationSecretByteCount = 32

  var version: Int
  var deviceIdentifier: String
  var lastNonceByCredential: [String: String]
  var installationBinding: String

  static func makeNew(installationSecret: Data) throws -> Self {
    var state = Self(
      version: currentVersion,
      deviceIdentifier: UUID().uuidString.lowercased(),
      lastNonceByCredential: [:],
      installationBinding: ""
    )
    try state.reseal(using: installationSecret)
    return state
  }

  func validated(using installationSecret: Data) throws -> Self {
    guard version == Self.currentVersion,
      KrakenDeviceIdentity.normalizedIdentifier(deviceIdentifier) == deviceIdentifier,
      installationSecret.count == Self.installationSecretByteCount,
      lastNonceByCredential.count <= Self.maximumCredentialCount,
      lastNonceByCredential.allSatisfy({ key, value in
        key.utf8.count == 64 && key.utf8.allSatisfy(Self.isLowercaseHex)
          && Int64(value).map { $0 >= 0 } == true
      }),
      let binding = Data(base64Encoded: installationBinding),
      binding.count == SHA256.Digest.byteCount,
      HMAC<SHA256>.isValidAuthenticationCode(
        binding,
        authenticating: bindingPayload(),
        using: SymmetricKey(data: installationSecret)
      )
    else {
      throw KrakenNonceError.localStateUnavailable
    }
    return self
  }

  func credentialIdentifier(
    for apiKey: String,
    installationSecret: Data
  ) throws -> String {
    guard installationSecret.count == Self.installationSecretByteCount else {
      throw KrakenNonceError.localStateUnavailable
    }
    var authenticatedData = Data("address-atlas.kraken.credential-id.v1\0".utf8)
    authenticatedData.append(Data(apiKey.utf8))
    let code = HMAC<SHA256>.authenticationCode(
      for: authenticatedData,
      using: SymmetricKey(data: installationSecret)
    )
    return Self.lowercaseHex(code)
  }

  mutating func reseal(using installationSecret: Data) throws {
    guard installationSecret.count == Self.installationSecretByteCount else {
      throw KrakenNonceError.localStateUnavailable
    }
    installationBinding = Data(
      HMAC<SHA256>.authenticationCode(
        for: bindingPayload(),
        using: SymmetricKey(data: installationSecret)
      )
    ).base64EncodedString()
  }

  private func bindingPayload() -> Data {
    var payload = Data("address-atlas.kraken.nonce-state.v2\0".utf8)
    Self.appendLengthPrefixed(Data(deviceIdentifier.utf8), to: &payload)
    for (identifier, nonce) in lastNonceByCredential.sorted(by: { $0.key < $1.key }) {
      Self.appendLengthPrefixed(Data(identifier.utf8), to: &payload)
      Self.appendLengthPrefixed(Data(nonce.utf8), to: &payload)
    }
    return payload
  }

  private static func appendLengthPrefixed(_ value: Data, to payload: inout Data) {
    var length = UInt64(value.count).bigEndian
    withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
    payload.append(value)
  }

  private static func lowercaseHex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    let hex = Array("0123456789abcdef".utf8)
    return bytes.reduce(into: "") { result, byte in
      result.append(Character(UnicodeScalar(hex[Int(byte >> 4)])))
      result.append(Character(UnicodeScalar(hex[Int(byte & 0x0f)])))
    }
  }

  private static func isLowercaseHex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...102).contains(byte)
  }
}

/// Version 1 put the installation UUID, the credential HMAC key, and every
/// nonce into the same copyable JSON object. It can be parsed only so migration
/// can fail closed by rotating to a fresh v2 identity; none of its identity or
/// nonce material is ever trusted or carried forward.
private struct KrakenLegacyLocalNonceStateV1: Decodable {
  var version: Int
  var deviceIdentifier: String
  var credentialIdentifierKey: String
  var lastNonceByCredential: [String: String]

  func validateForDiscard() throws {
    guard version == 1,
      KrakenDeviceIdentity.normalizedIdentifier(deviceIdentifier) == deviceIdentifier,
      Data(base64Encoded: credentialIdentifierKey)?.count == 32,
      lastNonceByCredential.count <= KrakenLocalNonceState.maximumCredentialCount,
      lastNonceByCredential.allSatisfy({ key, value in
        key.utf8.count == 64
          && key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
          && Int64(value).map { $0 >= 0 } == true
      })
    else { throw KrakenNonceError.localStateUnavailable }
  }
}

private struct KrakenLocalNonceStateVersion: Decodable {
  var version: Int
}

private enum KrakenLocalNonceStore {
  private static let maximumEncodedByteCount = 256 * 1_024

  static func withLockedState<T>(
    at storageURL: URL,
    installationSecretStore: any KrakenInstallationSecretStore,
    _ update: (inout KrakenLocalNonceState, Data) throws -> T
  ) throws -> T {
    let directoryURL = storageURL.deletingLastPathComponent()
    try prepareDirectory(directoryURL)
    let lockURL = storageURL.appendingPathExtension("lock")
    let lockDescriptor = lockURL.path.withCString {
      Darwin.open($0, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    }
    guard lockDescriptor >= 0 else { throw KrakenNonceError.localStateUnavailable }
    defer { Darwin.close(lockDescriptor) }
    guard isOwnedRegularFile(lockDescriptor),
      Darwin.fchmod(lockDescriptor, S_IRUSR | S_IWUSR) == 0
    else { throw KrakenNonceError.localStateUnavailable }
    while addressAtlasFlock(lockDescriptor, LOCK_EX) != 0 {
      guard errno == EINTR else { throw KrakenNonceError.localStateUnavailable }
    }
    defer { _ = addressAtlasFlock(lockDescriptor, LOCK_UN) }

    var metadata = stat()
    let statePathStatus = storageURL.path.withCString { Darwin.lstat($0, &metadata) }
    let installationSecret: Data
    var state: KrakenLocalNonceState
    var requiresInitialWrite = false
    if statePathStatus == 0 {
      guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
        metadata.st_uid == geteuid(),
        metadata.st_nlink == 1
      else { throw KrakenNonceError.localStateUnavailable }
      let data = try readBoundedState(at: storageURL)
      if let version = try? JSONDecoder().decode(KrakenLocalNonceStateVersion.self, from: data)
        .version
      {
        switch version {
        case KrakenLocalNonceState.currentVersion:
          if let existingSecret = try installationSecretStore.loadSecret() {
            guard existingSecret.count == KrakenLocalNonceState.installationSecretByteCount else {
              throw KrakenNonceError.localStateUnavailable
            }
            installationSecret = existingSecret
            do {
              state = try JSONDecoder().decode(KrakenLocalNonceState.self, from: data)
                .validated(using: installationSecret)
            } catch {
              // A regular, owner-only v2 file that cannot authenticate with this
              // device-only secret is copied, corrupt, or tampered state. It can
              // never be trusted for nonces. Replace it with a fresh identity,
              // then let the expected-identifier check reject every saved old
              // connection before HTTP. Files that fail type/owner/link checks
              // never reach this branch and are not replaced.
              state = try .makeNew(installationSecret: installationSecret)
              requiresInitialWrite = true
            }
          } else {
            // `nil` means Keychain returned the precise item-not-found status;
            // thrown access/decoding errors never enter this recovery path. The
            // old authenticated state is unusable without its secret, so rotate
            // both identity and nonce material. Persist the replacement before
            // installing its secret and before the caller can compare an expected
            // old identifier. A crash or Keychain failure therefore cannot send a
            // request under the old binding, and a later retry can rotate again.
            let replacement = try rotateAfterConfirmedMissingSecret(
              at: storageURL,
              in: installationSecretStore
            )
            state = replacement.0
            installationSecret = replacement.1
          }
        case 1:
          let legacy = try JSONDecoder().decode(KrakenLegacyLocalNonceStateV1.self, from: data)
          try legacy.validateForDiscard()
          installationSecret = try loadOrCreateSecret(in: installationSecretStore)
          state = try .makeNew(installationSecret: installationSecret)
          requiresInitialWrite = true
        default:
          // Preserve a structurally versioned future state for a newer app.
          throw KrakenNonceError.localStateUnavailable
        }
      } else if let existingSecret = try installationSecretStore.loadSecret() {
        guard existingSecret.count == KrakenLocalNonceState.installationSecretByteCount else {
          throw KrakenNonceError.localStateUnavailable
        }
        installationSecret = existingSecret
        state = try .makeNew(installationSecret: installationSecret)
        requiresInitialWrite = true
      } else {
        // An unreadable owner-only state plus a confirmed missing Keychain item
        // has no recoverable identity or nonce material. Apply the same safe
        // pre-comparison rotation used for an unreadable v2 binding.
        let replacement = try rotateAfterConfirmedMissingSecret(
          at: storageURL,
          in: installationSecretStore
        )
        state = replacement.0
        installationSecret = replacement.1
      }
    } else if errno == ENOENT {
      installationSecret = try loadOrCreateSecret(in: installationSecretStore)
      state = try .makeNew(installationSecret: installationSecret)
      requiresInitialWrite = true
    } else {
      throw KrakenNonceError.localStateUnavailable
    }

    // Persist a newly created or safely rotated identity before evaluating an
    // expected old device identifier. If that comparison fails, retries see
    // the same replacement identity instead of generating a new one each time.
    if requiresInitialWrite {
      try writeAtomicallyAndDurably(state, to: storageURL)
    }

    let result = try update(&state, installationSecret)
    try state.reseal(using: installationSecret)
    try writeAtomicallyAndDurably(state, to: storageURL)
    return result
  }

  private static func loadOrCreateSecret(
    in store: any KrakenInstallationSecretStore
  ) throws -> Data {
    if let existing = try store.loadSecret() {
      guard existing.count == KrakenLocalNonceState.installationSecretByteCount else {
        throw KrakenNonceError.localStateUnavailable
      }
      return existing
    }
    let generated = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    let installed = try store.saveSecretIfAbsent(generated)
    guard installed.count == KrakenLocalNonceState.installationSecretByteCount else {
      throw KrakenNonceError.localStateUnavailable
    }
    return installed
  }

  private static func rotateAfterConfirmedMissingSecret(
    at storageURL: URL,
    in store: any KrakenInstallationSecretStore
  ) throws -> (KrakenLocalNonceState, Data) {
    let candidate = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    var state = try KrakenLocalNonceState.makeNew(installationSecret: candidate)

    // Write first. If the process stops before the Keychain insert, the next
    // exact item-not-found result safely replaces this unusable candidate state.
    // Installing the secret first would leave the old v2 file permanently
    // indistinguishable from a copied/tampered file if the state write failed.
    try writeAtomicallyAndDurably(state, to: storageURL)

    let installed = try store.saveSecretIfAbsent(candidate)
    guard installed.count == KrakenLocalNonceState.installationSecretByteCount else {
      throw KrakenNonceError.localStateUnavailable
    }
    if installed != candidate {
      // A competing process may have won the atomic Keychain insert. Bind a new
      // identity to the winner and persist it before returning to the caller.
      state = try .makeNew(installationSecret: installed)
      try writeAtomicallyAndDurably(state, to: storageURL)
    }
    return (state, installed)
  }

  private static func prepareDirectory(_ directoryURL: URL) throws {
    var metadata = stat()
    let status = directoryURL.path.withCString { Darwin.lstat($0, &metadata) }
    if status == 0 {
      guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
        metadata.st_uid == geteuid()
      else { throw KrakenNonceError.localStateUnavailable }
    } else if errno == ENOENT {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } else {
      throw KrakenNonceError.localStateUnavailable
    }

    let descriptor = directoryURL.path.withCString {
      Darwin.open($0, O_RDONLY | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw KrakenNonceError.localStateUnavailable }
    defer { Darwin.close(descriptor) }
    var openedMetadata = stat()
    guard Darwin.fstat(descriptor, &openedMetadata) == 0,
      (openedMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
      openedMetadata.st_uid == geteuid(),
      Darwin.fchmod(descriptor, 0o700) == 0
    else { throw KrakenNonceError.localStateUnavailable }
  }

  private static func readBoundedState(at storageURL: URL) throws -> Data {
    let descriptor = storageURL.path.withCString {
      Darwin.open($0, O_RDONLY | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw KrakenNonceError.localStateUnavailable }
    defer { Darwin.close(descriptor) }
    guard isOwnedRegularFile(descriptor), Darwin.fchmod(descriptor, 0o600) == 0 else {
      throw KrakenNonceError.localStateUnavailable
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw KrakenNonceError.localStateUnavailable }
      guard count > 0 else { break }
      guard data.count <= maximumEncodedByteCount - count else {
        throw KrakenNonceError.localStateUnavailable
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    return data
  }

  private static func isOwnedRegularFile(_ descriptor: Int32) -> Bool {
    var metadata = stat()
    return Darwin.fstat(descriptor, &metadata) == 0
      && (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
      && metadata.st_uid == geteuid()
      && metadata.st_nlink == 1
  }

  private static func writeAtomicallyAndDurably(
    _ state: KrakenLocalNonceState,
    to storageURL: URL
  ) throws {
    let data = try JSONEncoder().encode(state)
    guard data.count <= maximumEncodedByteCount else {
      throw KrakenNonceError.localStateUnavailable
    }
    let temporaryURL = storageURL.deletingLastPathComponent().appending(
      path: ".\(storageURL.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp"
    )
    let temporaryDescriptor = temporaryURL.path.withCString {
      Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    }
    guard temporaryDescriptor >= 0 else { throw KrakenNonceError.localStateUnavailable }
    var shouldRemoveTemporary = true
    defer {
      Darwin.close(temporaryDescriptor)
      if shouldRemoveTemporary { try? FileManager.default.removeItem(at: temporaryURL) }
    }

    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      var offset = 0
      while offset < rawBuffer.count {
        let written = Darwin.write(
          temporaryDescriptor,
          baseAddress.advanced(by: offset),
          rawBuffer.count - offset
        )
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { throw KrakenNonceError.localStateUnavailable }
        offset += written
      }
    }
    guard Darwin.fsync(temporaryDescriptor) == 0 else {
      throw KrakenNonceError.localStateUnavailable
    }
    guard
      temporaryURL.path.withCString({ temporaryPath in
        storageURL.path.withCString { storagePath in
          Darwin.rename(temporaryPath, storagePath)
        }
      }) == 0
    else {
      throw KrakenNonceError.localStateUnavailable
    }
    shouldRemoveTemporary = false

    let directoryDescriptor = storageURL.deletingLastPathComponent().path.withCString {
      Darwin.open($0, O_RDONLY | O_NOFOLLOW)
    }
    guard directoryDescriptor >= 0 else { throw KrakenNonceError.localStateUnavailable }
    defer { Darwin.close(directoryDescriptor) }
    guard Darwin.fsync(directoryDescriptor) == 0 || errno == EINVAL else {
      throw KrakenNonceError.localStateUnavailable
    }
  }
}
