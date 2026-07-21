import CryptoKit
import Foundation
import XCTest

@testable import AddressAtlasCore

final class JSONHTTPClientHardeningTests: XCTestCase {
  func testFinalWarningPolicyCapsUniqueCountAndProviderControlledLength() {
    let warnings = (0..<1_000).map { index in
      "warning \(index): " + String(repeating: "x", count: 2_000)
    }

    let bounded = ScanWarningPolicy.bounded(warnings)

    XCTAssertEqual(bounded.count, ScanWarningPolicy.maximumCount)
    XCTAssertTrue(bounded.last?.contains("additional unique scan warnings were omitted") == true)
    XCTAssertTrue(
      bounded.allSatisfy {
        $0.unicodeScalars.count <= ScanWarningPolicy.maximumScalarCount
      })
  }

  func testRetriesOneRateLimitedRequestUsingBoundedRetryAfter() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      let call = requests.append(request)
      if call == 1 {
        return scannerResponse(
          request,
          #"{"error":"slow down"}"#,
          statusCode: 429,
          headerFields: ["Retry-After": "0"]
        )
      }
      return scannerResponse(request, #"{"ok":1}"#)
    }
    let client = JSONHTTPClient(http: http, maxRateLimitRetries: 1)

    let result = try await client.get(
      URL(string: "https://rpc.example/data")!, as: [String: Int].self)

    XCTAssertEqual(result["ok"], 1)
    XCTAssertEqual(requests.snapshot().count, 2)
  }

  func testRetriesOneTransientHTTPFailureThenReturnsSuccess() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      let call = requests.append(request)
      if call == 1 {
        return scannerResponse(
          request,
          #"{"error":"temporarily unavailable"}"#,
          statusCode: 503,
          headerFields: ["Retry-After": "0"]
        )
      }
      return scannerResponse(request, #"{"ok":1}"#)
    }
    let client = JSONHTTPClient(http: http)

    let result = try await client.get(
      URL(string: "https://rpc.example/data")!, as: [String: Int].self)

    XCTAssertEqual(result["ok"], 1)
    XCTAssertEqual(requests.snapshot().count, 2)
  }

  func testPersistentTransientHTTPFailureStopsAfterOneRetry() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      return scannerResponse(
        request,
        #"{"error":"temporarily unavailable"}"#,
        statusCode: 503,
        headerFields: ["Retry-After": "0"]
      )
    }
    let client = JSONHTTPClient(http: http)

    do {
      _ = try await client.get(
        URL(string: "https://rpc.example/data")!, as: [String: Int].self)
      XCTFail("Expected the persistent transient failure to surface.")
    } catch let error as JSONHTTPClientError {
      XCTAssertEqual(error, .httpStatus(503))
    }
    XCTAssertEqual(requests.snapshot().count, 2)
  }

  func testRetriesOneSelectedTransportFailure() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      let call = requests.append(request)
      if call == 1 { throw URLError(.timedOut) }
      return scannerResponse(request, #"{"ok":1}"#)
    }
    let client = JSONHTTPClient(http: http)

    let result = try await client.get(
      URL(string: "https://rpc.example/data")!, as: [String: Int].self)

    XCTAssertEqual(result["ok"], 1)
    XCTAssertEqual(requests.snapshot().count, 2)
  }

  func testCancellationIsNeverRetried() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      throw CancellationError()
    }
    let client = JSONHTTPClient(http: http)

    do {
      _ = try await client.get(
        URL(string: "https://rpc.example/data")!, as: [String: Int].self)
      XCTFail("Expected cancellation to propagate.")
    } catch is CancellationError {
      // Expected.
    }
    XCTAssertEqual(requests.snapshot().count, 1)
  }

  func testRejectsSuccessfulResponseAboveConfiguredSizeLimit() async throws {
    let http = ScannerHTTPStub { request in
      scannerResponse(request, #"{"payload":"too-large"}"#)
    }
    let client = JSONHTTPClient(http: http, maxResponseBytes: 8)

    do {
      _ = try await client.get(URL(string: "https://rpc.example/data")!, as: [String: String].self)
      XCTFail("Expected a response-size failure.")
    } catch let error as JSONHTTPClientError {
      XCTAssertEqual(error, .responseTooLarge)
    }
  }

  func testBoundedURLSessionClientAbortsAnUnknownLengthStreamAtTheLimit() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScannerOversizedURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = BoundedURLSessionHTTPClient(session: session, maxResponseBytes: 8)
    let request = URLRequest(url: URL(string: "https://stream.example/oversized")!)

    do {
      _ = try await client.data(for: request)
      XCTFail("Expected the stream to be aborted at its byte limit.")
    } catch let error as JSONHTTPClientError {
      XCTAssertEqual(error, .responseTooLarge)
    }
  }

  func testBoundedURLSessionClientDoesNotFollowRedirects() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScannerRedirectURLProtocol.self]
    let session = URLSession(
      configuration: configuration,
      delegate: NonRedirectingSessionDelegate(),
      delegateQueue: nil
    )
    defer { session.invalidateAndCancel() }
    let client = BoundedURLSessionHTTPClient(session: session)
    let request = URLRequest(url: URL(string: "https://redirect-origin.example/start")!)

    do {
      _ = try await client.data(for: request)
      XCTFail("Expected the refused redirect to fail the request.")
    } catch {
      XCTAssertTrue(error is URLError)
    }
    XCTAssertEqual(ScannerRedirectURLProtocol.destinationRequestCount, 0)
  }

  func testBoundedURLSessionClientEnforcesAbsoluteDeadlineAndCancelsSlowDrip() async throws {
    ScannerSlowDripURLProtocol.probe.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScannerSlowDripURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = BoundedURLSessionHTTPClient(session: session, resourceTimeout: 0.08)
    var request = URLRequest(url: URL(string: "https://stream.example/slow-drip-deadline")!)
    request.timeoutInterval = 10
    let startedAt = Date()

    do {
      _ = try await client.data(for: request)
      XCTFail("Expected the absolute resource deadline to abort the slow stream.")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .timedOut)
    }

    let elapsed = Date().timeIntervalSince(startedAt)
    XCTAssertGreaterThanOrEqual(elapsed, 0.06)
    // Leave CI scheduling headroom while still proving that the 10-second
    // request timeout is not what ended the slow-drip transfer.
    XCTAssertLessThan(elapsed, 1.5)
    XCTAssertTrue(ScannerSlowDripURLProtocol.probe.waitForStop(timeout: 1))
  }

  func testBoundedURLSessionClientPreservesCallerCancellationAndCancelsSlowDrip() async throws {
    ScannerSlowDripURLProtocol.probe.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScannerSlowDripURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = BoundedURLSessionHTTPClient(session: session, resourceTimeout: 5)
    let request = URLRequest(url: URL(string: "https://stream.example/slow-drip-cancel")!)
    let task = Task { try await client.data(for: request) }
    XCTAssertTrue(ScannerSlowDripURLProtocol.probe.waitForStart(timeout: 1))

    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected caller cancellation to propagate.")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Expected CancellationError, got \(error).")
    }
    XCTAssertTrue(ScannerSlowDripURLProtocol.probe.waitForStop(timeout: 1))
  }

  func testProviderErrorSanitizerRedactsSecretsFlattensControlsAndCapsLength() {
    let rawSecret = String(repeating: "s", count: 80)
    let sanitized = ProviderErrorSanitizer.sanitize(
      "authorization: Bearer \(rawSecret)\napi_key=\(rawSecret) \(String(repeating: "x", count: 500))"
    )

    XCTAssertFalse(sanitized.contains(rawSecret))
    XCTAssertFalse(sanitized.contains("\n"))
    XCTAssertTrue(sanitized.contains("[redacted]"))
    XCTAssertLessThanOrEqual(
      sanitized.unicodeScalars.count, ProviderErrorSanitizer.maximumScalarCount + 1)
  }

  func testProviderErrorSanitizerNeverPublishesRawFrameworkOrSwiftTypeErrors() {
    XCTAssertEqual(
      ProviderErrorSanitizer.sanitize(
        "The operation couldn't be completed. (AddressAtlasCore.KeychainVaultKeyStoreError error 0.)"
      ),
      "Provider request failed."
    )
    XCTAssertEqual(
      ProviderErrorSanitizer.sanitize("Request failed in NSURLErrorDomain code -1009"),
      "Provider request failed."
    )
  }
}
