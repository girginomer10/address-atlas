import AddressAtlasCore
import Foundation
import XCTest

@testable import AddressAtlasMac

@MainActor
final class AppStateNetworkBoundaryTests: XCTestCase {
  func makeTemporaryStore() throws -> (
    directory: URL,
    database: URL,
    vaultKey: Data,
    store: EncryptedSQLiteVaultStore
  ) {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = directory.appending(path: "vault.sqlite")
    let vaultKey = try VaultCrypto().generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(path: database, vaultKey: vaultKey)
    _ = try store.load()
    return (directory, database, vaultKey, store)
  }
}

@MainActor
final class StubPasskeyAuthenticator: PasskeyAuthenticating {
  private let session: PasskeyWebSession
  private(set) var callCount = 0
  private(set) var lastMode: PasskeyWebMode?

  init(session: PasskeyWebSession) {
    self.session = session
  }

  func authenticate(serverURL: URL, mode: PasskeyWebMode) async throws -> PasskeyWebSession {
    callCount += 1
    lastMode = mode
    return session
  }
}

@MainActor
final class CancelledPasskeyAuthenticator: PasskeyAuthenticating {
  func authenticate(serverURL: URL, mode: PasskeyWebMode) async throws -> PasskeyWebSession {
    throw PasskeyAuthenticationError.cancelled
  }
}

@MainActor
final class RecordingPasskeyAuthenticator: PasskeyAuthenticating {
  private(set) var callCount = 0

  func authenticate(serverURL: URL, mode: PasskeyWebMode) async throws -> PasskeyWebSession {
    callCount += 1
    throw PasskeyAuthenticationError.unavailable
  }
}

final class RecordingHTTPStub: HTTPClient, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [URLRequest] = []
  private let handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
    self.handler = handler
  }

  var requests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    record(request)
    return try await handler(request)
  }

  private func record(_ request: URLRequest) {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(request)
  }
}

actor DeletionAttemptCounter {
  private var count = 0

  func next() -> Int {
    count += 1
    return count
  }
}

func stubJSONResponse(
  _ request: URLRequest,
  _ json: String,
  statusCode: Int = 200
) -> (Data, HTTPURLResponse) {
  (Data(json.utf8), stubHTTPResponse(request, statusCode: statusCode))
}

func stubHTTPResponse(
  _ request: URLRequest,
  statusCode: Int = 200
) -> HTTPURLResponse {
  HTTPURLResponse(
    url: request.url ?? URL(string: "https://example.com")!,
    statusCode: statusCode,
    httpVersion: "HTTP/1.1",
    headerFields: ["content-type": "application/json"]
  )!
}
