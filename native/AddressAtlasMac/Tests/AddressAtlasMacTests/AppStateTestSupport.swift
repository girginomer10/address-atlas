import AddressAtlasCore
import Foundation
import XCTest

@testable import AddressAtlasMac

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
