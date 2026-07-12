import Foundation

public protocol HTTPClient: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct WorkflowTimeoutError: Error, Equatable, LocalizedError, Sendable {
  public var seconds: TimeInterval

  public init(seconds: TimeInterval) {
    self.seconds = seconds
  }

  public var errorDescription: String? {
    "The operation exceeded its \(Int(seconds))-second deadline."
  }
}

private struct IndexedAsyncValue<Value: Sendable>: Sendable {
  var index: Int
  var value: Value
}

actor CompletedWorkCollector<Value: Sendable> {
  private var values: [Value] = []

  func append(_ value: Value) {
    values.append(value)
  }

  func snapshot() -> [Value] {
    values
  }
}

func withWorkflowTimeout<Value: Sendable>(
  seconds: TimeInterval,
  operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  guard seconds.isFinite, seconds > 0 else { throw WorkflowTimeoutError(seconds: seconds) }
  return try await withThrowingTaskGroup(of: Value.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      throw WorkflowTimeoutError(seconds: seconds)
    }
    defer { group.cancelAll() }
    guard let value = try await group.next() else { throw CancellationError() }
    return value
  }
}

func boundedConcurrentMap<Input: Sendable, Output: Sendable>(
  _ inputs: [Input],
  maxConcurrent: Int,
  operation: @escaping @Sendable (Input) async throws -> Output
) async throws -> [Output] {
  guard !inputs.isEmpty else { return [] }
  let limit = max(1, min(maxConcurrent, inputs.count))
  return try await withThrowingTaskGroup(of: IndexedAsyncValue<Output>.self) { group in
    var nextIndex = 0
    var results = [Output?](repeating: nil, count: inputs.count)

    while nextIndex < limit {
      let index = nextIndex
      let input = inputs[index]
      group.addTask {
        IndexedAsyncValue(index: index, value: try await operation(input))
      }
      nextIndex += 1
    }

    while let result = try await group.next() {
      results[result.index] = result.value
      if nextIndex < inputs.count {
        let index = nextIndex
        let input = inputs[index]
        group.addTask {
          IndexedAsyncValue(index: index, value: try await operation(input))
        }
        nextIndex += 1
      }
    }
    return results.compactMap { $0 }
  }
}

func throwIfCancellation(_ error: Error) throws {
  if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
    throw CancellationError()
  }
}

extension URLSession: HTTPClient {
  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await data(for: request, delegate: nil)
    guard let http = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    return (data, http)
  }
}

/// Refuses to follow HTTP redirects. Signed exchange requests carry API-key and
/// signature headers; URLSession only strips `Authorization` on a cross-origin
/// redirect, not custom headers (`X-MBX-APIKEY`, `CB-ACCESS-SIGN`, `API-Key`),
/// so a redirect from a compromised/MITM'd host could leak credentials. With
/// this delegate a 3xx is surfaced as a normal (non-2xx) response instead.
final class NonRedirectingSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

public extension URLSession {
  /// Shared session that does not follow redirects (used for signed requests).
  static let nonRedirecting: URLSession = URLSession(
    configuration: .ephemeral,
    delegate: NonRedirectingSessionDelegate(),
    delegateQueue: nil
  )
}

public struct JSONHTTPClient: Sendable {
  private let http: HTTPClient

  public init(http: HTTPClient = URLSession.shared) {
    self.http = http
  }

  public func get<T: Decodable>(_ url: URL, as type: T.Type = T.self) async throws -> T {
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "accept")
    let (data, response) = try await http.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return try JSONDecoder.addressAtlas.decode(T.self, from: data)
  }

  public func post<T: Decodable, B: Encodable>(_ url: URL, body: B, as type: T.Type = T.self) async throws -> T {
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try JSONEncoder.addressAtlas.encode(body)
    let (data, response) = try await http.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return try JSONDecoder.addressAtlas.decode(T.self, from: data)
  }
}
