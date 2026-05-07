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

public struct JSONHTTPClient: Sendable {
  private let http: HTTPClient

  public init(http: HTTPClient = URLSession.shared) {
    self.http = http
  }

  public func get<T: Decodable>(_ url: URL, as type: T.Type = T.self) async throws -> T {
    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "accept")
    let (data, response) = try await http.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return try JSONDecoder.addressAtlas.decode(T.self, from: data)
  }

  public func post<T: Decodable, B: Encodable>(_ url: URL, body: B, as type: T.Type = T.self) async throws -> T {
    var request = URLRequest(url: url)
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
