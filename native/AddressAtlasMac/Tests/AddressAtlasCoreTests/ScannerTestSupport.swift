import CryptoKit
import Foundation
import XCTest

@testable import AddressAtlasCore

func krakenStateFixture(
  secret: Data? = nil
) throws -> ScannerKrakenStateFixture {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "address-atlas-kraken-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return ScannerKrakenStateFixture(
    directory: directory,
    stateURL: directory.appending(path: "state.json"),
    secretStore: ScannerKrakenInstallationSecretStore(secret: secret)
  )
}

struct ScannerHTTPStub: HTTPClient, @unchecked Sendable {
  let handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try await handler(request)
  }
}

struct ScannerStaticPriceProvider: PriceProviding {
  var values: [String: PricePoint]
  func prices(for coinGeckoIds: [String]) async throws -> [String: PricePoint] { values }
}

struct ScannerFailingPriceProvider: PriceProviding {
  func prices(for coinGeckoIds: [String]) async throws -> [String: PricePoint] {
    throw URLError(.cannotConnectToHost)
  }
}

struct ScannerSleepingPriceProvider: PriceProviding {
  func prices(for coinGeckoIds: [String]) async throws -> [String: PricePoint] {
    try await Task.sleep(nanoseconds: 5_000_000_000)
    return [:]
  }
}

final class ScannerRequestLog: @unchecked Sendable {
  private let lock = NSLock()
  private var requests: [URLRequest] = []

  @discardableResult
  func append(_ request: URLRequest) -> Int {
    lock.lock()
    defer { lock.unlock() }
    requests.append(request)
    return requests.count
  }

  func snapshot() -> [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
}

struct ScannerKrakenStateFixture {
  let directory: URL
  let stateURL: URL
  let secretStore: ScannerKrakenInstallationSecretStore

  func makeGenerator() -> KrakenNonceGenerator {
    KrakenNonceGenerator(
      storageURL: stateURL,
      installationSecretStore: secretStore
    )
  }
}

private enum ScannerKrakenSecretStoreFailure: Error {
  case unavailable
}

final class ScannerKrakenInstallationSecretStore:
  KrakenInstallationSecretStore,
  @unchecked Sendable
{
  enum FailureMode: Equatable {
    case none
    case load
    case save
  }

  private let lock = NSLock()
  private var secret: Data?
  private var failureMode: FailureMode = .none

  init(secret: Data? = nil) {
    self.secret = secret
  }

  func loadSecret() throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    guard failureMode != .load else { throw ScannerKrakenSecretStoreFailure.unavailable }
    return secret
  }

  func saveSecretIfAbsent(_ candidate: Data) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard failureMode != .save else { throw ScannerKrakenSecretStoreFailure.unavailable }
    if let secret { return secret }
    secret = candidate
    return candidate
  }

  func setFailureMode(_ mode: FailureMode) {
    lock.lock()
    failureMode = mode
    lock.unlock()
  }

  func removeSecret() {
    lock.lock()
    secret = nil
    lock.unlock()
  }

  func snapshotSecret() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return secret
  }
}

final class ScannerNonceSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String]

  init(_ values: [String]) { self.values = values }

  func next() -> String {
    lock.lock()
    defer { lock.unlock() }
    return values.isEmpty ? "fallback" : values.removeFirst()
  }
}

actor ScannerConcurrencyProbe {
  private var active = 0
  private var highWaterMark = 0

  func enter() {
    active += 1
    highWaterMark = max(highWaterMark, active)
  }

  func leave() { active -= 1 }
  func maximum() -> Int { highWaterMark }
}

final class ScannerSlowDripProbe: @unchecked Sendable {
  private let condition = NSCondition()
  private var started = false
  private var stopped = false

  func reset() {
    condition.lock()
    started = false
    stopped = false
    condition.unlock()
  }

  func markStarted() {
    condition.lock()
    started = true
    condition.broadcast()
    condition.unlock()
  }

  func markStopped() {
    condition.lock()
    stopped = true
    condition.broadcast()
    condition.unlock()
  }

  func waitForStart(timeout: TimeInterval) -> Bool {
    wait(timeout: timeout) { started }
  }

  func waitForStop(timeout: TimeInterval) -> Bool {
    wait(timeout: timeout) { stopped }
  }

  private func wait(timeout: TimeInterval, predicate: () -> Bool) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() {
      guard condition.wait(until: deadline) else { return predicate() }
    }
    return true
  }
}

final class ScannerSlowDripURLProtocol: URLProtocol, @unchecked Sendable {
  static let probe = ScannerSlowDripProbe()

  private let stateLock = NSLock()
  private var stopped = false

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.probe.markStarted()
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["content-type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

    DispatchQueue.global().async { [weak self] in
      guard let self else { return }
      for _ in 0..<250 {
        Thread.sleep(forTimeInterval: 0.02)
        guard !self.isStopped else { return }
        self.client?.urlProtocol(self, didLoad: Data([0x20]))
      }
      guard !self.isStopped else { return }
      self.client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {
    stateLock.lock()
    stopped = true
    stateLock.unlock()
    Self.probe.markStopped()
  }

  private var isStopped: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return stopped
  }
}

final class ScannerOversizedURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["content-type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(repeating: 0x61, count: 4))
    client?.urlProtocol(self, didLoad: Data(repeating: 0x62, count: 4))
    client?.urlProtocol(self, didLoad: Data(repeating: 0x63, count: 4))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

final class ScannerRedirectURLProtocol: URLProtocol, @unchecked Sendable {
  private static let destinationRequests = ScannerRequestLog()
  static var destinationRequestCount: Int { destinationRequests.snapshot().count }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    if request.url?.host == "redirect-origin.example" {
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 302,
        httpVersion: "HTTP/1.1",
        headerFields: ["location": "https://redirect-destination.example/secret"]
      )!
      let redirected = URLRequest(url: URL(string: "https://redirect-destination.example/secret")!)
      client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
      client?.urlProtocolDidFinishLoading(self)
      return
    }

    _ = Self.destinationRequests.append(request)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["content-type": "text/plain"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("redirect followed".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

func scannerPrivateKey() throws -> P256.Signing.PrivateKey {
  try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
}

func scannerJSONObject(_ data: Data) throws -> [String: Any] {
  try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

func scannerResponse(
  _ request: URLRequest,
  _ json: String,
  statusCode: Int = 200,
  headerFields: [String: String] = [:]
) -> (Data, HTTPURLResponse) {
  (
    Data(json.utf8),
    scannerHTTPResponse(request, statusCode: statusCode, headerFields: headerFields)
  )
}

func scannerHTTPResponse(
  _ request: URLRequest,
  statusCode: Int = 200,
  headerFields: [String: String] = [:]
) -> HTTPURLResponse {
  var headers = ["content-type": "application/json"]
  headers.merge(headerFields) { _, new in new }
  return HTTPURLResponse(
    url: request.url ?? URL(string: "https://example.com")!,
    statusCode: statusCode,
    httpVersion: "HTTP/1.1",
    headerFields: headers
  )!
}
