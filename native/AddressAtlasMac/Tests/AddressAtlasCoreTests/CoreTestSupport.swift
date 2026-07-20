import Foundation

@testable import AddressAtlasCore

struct StubHTTPClient: HTTPClient, @unchecked Sendable {
  let handler: (URLRequest) throws -> (Data, HTTPURLResponse)

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try handler(request)
  }
}

final class BatchRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var sizes: [Int] = []

  func append(_ size: Int) {
    lock.lock()
    defer { lock.unlock() }
    sizes.append(size)
  }

  func snapshot() -> [Int] {
    lock.lock()
    defer { lock.unlock() }
    return sizes
  }
}

func httpResponse(for request: URLRequest, statusCode: Int = 200) -> HTTPURLResponse {
  HTTPURLResponse(
    url: request.url ?? URL(string: "https://example.com")!,
    statusCode: statusCode,
    httpVersion: "HTTP/1.1",
    headerFields: ["content-type": "application/json"]
  )!
}
