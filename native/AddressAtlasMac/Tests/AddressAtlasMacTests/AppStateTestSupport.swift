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
