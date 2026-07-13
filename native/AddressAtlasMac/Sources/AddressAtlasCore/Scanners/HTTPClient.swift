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

public enum JSONHTTPClientError: Error, Equatable, LocalizedError, Sendable {
  case httpStatus(Int)
  case responseTooLarge

  public var statusCode: Int? {
    if case .httpStatus(let statusCode) = self { return statusCode }
    return nil
  }

  public var errorDescription: String? {
    switch self {
    case .httpStatus(let statusCode):
      return "HTTP request failed with status \(statusCode)."
    case .responseTooLarge:
      return "HTTP response exceeded the supported size limit."
    }
  }
}

enum ProviderErrorSanitizer {
  static let maximumScalarCount = 320

  static func sanitize(_ raw: String, fallback: String = "Provider request failed.") -> String {
    let withoutControls = String(raw.unicodeScalars.map { scalar -> Character in
      CharacterSet.controlCharacters.contains(scalar) ? " " : Character(String(scalar))
    })
    var cleaned = withoutControls
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")

    cleaned = cleaned.replacingOccurrences(
      of: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
      with: "Bearer [redacted]",
      options: .regularExpression
    )
    cleaned = cleaned.replacingOccurrences(
      of: #"(?i)(api[_ -]?key|secret|token|passphrase|authorization)[\"']?\s*[:=]\s*[\"']?[^,\s\"'}]+"#,
      with: "$1=[redacted]",
      options: .regularExpression
    )
    cleaned = cleaned.replacingOccurrences(
      of: #"(?<![A-Za-z0-9])[A-Za-z0-9+/_=-]{48,}(?![A-Za-z0-9])"#,
      with: "[redacted]",
      options: .regularExpression
    )

    guard !cleaned.isEmpty else { return fallback }
    let scalars = cleaned.unicodeScalars
    guard scalars.count > maximumScalarCount else { return cleaned }
    return String(String.UnicodeScalarView(scalars.prefix(maximumScalarCount))) + "…"
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

/// Streams response bytes and aborts the underlying task as soon as the limit
/// is exceeded. A post-download `Data.count` check is not sufficient because an
/// untrusted provider could otherwise exhaust memory before validation runs.
public struct BoundedURLSessionHTTPClient: HTTPClient {
  private let session: URLSession
  public let maxResponseBytes: Int

  public init(session: URLSession = .nonRedirecting, maxResponseBytes: Int = 8_000_000) {
    self.session = session
    self.maxResponseBytes = max(1, maxResponseBytes)
  }

  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (bytes, response) = try await session.bytes(for: request, delegate: nil)
    guard let http = response as? HTTPURLResponse else {
      bytes.task.cancel()
      throw URLError(.badServerResponse)
    }
    if response.expectedContentLength > Int64(maxResponseBytes) {
      bytes.task.cancel()
      throw JSONHTTPClientError.responseTooLarge
    }

    var data = Data()
    if response.expectedContentLength > 0 {
      data.reserveCapacity(min(maxResponseBytes, Int(response.expectedContentLength)))
    }
    do {
      for try await byte in bytes {
        guard data.count < maxResponseBytes else {
          bytes.task.cancel()
          throw JSONHTTPClientError.responseTooLarge
        }
        data.append(byte)
      }
    } catch {
      bytes.task.cancel()
      throw error
    }
    return (data, http)
  }
}

public struct JSONHTTPClient: Sendable {
  private let http: HTTPClient
  private let maxResponseBytes: Int
  private let maxRateLimitRetries: Int

  public init(
    http: HTTPClient? = nil,
    maxResponseBytes: Int = 8_000_000,
    maxRateLimitRetries: Int = 1
  ) {
    let responseLimit = max(1, maxResponseBytes)
    self.http = http ?? BoundedURLSessionHTTPClient(maxResponseBytes: responseLimit)
    self.maxResponseBytes = responseLimit
    self.maxRateLimitRetries = max(0, min(maxRateLimitRetries, 3))
  }

  public func get<T: Decodable>(_ url: URL, as type: T.Type = T.self) async throws -> T {
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "accept")
    let data = try await send(request)
    return try JSONDecoder.addressAtlas.decode(T.self, from: data)
  }

  public func post<T: Decodable, B: Encodable>(_ url: URL, body: B, as type: T.Type = T.self) async throws -> T {
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try JSONEncoder.addressAtlas.encode(body)
    let data = try await send(request)
    return try JSONDecoder.addressAtlas.decode(T.self, from: data)
  }

  private func send(_ request: URLRequest) async throws -> Data {
    var rateLimitRetries = 0
    while true {
      try Task.checkCancellation()
      let (data, response) = try await http.data(for: request)
      if response.statusCode == 429,
         rateLimitRetries < maxRateLimitRetries,
         let delay = Self.boundedRetryDelay(response.value(forHTTPHeaderField: "Retry-After")) {
        rateLimitRetries += 1
        if delay > 0 {
          try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        continue
      }
      guard (200..<300).contains(response.statusCode) else {
        throw JSONHTTPClientError.httpStatus(response.statusCode)
      }
      guard data.count <= maxResponseBytes else {
        throw JSONHTTPClientError.responseTooLarge
      }
      return data
    }
  }

  private static func boundedRetryDelay(_ value: String?) -> TimeInterval? {
    guard let value else { return 0.25 }
    guard let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)),
          seconds.isFinite,
          seconds >= 0,
          seconds <= 2
    else { return nil }
    return seconds
  }
}
