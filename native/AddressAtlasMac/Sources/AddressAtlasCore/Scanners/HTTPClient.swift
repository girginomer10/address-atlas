import Foundation

public protocol HTTPClient: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct WorkflowTimeoutError: Error, Equatable, LocalizedError, Sendable {
  public var seconds: TimeInterval

  public init(seconds: TimeInterval) {
    self.seconds = seconds
  }

  var displaySeconds: String {
    seconds.isFinite && seconds >= 0 && seconds < Double(Int.max)
      ? String(Int(seconds))
      : String(seconds)
  }

  public var errorDescription: String? {
    "The operation exceeded its \(displaySeconds)-second deadline."
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
    let withoutControls = String(
      raw.unicodeScalars.map { scalar -> Character in
        CharacterSet.controlCharacters.contains(scalar) ? " " : Character(String(scalar))
      })
    var cleaned =
      withoutControls
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")

    cleaned = cleaned.replacingOccurrences(
      of: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
      with: "Bearer [redacted]",
      options: .regularExpression
    )
    cleaned = cleaned.replacingOccurrences(
      of:
        #"(?i)(api[_ -]?key|secret|token|passphrase|authorization)[\"']?\s*[:=]\s*[\"']?[^,\s\"'}]+"#,
      with: "$1=[redacted]",
      options: .regularExpression
    )
    cleaned = cleaned.replacingOccurrences(
      of: #"(?<![A-Za-z0-9])[A-Za-z0-9+/_=-]{48,}(?![A-Za-z0-9])"#,
      with: "[redacted]",
      options: .regularExpression
    )

    // Framework domains and Swift's default `Module.Type error N` strings are
    // implementation details, not recovery guidance. Scanner failures can
    // become durable warnings, so fail to a reviewed provider message here as
    // well as at the app's primary error boundary.
    if cleaned.range(
      of:
        #"(?i)(NS[A-Za-z0-9_]*ErrorDomain|[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+Error error -?[0-9]+)"#,
      options: .regularExpression
    ) != nil {
      return fallback
    }

    guard !cleaned.isEmpty else { return fallback }
    let scalars = cleaned.unicodeScalars
    guard scalars.count > maximumScalarCount else { return cleaned }
    return String(String.UnicodeScalarView(scalars.prefix(maximumScalarCount))) + "…"
  }
}

/// Final persistence/UI boundary for warnings originating in remote-provider
/// responses. Provider-specific parsers should aggregate repeated record errors
/// first; this policy is the independent backstop that bounds both count and
/// text length even for restored or adversarial inputs.
public enum ScanWarningPolicy {
  public static let maximumCount = 64
  public static let maximumScalarCount = ProviderErrorSanitizer.maximumScalarCount + 1

  public static func bounded(_ warnings: [String]) -> [String] {
    guard !warnings.isEmpty else { return [] }
    var result: [String] = []
    result.reserveCapacity(min(warnings.count, maximumCount))
    var seen = Set<String>()
    var omitted = 0

    for warning in warnings {
      let sanitized = ProviderErrorSanitizer.sanitize(
        warning, fallback: "Provider warning unavailable.")
      guard seen.insert(sanitized).inserted else { continue }
      if result.count < maximumCount - 1 {
        result.append(sanitized)
      } else {
        omitted += 1
      }
    }

    if omitted > 0 {
      result.append(
        "\(omitted) additional unique scan warning\(omitted == 1 ? " was" : "s were") omitted.")
    }
    return result
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
  let rawNanoseconds = seconds * 1_000_000_000
  guard rawNanoseconds.isFinite,
    rawNanoseconds > 0,
    rawNanoseconds < Double(UInt64.max)
  else {
    throw WorkflowTimeoutError(seconds: seconds)
  }
  let nanoseconds = UInt64(rawNanoseconds.rounded(.up))
  // A throwing task-group scope waits for cancelled children to finish before
  // returning. Callers must therefore make `operation` cancellation-cooperative
  // (all production callers use URLSession, Task.sleep, or explicit checks).
  // BoundedURLSessionHTTPClient additionally cancels its URLSessionTask while
  // unwinding so a slow-drip response cannot keep this scope alive.
  return try await withThrowingTaskGroup(of: Value.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(nanoseconds: nanoseconds)
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

/// Transport trust boundary (deliberate design decision): TLS certificate or
/// public-key pinning is intentionally NOT implemented. Every remote endpoint
/// (chain RPCs, the price API, exchange APIs, the sync server) is operated by a
/// third party that rotates certificates and CAs on its own schedule, so pins
/// would turn routine rotations into app-wide outages with no recovery path
/// short of shipping a new binary. The chosen boundary is instead the system
/// trust store plus: HTTPS-only host/scheme/port allowlisting (validated
/// endpoint config and hardcoded exchange origins), sessions that refuse to
/// follow redirects, bounded response sizes, and wall-clock timeouts.
///
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

extension URLSession {
  /// Shared session that does not follow redirects (used for signed requests).
  public static let nonRedirecting: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    // URLRequest.timeoutInterval is an inactivity timeout and can be kept alive
    // forever by a slow-drip response. This resource timeout is an independent
    // system-level backstop; BoundedURLSessionHTTPClient also enforces a
    // per-instance wall-clock deadline so shorter config/sync limits are honored.
    configuration.timeoutIntervalForResource = 30
    return URLSession(
      configuration: configuration,
      delegate: NonRedirectingSessionDelegate(),
      delegateQueue: nil
    )
  }()
}

/// Streams response bytes and aborts the underlying task as soon as the limit
/// is exceeded. A post-download `Data.count` check is not sufficient because an
/// untrusted provider could otherwise exhaust memory before validation runs.
public struct BoundedURLSessionHTTPClient: HTTPClient {
  private let session: URLSession
  public let maxResponseBytes: Int
  public let resourceTimeout: TimeInterval

  public init(
    session: URLSession = .nonRedirecting,
    maxResponseBytes: Int = 8_000_000,
    resourceTimeout: TimeInterval = 30
  ) {
    self.session = session
    self.maxResponseBytes = max(1, maxResponseBytes)
    let validatedTimeout = resourceTimeout.isFinite && resourceTimeout > 0 ? resourceTimeout : 30
    self.resourceTimeout = min(validatedTimeout, 30)
  }

  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let requestTimeout =
      request.timeoutInterval.isFinite && request.timeoutInterval > 0
      ? request.timeoutInterval
      : resourceTimeout
    let deadline = min(requestTimeout, resourceTimeout)
    do {
      return try await withWorkflowTimeout(seconds: deadline) {
        try await streamData(for: request)
      }
    } catch is WorkflowTimeoutError {
      if Task.isCancelled { throw CancellationError() }
      throw URLError(.timedOut)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
      // Preserve structured-concurrency cancellation for callers. A transport
      // cancellation unrelated to the parent task remains a URLError.
      throw CancellationError()
    }
  }

  private func streamData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
  private let maxTransientRetries = 1

  public init(
    http: HTTPClient? = nil,
    maxResponseBytes: Int = 8_000_000,
    maxRateLimitRetries: Int = 1
  ) {
    let responseLimit = max(1, maxResponseBytes)
    self.http =
      http
      ?? BoundedURLSessionHTTPClient(
        maxResponseBytes: responseLimit,
        resourceTimeout: 30
      )
    self.maxResponseBytes = responseLimit
    self.maxRateLimitRetries = max(0, min(maxRateLimitRetries, 3))
  }

  public func get<T: Decodable>(
    _ url: URL,
    headers: [String: String] = [:],
    as type: T.Type = T.self
  ) async throws -> T {
    try await getResponse(url, headers: headers, as: type).value
  }

  func getResponse<T: Decodable>(
    _ url: URL,
    headers: [String: String] = [:],
    as type: T.Type = T.self
  ) async throws -> (value: T, response: HTTPURLResponse) {
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "accept")
    for (field, value) in headers {
      request.setValue(value, forHTTPHeaderField: field)
    }
    let (data, response) = try await send(request)
    return (try JSONDecoder.addressAtlas.decode(T.self, from: data), response)
  }

  func getRawResponse(
    _ url: URL,
    headers: [String: String] = [:]
  ) async throws -> (data: Data, response: HTTPURLResponse) {
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    for (field, value) in headers {
      request.setValue(value, forHTTPHeaderField: field)
    }
    return try await send(request)
  }

  public func post<T: Decodable, B: Encodable>(_ url: URL, body: B, as type: T.Type = T.self)
    async throws -> T
  {
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try JSONEncoder.addressAtlas.encode(body)
    let (data, _) = try await send(request)
    return try JSONDecoder.addressAtlas.decode(T.self, from: data)
  }

  private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    var rateLimitRetries = 0
    var transientRetries = 0
    while true {
      try Task.checkCancellation()
      let data: Data
      let response: HTTPURLResponse
      do {
        (data, response) = try await http.data(for: request)
      } catch {
        try throwIfCancellation(error)
        guard transientRetries < maxTransientRetries, Self.isTransientTransportFailure(error)
        else { throw error }
        transientRetries += 1
        try await Self.sleepBeforeRetry(seconds: 0.25)
        continue
      }
      if response.statusCode == 429,
        rateLimitRetries < maxRateLimitRetries,
        let delay = Self.boundedRetryDelay(response.value(forHTTPHeaderField: "Retry-After"))
      {
        rateLimitRetries += 1
        if delay > 0 {
          try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        continue
      }
      if Self.isTransientStatus(response.statusCode), transientRetries < maxTransientRetries {
        transientRetries += 1
        let delay =
          Self.boundedRetryDelay(response.value(forHTTPHeaderField: "Retry-After")) ?? 0.25
        try await Self.sleepBeforeRetry(seconds: delay)
        continue
      }
      guard (200..<300).contains(response.statusCode) else {
        throw JSONHTTPClientError.httpStatus(response.statusCode)
      }
      guard data.count <= maxResponseBytes else {
        throw JSONHTTPClientError.responseTooLarge
      }
      return (data, response)
    }
  }

  static func isTransientFailure(_ error: Error) -> Bool {
    if let httpError = error as? JSONHTTPClientError,
      let statusCode = httpError.statusCode
    {
      return isTransientStatus(statusCode)
    }
    return isTransientTransportFailure(error)
  }

  private static func isTransientStatus(_ statusCode: Int) -> Bool {
    statusCode == 408 || statusCode == 425 || (500...599).contains(statusCode)
  }

  private static func isTransientTransportFailure(_ error: Error) -> Bool {
    guard let code = (error as? URLError)?.code else { return false }
    return [
      .timedOut,
      .cannotFindHost,
      .cannotConnectToHost,
      .networkConnectionLost,
      .dnsLookupFailed,
      .notConnectedToInternet,
      .resourceUnavailable,
    ].contains(code)
  }

  private static func sleepBeforeRetry(seconds: TimeInterval) async throws {
    guard seconds > 0 else { return }
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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
