import AddressAtlasCore
import CryptoKit
import Foundation
import XCTest
@testable import AddressAtlasMac

@MainActor
final class PasskeyWebAuthenticatorTests: XCTestCase {
  private let validUserId = "11111111-1111-4111-8111-111111111111"
  private let verifier = Base64URL.encode(Data(0..<32))

  func testPKCEUsesCanonicalThirtyTwoByteVerifierAndSHA256Challenge() throws {
    let bytes = Data(0..<32)
    let material = try PasskeyWebAuthenticator.makePKCEMaterial(randomBytes: bytes)
    let independentChallenge = Base64URL.encode(
      Data(SHA256.hash(data: Data(material.verifier.utf8))))

    XCTAssertEqual(material.verifier, Base64URL.encode(bytes))
    XCTAssertEqual(material.verifier.utf8.count, 43)
    XCTAssertEqual(try Base64URL.decode(material.verifier), bytes)
    XCTAssertEqual(material.challenge, independentChallenge)
    XCTAssertEqual(material.challenge.utf8.count, 43)
    XCTAssertEqual(try Base64URL.decode(material.challenge).count, 32)
    XCTAssertThrowsError(
      try PasskeyWebAuthenticator.makePKCEMaterial(randomBytes: Data(repeating: 0, count: 31)))
  }

  func testPKCES256MatchesRFC7636KnownAnswer() throws {
    let expectedVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    let bytes = try Base64URL.decode(expectedVerifier)
    let material = try PasskeyWebAuthenticator.makePKCEMaterial(randomBytes: bytes)

    XCTAssertEqual(material.verifier, expectedVerifier)
    XCTAssertEqual(material.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  func testAuthorizationURLCarriesChallengeAndNeverVerifier() throws {
    let server = try XCTUnwrap(URL(string: "https://sync.example.com"))
    let state = "11111111-1111-4111-8111-111111111111"
    let material = try PasskeyWebAuthenticator.makePKCEMaterial(randomBytes: Data(0..<32))
    let url = try PasskeyWebAuthenticator.authorizationURL(
      serverURL: server,
      mode: .authenticate,
      state: state,
      codeChallenge: material.challenge
    )
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let queryItems = try XCTUnwrap(components.queryItems)
    let values = Dictionary(uniqueKeysWithValues: try queryItems.map { item in
      (item.name, try XCTUnwrap(item.value))
    })

    XCTAssertEqual(url.path, "/auth/native")
    XCTAssertEqual(values["mode"], "authenticate")
    XCTAssertEqual(values["callback"], "address-atlas://sync-auth")
    XCTAssertEqual(values["state"], state)
    XCTAssertEqual(values["code_challenge"], material.challenge)
    XCTAssertEqual(values["code_challenge_method"], "S256")
    XCTAssertNil(values["codeVerifier"])
    XCTAssertFalse(url.absoluteString.contains(material.verifier))
  }

  func testCallbackCarriesOnlyCodeStateAndExpectedCanonicalOrigin() throws {
    let expected = try XCTUnwrap(URL(string: "https://sync.example.com"))
    let callback = try callbackURL(
      serverURL: "HTTPS://SYNC.EXAMPLE.COM:443/",
      state: "request-state",
      code: "signed.code_1"
    )

    let parsed = try PasskeyWebAuthenticator.parseAuthorizationCallback(
      callbackURL: callback,
      expectedState: "request-state",
      expectedServerURL: expected
    )

    XCTAssertEqual(parsed.authorizationCode, "signed.code_1")
    XCTAssertEqual(parsed.serverURL, expected)
  }

  func testCallbackRejectsWrongStateOriginPathAuthorityAndFragments() throws {
    let expected = try XCTUnwrap(URL(string: "https://sync.example.com"))
    let encodedServer = "https%3A%2F%2Fsync.example.com"
    let invalidCallbacks = [
      try callbackURL(serverURL: expected.absoluteString, state: "wrong-state"),
      try callbackURL(serverURL: "https://attacker.example", state: "request-state"),
      try XCTUnwrap(
        URL(string: "address-atlas://other?code=code-1&state=request-state&serverURL=\(encodedServer)")),
      try XCTUnwrap(
        URL(string: "address-atlas://user@sync-auth?code=code-1&state=request-state&serverURL=\(encodedServer)")),
      try XCTUnwrap(
        URL(string: "address-atlas://sync-auth:443?code=code-1&state=request-state&serverURL=\(encodedServer)")),
      try XCTUnwrap(
        URL(string: "address-atlas://sync-auth/extra?code=code-1&state=request-state&serverURL=\(encodedServer)")),
      try XCTUnwrap(
        URL(string: "address-atlas://sync-auth?code=code-1&state=request-state&serverURL=\(encodedServer)#fragment")),
    ]

    for callback in invalidCallbacks {
      XCTAssertThrowsError(
        try PasskeyWebAuthenticator.parseAuthorizationCallback(
          callbackURL: callback,
          expectedState: "request-state",
          expectedServerURL: expected
        ),
        "Unexpectedly accepted callback: \(callback)"
      )
    }
  }

  func testCallbackRejectsDuplicateMissingUnexpectedAndBearerFields() throws {
    let expected = try XCTUnwrap(URL(string: "https://sync.example.com"))
    let encodedServer = "https%3A%2F%2Fsync.example.com"
    let invalidCallbacks = [
      "address-atlas://sync-auth?code=code-1&code=code-1&state=request-state&serverURL=\(encodedServer)",
      "address-atlas://sync-auth?code=code-1&state=request-state",
      "address-atlas://sync-auth?code=code-1&state=request-state&serverURL=\(encodedServer)&extra=1",
      "address-atlas://sync-auth?code=code-1&state=request-state&serverURL=\(encodedServer)&sessionToken=secret",
      "address-atlas://sync-auth?code=code-1&state=request-state&serverURL=\(encodedServer)&userId=\(validUserId)",
    ]

    for rawURL in invalidCallbacks {
      let callback = try XCTUnwrap(URL(string: rawURL))
      XCTAssertThrowsError(
        try PasskeyWebAuthenticator.parseAuthorizationCallback(
          callbackURL: callback,
          expectedState: "request-state",
          expectedServerURL: expected
        ),
        "Unexpectedly accepted callback: \(rawURL)"
      )
    }
  }

  func testCallbackRejectsMalformedAndOversizedAuthorizationCodes() throws {
    let expected = try XCTUnwrap(URL(string: "https://sync.example.com"))
    for code in [
      "",
      "contains a space",
      "unsafe\r\nvalue",
      "server-contract-rejects~tilde",
      String(repeating: "a", count: PasskeyWebAuthenticator.maximumAuthorizationCodeByteCount + 1),
      String(repeating: "a", count: PasskeyWebAuthenticator.maximumCallbackURLByteCount + 1),
    ] {
      let callback = try callbackURL(
        serverURL: expected.absoluteString,
        state: "request-state",
        code: code
      )
      XCTAssertThrowsError(
        try PasskeyWebAuthenticator.parseAuthorizationCallback(
          callbackURL: callback,
          expectedState: "request-state",
          expectedServerURL: expected
        ),
        "Unexpectedly accepted code length \(code.utf8.count)"
      )
    }
  }

  func testCodeExchangeUsesOneBoundedCookieFreePOSTAndValidatesSession() async throws {
    let server = try XCTUnwrap(URL(string: "https://sync.example.com"))
    let userId = validUserId
    let token = testSessionToken(accountId: userId)
    let http = RecordingHTTPStub { request in
      passkeyExchangeResponse(
        request,
        "{\"userId\":\"\(userId)\",\"sessionToken\":\"\(token)\"}"
      )
    }
    let authenticator = PasskeyWebAuthenticator(http: http)

    let session = try await authenticator.exchangeAuthorizationCode(
      "signed.code-1",
      codeVerifier: verifier,
      serverURL: server
    )

    XCTAssertEqual(session.userId, validUserId)
    XCTAssertEqual(session.sessionToken, token)
    XCTAssertEqual(session.serverURL, server.absoluteString)
    let request = try XCTUnwrap(http.requests.first)
    XCTAssertEqual(http.requests.count, 1)
    XCTAssertEqual(request.url?.absoluteString, "https://sync.example.com/auth/native/exchange")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.timeoutInterval, PasskeyWebAuthenticator.exchangeTimeout)
    XCTAssertEqual(request.httpShouldHandleCookies, false)
    XCTAssertEqual(request.value(forHTTPHeaderField: "accept"), "application/json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "cache-control"), "no-store")
    XCTAssertEqual(request.value(forHTTPHeaderField: "pragma"), "no-cache")
    XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
    XCTAssertFalse(request.url?.absoluteString.contains(verifier) ?? true)
    let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
      as? [String: String]
    XCTAssertEqual(body?["authorizationCode"], "signed.code-1")
    XCTAssertEqual(body?["codeVerifier"], verifier)
    XCTAssertEqual(body?.count, 2)
  }

  func testCodeExchangeRejectsWrongStatusMalformedIdentityTokenAndOversizedBody() async throws {
    let server = try XCTUnwrap(URL(string: "https://sync.example.com"))
    let validToken = testSessionToken(accountId: validUserId)
    let mismatchedToken = testSessionToken(
      accountId: "22222222-2222-4222-8222-222222222222"
    )
    let cases: [(status: Int, body: String)] = [
      (201, "{\"userId\":\"\(validUserId)\",\"sessionToken\":\"\(validToken)\"}"),
      (200, #"{"userId":"not-a-uuid","sessionToken":"token-1"}"#),
      (200, #"{"userId":"11111111-1111-4111-8111-111111111111","sessionToken":"unsafe token"}"#),
      (200, "{\"userId\":\"\(validUserId)\",\"sessionToken\":\"\(mismatchedToken)\"}"),
      (200, "{}"),
      (200, String(repeating: "a", count: PasskeyWebAuthenticator.maximumExchangeResponseByteCount + 1)),
    ]

    for item in cases {
      let http = RecordingHTTPStub { request in
        passkeyExchangeResponse(request, item.body, statusCode: item.status)
      }
      let authenticator = PasskeyWebAuthenticator(http: http)
      do {
        _ = try await authenticator.exchangeAuthorizationCode(
          "code-1", codeVerifier: verifier, serverURL: server)
        XCTFail("Expected exchange response rejection")
      } catch {
        XCTAssertEqual(error as? PasskeyAuthenticationError, .invalidExchange)
      }
      XCTAssertEqual(http.requests.count, 1)
    }
  }

  func testCodeExchangeNeverRetriesSingleUseCodeAfterServerFailure() async throws {
    let server = try XCTUnwrap(URL(string: "https://sync.example.com"))
    let http = RecordingHTTPStub { request in
      passkeyExchangeResponse(request, #"{"error":"temporarily unavailable"}"#, statusCode: 503)
    }
    let authenticator = PasskeyWebAuthenticator(http: http)

    do {
      _ = try await authenticator.exchangeAuthorizationCode(
        "single-use-code", codeVerifier: verifier, serverURL: server)
      XCTFail("Expected exchange failure")
    } catch {
      XCTAssertEqual(error as? PasskeyAuthenticationError, .invalidExchange)
      XCTAssertTrue(error.localizedDescription.contains("server outcome is unknown"))
      XCTAssertTrue(error.localizedDescription.contains("This Mac was not connected"))
    }
    XCTAssertEqual(http.requests.count, 1)
  }

  func testCodeExchangeCancellationPropagatesWithoutReplay() async throws {
    let server = try XCTUnwrap(URL(string: "https://sync.example.com"))
    let probe = PasskeyExchangeCancellationProbe()
    let authenticator = PasskeyWebAuthenticator(http: probe)
    let task = Task { @MainActor in
      try await authenticator.exchangeAuthorizationCode(
        "single-use-code", codeVerifier: verifier, serverURL: server)
    }
    await probe.waitUntilStarted()
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    let requestCount = await probe.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testCodeExchangeRejectsMissingNoStoreOrNonJSONResponse() async throws {
    let server = try XCTUnwrap(URL(string: "https://sync.example.com"))
    let userId = validUserId
    let token = testSessionToken(accountId: userId)
    let cases: [[String: String]] = [
      ["content-type": "application/json"],
      ["content-type": "text/plain", "cache-control": "no-store"],
      ["content-type": "application/json", "cache-control": "private"],
    ]
    for headers in cases {
      let http = RecordingHTTPStub { request in
        passkeyExchangeResponse(
          request,
          "{\"userId\":\"\(userId)\",\"sessionToken\":\"\(token)\"}",
          headers: headers
        )
      }
      let authenticator = PasskeyWebAuthenticator(http: http)
      do {
        _ = try await authenticator.exchangeAuthorizationCode(
          "code-1", codeVerifier: verifier, serverURL: server)
        XCTFail("Expected response header rejection")
      } catch {
        XCTAssertEqual(error as? PasskeyAuthenticationError, .invalidExchange)
      }
    }
  }

  func testAuthorizationContinuationGateAllowsExactlyOneRacingTerminalOutcome() async {
    let gate = PasskeyAuthorizationContinuationGate()
    let winners = PasskeyGateWinnerCounter()
    let callback = URL(string: "address-atlas://sync-auth?code=code-1")!

    do {
      let _: URL = try await withCheckedThrowingContinuation { continuation in
        gate.install(continuation)
        DispatchQueue.concurrentPerform(iterations: 300) { index in
          let outcome: PasskeyAuthorizationSessionOutcome
          switch index % 3 {
          case 0: outcome = .success(callback)
          case 1: outcome = .cancelled
          default: outcome = .unavailable
          }
          if gate.complete(outcome) { winners.increment() }
        }
      }
    } catch {
      XCTAssertTrue(error is CancellationError || error as? PasskeyAuthenticationError == .unavailable)
    }

    XCTAssertEqual(winners.value, 1)
    XCTAssertTrue(gate.isCompleted)
  }

  func testAuthorizationContinuationGateRejectsLateCallbackAfterStartFailure() async {
    let gate = PasskeyAuthorizationContinuationGate()
    XCTAssertTrue(gate.complete(.unavailable))
    XCTAssertFalse(
      gate.complete(.success(URL(string: "address-atlas://sync-auth?code=late")!))
    )

    do {
      let _: URL = try await withCheckedThrowingContinuation { continuation in
        gate.install(continuation)
      }
      XCTFail("Expected the pre-install start failure")
    } catch {
      XCTAssertEqual(error as? PasskeyAuthenticationError, .unavailable)
    }
  }

  private func callbackURL(
    serverURL: String,
    state: String,
    code: String = "code-1"
  ) throws -> URL {
    var components = URLComponents()
    components.scheme = "address-atlas"
    components.host = "sync-auth"
    components.queryItems = [
      URLQueryItem(name: "code", value: code),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "serverURL", value: serverURL),
    ]
    return try XCTUnwrap(components.url)
  }

}

private func passkeyExchangeResponse(
  _ request: URLRequest,
  _ body: String,
  statusCode: Int = 200,
  headers: [String: String] = [
    "content-type": "application/json; charset=utf-8",
    "cache-control": "private, no-store",
  ]
) -> (Data, HTTPURLResponse) {
  (
    Data(body.utf8),
    HTTPURLResponse(
      url: request.url ?? URL(string: "https://sync.example.com")!,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
  )
}

private actor PasskeyExchangeCancellationProbe: HTTPClient {
  private var started = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var count = 0

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    count += 1
    started = true
    let pending = waiters
    waiters.removeAll()
    pending.forEach { $0.resume() }
    try await Task.sleep(for: .seconds(60))
    throw CancellationError()
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func requestCount() -> Int { count }
}

private final class PasskeyGateWinnerCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
