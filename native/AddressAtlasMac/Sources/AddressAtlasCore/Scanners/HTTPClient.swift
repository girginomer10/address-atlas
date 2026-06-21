import Foundation

public protocol HTTPClient: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
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
