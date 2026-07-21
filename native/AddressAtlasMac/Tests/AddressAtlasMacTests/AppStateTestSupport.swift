import AddressAtlasCore
import Foundation
import XCTest

@testable import AddressAtlasMac

func testSessionToken(
  accountId: String,
  sessionId: String = "99999999-9999-4999-8999-999999999999"
) -> String {
  let issuedAt = Int64(Date().timeIntervalSince1970 * 1_000) - 1_000
  let payload: [String: Any] = [
    "userId": accountId,
    "sessionId": sessionId,
    "issuedAt": issuedAt,
    "expiresAt": issuedAt + SyncSessionToken.maximumLifetimeMilliseconds,
  ]
  let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
  return "v1.session.\(Base64URL.encode(data)).\(Base64URL.encode(Data(repeating: 0x5A, count: 32)))"
}

func testExpiredSessionToken(
  accountId: String,
  sessionId: String = "88888888-8888-4888-8888-888888888888"
) -> String {
  let expiresAt = Int64(Date().timeIntervalSince1970 * 1_000) - 1_000
  let payload: [String: Any] = [
    "userId": accountId,
    "sessionId": sessionId,
    "issuedAt": expiresAt - SyncSessionToken.maximumLifetimeMilliseconds,
    "expiresAt": expiresAt,
  ]
  let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
  return "v1.session.\(Base64URL.encode(data)).\(Base64URL.encode(Data(repeating: 0x5A, count: 32)))"
}

/// Produces a sizeable warning fixture that is already in the canonical form
/// accepted at the strict persistence boundary. Repeated single-character
/// strings look like opaque secrets to the production sanitizer and are
/// intentionally unsuitable as fixtures.
func testCanonicalWarnings(totalLength: Int) -> [String] {
  var remaining = max(0, totalLength)
  var index = 0
  var warnings: [String] = []
  while remaining > 0 {
    let prefix = "warning \(index): "
    let chunk = min(300, remaining)
    let wordCount = max(1, (chunk - prefix.count + 1) / 2)
    warnings.append(prefix + Array(repeating: "x", count: wordCount).joined(separator: " "))
    remaining -= chunk
    index += 1
  }
  return warnings
}

/// Builds the authenticated predecessor metadata carried inside a snapshot.
/// A top-level snapshot at version N must contain a document whose last
/// confirmed remote version is exactly N - 1.
func testDocumentWithRemoteBaseline(
  _ document: VaultDocument,
  accountId: String,
  priorVersion: Int
) -> VaultDocument {
  var result = document
  result.syncState = SyncState(
    accountId: accountId,
    latestRemoteVersion: priorVersion,
    lastSyncedAt: priorVersion == 0 ? nil : Date(timeIntervalSince1970: 1_700_000_000),
    lastChecksum: priorVersion == 0 ? nil : String(repeating: "a", count: 64)
  )
  return result
}

actor CountingEndpointConfigClient: EndpointConfigFetching {
  let config: NativeEndpointConfig
  private(set) var requestCount = 0

  init(config: NativeEndpointConfig) {
    self.config = config
  }

  func fetch(from serverURL: URL) async throws -> NativeEndpointConfig {
    requestCount += 1
    try await Task.sleep(for: .milliseconds(20))
    return config
  }
}

/// Exercises the real AppState orchestration glue (encrypt/decode/persist/merge)
/// with stubs installed only at the HTTP transport boundary.

struct FixedEndpointConfigClient: EndpointConfigFetching {
  var config: NativeEndpointConfig

  func fetch(from serverURL: URL) async throws -> NativeEndpointConfig {
    config
  }
}

struct FailingEndpointConfigClient: EndpointConfigFetching {
  var code: URLError.Code = .cannotConnectToHost

  func fetch(from serverURL: URL) async throws -> NativeEndpointConfig {
    throw URLError(code)
  }
}

actor FirstSuccessThenFailureEndpointConfigClient: EndpointConfigFetching {
  private let config: NativeEndpointConfig
  private var returnedConfig = false

  init(config: NativeEndpointConfig) {
    self.config = config
  }

  func fetch(from _: URL) async throws -> NativeEndpointConfig {
    guard !returnedConfig else { throw URLError(.cannotConnectToHost) }
    returnedConfig = true
    return config
  }
}

actor ScriptedEndpointConfigTrustStore: EndpointConfigTrustPersisting {
  private var outcomes: [EndpointConfigTrustCommitOutcome]
  private(set) var recordCount = 0

  init(_ outcomes: [EndpointConfigTrustCommitOutcome]) {
    self.outcomes = outcomes
  }

  func validate(_: NativeEndpointConfig, for _: URL) async throws {}

  func validateAndRecord(
    _: NativeEndpointConfig,
    for _: URL
  ) async throws -> EndpointConfigTrustCommitOutcome {
    recordCount += 1
    return outcomes.isEmpty ? .durable : outcomes.removeFirst()
  }
}

actor FailingRecordEndpointConfigTrustStore: EndpointConfigTrustPersisting {
  func validate(_: NativeEndpointConfig, for _: URL) async throws {}

  func validateAndRecord(
    _: NativeEndpointConfig,
    for _: URL
  ) async throws -> EndpointConfigTrustCommitOutcome {
    throw EndpointConfigTrustStoreError.unavailable
  }
}

final class AppStateTestVaultKeyStore: VaultKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var key: Data?

  init(key: Data? = nil) {
    self.key = key
  }

  func loadVaultKey() throws -> Data? {
    lock.withLock { key }
  }

  func saveVaultKey(_ key: Data) throws {
    lock.withLock { self.key = key }
  }

  func saveVaultKeyIfAbsent(_ key: Data) throws -> Data {
    lock.withLock {
      if let existing = self.key { return existing }
      self.key = key
      return key
    }
  }

  func deleteVaultKey() throws {
    lock.withLock { key = nil }
  }
}

actor RecoverableVaultHTTPState {
  enum PutBehavior: Sendable {
    case accept
    case commitThenTimeout
    case timeoutBeforeCommit
    case reject503
  }

  private var remoteSnapshot: RemoteVaultSnapshot?
  private var putBehaviors: [PutBehavior]
  private var receivedSnapshots: [RemoteVaultSnapshot] = []

  init(
    remoteSnapshot: RemoteVaultSnapshot? = nil,
    putBehaviors: [PutBehavior] = []
  ) {
    self.remoteSnapshot = remoteSnapshot
    self.putBehaviors = putBehaviors
  }

  func handle(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
    guard request.url?.path == "/vault/latest" else {
      throw URLError(.unsupportedURL)
    }
    if request.httpMethod == "GET" {
      guard let remoteSnapshot else {
        return stubJSONResponse(request, #"{"error":"vault not found"}"#, statusCode: 404)
      }
      return (
        try JSONEncoder.addressAtlas.encode(remoteSnapshot),
        stubHTTPResponse(request)
      )
    }
    guard request.httpMethod == "PUT", let body = request.httpBody else {
      throw URLError(.badServerResponse)
    }
    let snapshot = try JSONDecoder.addressAtlas.decode(RemoteVaultSnapshot.self, from: body)
    receivedSnapshots.append(snapshot)
    let behavior = putBehaviors.isEmpty ? PutBehavior.accept : putBehaviors.removeFirst()
    switch behavior {
    case .accept:
      remoteSnapshot = snapshot
      return stubJSONResponse(request, #"{"ok":true}"#)
    case .commitThenTimeout:
      remoteSnapshot = snapshot
      throw URLError(.timedOut)
    case .timeoutBeforeCommit:
      throw URLError(.timedOut)
    case .reject503:
      return stubJSONResponse(
        request,
        #"{"error":"Upload temporarily unavailable."}"#,
        statusCode: 503
      )
    }
  }

  func replaceRemote(with snapshot: RemoteVaultSnapshot?) {
    remoteSnapshot = snapshot
  }

  func snapshotsReceived() -> [RemoteVaultSnapshot] {
    receivedSnapshots
  }

  func currentRemote() -> RemoteVaultSnapshot? {
    remoteSnapshot
  }
}
