import AddressAtlasCore
import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

struct PasskeyWebSession: Sendable {
  var userId: String
  var sessionToken: String
  var serverURL: String
}

enum PasskeyWebMode: String, Sendable {
  case register
  case authenticate
}

enum PasskeyAuthenticationError: Error, Equatable, LocalizedError, Sendable {
  case cancelled
  case invalidCallback
  case invalidExchange
  case unavailable

  var errorDescription: String? {
    switch self {
    case .cancelled:
      return nil
    case .invalidCallback:
      return
        "This Mac was not connected because the passkey callback was invalid. The server may still have created or refreshed a sign-in grant; start sign-in again to obtain a fresh, safely bound session."
    case .invalidExchange:
      return
        "This Mac was not connected because the one-time passkey exchange could not be confirmed. The server outcome is unknown; start sign-in again to obtain a fresh, safely bound session."
    case .unavailable:
      return "Passkey sign-in could not be started. Check the sync server and try again."
    }
  }
}

/// Injection seam for AppState behavior tests. Production always uses the real
/// ASWebAuthenticationSession ceremony implemented by PasskeyWebAuthenticator.
@MainActor
protocol PasskeyAuthenticating {
  func authenticate(serverURL: URL, mode: PasskeyWebMode) async throws -> PasskeyWebSession
}

struct PasskeyPKCEMaterial: Equatable, Sendable {
  var verifier: String
  var challenge: String
}

struct PasskeyAuthorizationCallback: Equatable, Sendable {
  var authorizationCode: String
  var serverURL: URL
}

private struct PasskeyCodeExchangeRequest: Encodable, Sendable {
  var authorizationCode: String
  var codeVerifier: String
}

private struct PasskeyCodeExchangeResponse: Decodable, Sendable {
  var userId: String
  var sessionToken: String
}

enum PasskeyAuthorizationSessionOutcome: Sendable {
  case success(URL)
  case cancelled
  case invalidCallback
  case unavailable
}

/// ASWebAuthenticationSession completion, `start() == false`, and task
/// cancellation can race. Centralize ownership of the continuation so every
/// path is safe even if the framework delivers a late callback after cancel.
final class PasskeyAuthorizationContinuationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<URL, Error>?
  private var pendingOutcome: PasskeyAuthorizationSessionOutcome?
  private var completed = false

  func install(_ continuation: CheckedContinuation<URL, Error>) {
    let pending: PasskeyAuthorizationSessionOutcome?
    lock.lock()
    precondition(self.continuation == nil, "Authorization continuation installed twice")
    if completed {
      pending = pendingOutcome
    } else {
      self.continuation = continuation
      pending = nil
    }
    lock.unlock()
    if let pending { Self.resume(continuation, with: pending) }
  }

  @discardableResult
  func complete(_ outcome: PasskeyAuthorizationSessionOutcome) -> Bool {
    let continuation: CheckedContinuation<URL, Error>?
    lock.lock()
    guard !completed else {
      lock.unlock()
      return false
    }
    completed = true
    pendingOutcome = outcome
    continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    if let continuation { Self.resume(continuation, with: outcome) }
    return true
  }

  var isCompleted: Bool {
    lock.lock()
    defer { lock.unlock() }
    return completed
  }

  private static func resume(
    _ continuation: CheckedContinuation<URL, Error>,
    with outcome: PasskeyAuthorizationSessionOutcome
  ) {
    switch outcome {
    case .success(let url): continuation.resume(returning: url)
    case .cancelled: continuation.resume(throwing: CancellationError())
    case .invalidCallback:
      continuation.resume(throwing: PasskeyAuthenticationError.invalidCallback)
    case .unavailable:
      continuation.resume(throwing: PasskeyAuthenticationError.unavailable)
    }
  }
}

@MainActor
final class PasskeyWebAuthenticator: NSObject, PasskeyAuthenticating,
  ASWebAuthenticationPresentationContextProviding
{
  static let verifierByteCount = 32
  static let canonicalVerifierLength = 43
  static let maximumAuthorizationCodeByteCount = 4_096
  static let maximumCallbackURLByteCount = 8_192
  static let maximumExchangeResponseByteCount = 16_384
  static let exchangeTimeout: TimeInterval = 15

  private let http: any HTTPClient
  private var session: ASWebAuthenticationSession?

  override convenience init() {
    self.init(
      http: BoundedURLSessionHTTPClient(
        maxResponseBytes: Self.maximumExchangeResponseByteCount,
        resourceTimeout: Self.exchangeTimeout
      )
    )
  }

  init(http: any HTTPClient) {
    self.http = http
    super.init()
  }

  func authenticate(serverURL: URL, mode: PasskeyWebMode) async throws -> PasskeyWebSession {
    try Task.checkCancellation()
    let state = UUID().uuidString
    let pkce = try Self.makePKCEMaterial()
    let authURL = try Self.authorizationURL(
      serverURL: serverURL,
      mode: mode,
      state: state,
      codeChallenge: pkce.challenge
    )
    let callbackURL = try await presentAuthorizationSession(authURL: authURL)
    let callback: PasskeyAuthorizationCallback
    do {
      callback = try Self.parseAuthorizationCallback(
        callbackURL: callbackURL,
        expectedState: state,
        expectedServerURL: serverURL
      )
    } catch {
      throw PasskeyAuthenticationError.invalidCallback
    }
    try Task.checkCancellation()
    return try await exchangeAuthorizationCode(
      callback.authorizationCode,
      codeVerifier: pkce.verifier,
      serverURL: callback.serverURL
    )
  }

  private func presentAuthorizationSession(authURL: URL) async throws -> URL {
    let continuationGate = PasskeyAuthorizationContinuationGate()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        continuationGate.install(continuation)
        guard !continuationGate.isCompleted else { return }
        let webSession = ASWebAuthenticationSession(
          url: authURL, callbackURLScheme: "address-atlas"
        ) { [weak self] callbackURL, error in
          Task { @MainActor in
            self?.session = nil
            if let authenticationError = error as? ASWebAuthenticationSessionError,
              authenticationError.code == .canceledLogin
            {
              continuationGate.complete(.cancelled)
              return
            }
            if error != nil {
              continuationGate.complete(.unavailable)
              return
            }
            guard let callbackURL else {
              continuationGate.complete(.invalidCallback)
              return
            }
            continuationGate.complete(.success(callbackURL))
          }
        }
        webSession.presentationContextProvider = self
        // The passkey ceremony does not require Safari cookies. Avoid retaining
        // or reusing web-session state on shared Macs.
        webSession.prefersEphemeralWebBrowserSession = true
        if Task.isCancelled {
          continuationGate.complete(.cancelled)
          return
        }
        session = webSession
        if !webSession.start() {
          session = nil
          continuationGate.complete(.unavailable)
        }
      }
    } onCancel: { [weak self] in
      continuationGate.complete(.cancelled)
      Task { @MainActor in
        self?.session?.cancel()
      }
    }
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
  }

  static func makePKCEMaterial(randomBytes: Data? = nil) throws -> PasskeyPKCEMaterial {
    let bytes: Data
    if let randomBytes {
      bytes = randomBytes
    } else {
      var generated = Data(count: verifierByteCount)
      let status = generated.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return errSecAllocate }
        return SecRandomCopyBytes(kSecRandomDefault, verifierByteCount, baseAddress)
      }
      guard status == errSecSuccess else { throw PasskeyAuthenticationError.unavailable }
      bytes = generated
    }
    guard bytes.count == verifierByteCount else {
      throw PasskeyAuthenticationError.unavailable
    }
    let verifier = Base64URL.encode(bytes)
    guard verifier.utf8.count == canonicalVerifierLength,
      (try? Base64URL.decode(verifier)) == bytes
    else {
      throw PasskeyAuthenticationError.unavailable
    }
    return PasskeyPKCEMaterial(
      verifier: verifier,
      challenge: Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    )
  }

  static func authorizationURL(
    serverURL: URL,
    mode: PasskeyWebMode,
    state: String,
    codeChallenge: String
  ) throws -> URL {
    guard SyncServerURL.validatedOrigin(serverURL.absoluteString) == serverURL,
      UUID(uuidString: state)?.uuidString == state,
      codeChallenge.utf8.count == canonicalVerifierLength,
      (try? Base64URL.decode(codeChallenge))?.count == verifierByteCount
    else {
      throw PasskeyAuthenticationError.unavailable
    }
    var components = URLComponents(
      url: serverURL.appending(path: "auth/native"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "mode", value: mode.rawValue),
      URLQueryItem(name: "callback", value: "address-atlas://sync-auth"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: codeChallenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    guard let authURL = components?.url else {
      throw PasskeyAuthenticationError.unavailable
    }
    return authURL
  }

  static func parseAuthorizationCallback(
    callbackURL: URL,
    expectedState: String,
    expectedServerURL: URL
  ) throws -> PasskeyAuthorizationCallback {
    // Accept exactly the callback registered with ASWebAuthenticationSession.
    // Userinfo, ports, paths, fragments, and extra fields are rejected so bearer
    // credentials can never re-enter the callback URL.
    guard callbackURL.absoluteString.utf8.count <= maximumCallbackURLByteCount,
      callbackURL.scheme == "address-atlas",
      callbackURL.host == "sync-auth",
      callbackURL.user == nil,
      callbackURL.password == nil,
      callbackURL.port == nil,
      callbackURL.path.isEmpty,
      callbackURL.fragment == nil
    else {
      throw PasskeyAuthenticationError.invalidCallback
    }
    let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let expectedNames: Set<String> = ["code", "state", "serverURL"]
    guard items.count == expectedNames.count, Set(items.map(\.name)) == expectedNames else {
      throw PasskeyAuthenticationError.invalidCallback
    }
    func value(_ name: String) -> String? {
      let matches = items.filter { $0.name == name }
      return matches.count == 1 ? matches[0].value : nil
    }
    guard let returnedState = value("state"), returnedState == expectedState,
      let authorizationCode = value("code"), isValidAuthorizationCode(authorizationCode),
      let rawServerURL = value("serverURL"), rawServerURL.utf8.count <= 2_048,
      let returnedOrigin = SyncServerURL.validatedOrigin(rawServerURL),
      returnedOrigin.absoluteString == expectedServerURL.absoluteString
    else {
      throw PasskeyAuthenticationError.invalidCallback
    }
    return PasskeyAuthorizationCallback(
      authorizationCode: authorizationCode,
      serverURL: expectedServerURL
    )
  }

  func exchangeAuthorizationCode(
    _ authorizationCode: String,
    codeVerifier: String,
    serverURL: URL
  ) async throws -> PasskeyWebSession {
    guard Self.isValidAuthorizationCode(authorizationCode),
      codeVerifier.utf8.count == Self.canonicalVerifierLength,
      (try? Base64URL.decode(codeVerifier))?.count == Self.verifierByteCount,
      SyncServerURL.validatedOrigin(serverURL.absoluteString) == serverURL
    else {
      throw PasskeyAuthenticationError.invalidExchange
    }
    try Task.checkCancellation()
    var request = URLRequest(url: serverURL.appending(path: "auth/native/exchange"))
    request.httpMethod = "POST"
    request.timeoutInterval = Self.exchangeTimeout
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("no-store", forHTTPHeaderField: "cache-control")
    request.setValue("no-cache", forHTTPHeaderField: "pragma")
    request.httpBody = try JSONEncoder.addressAtlas.encode(
      PasskeyCodeExchangeRequest(
        authorizationCode: authorizationCode,
        codeVerifier: codeVerifier
      ))

    do {
      // Authorization codes are single-use. Do not wrap this request in the
      // retrying JSON client: any lost response is an unknown outcome and must
      // start a fresh browser ceremony rather than replaying the code.
      let (data, response) = try await http.data(for: request)
      try Task.checkCancellation()
      guard response.statusCode == 200,
        Self.isJSONResponse(response),
        Self.hasNoStoreDirective(response),
        data.count <= Self.maximumExchangeResponseByteCount,
        let decoded = try? JSONDecoder.addressAtlas.decode(
          PasskeyCodeExchangeResponse.self, from: data),
        let userId = SyncAccountIdentifier.normalized(decoded.userId),
        SyncSessionToken.isUsable(decoded.sessionToken, forAccountId: userId)
      else {
        throw PasskeyAuthenticationError.invalidExchange
      }
      return PasskeyWebSession(
        userId: userId,
        sessionToken: decoded.sessionToken,
        serverURL: serverURL.absoluteString
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as PasskeyAuthenticationError {
      throw error
    } catch {
      throw PasskeyAuthenticationError.invalidExchange
    }
  }

  private static func isValidAuthorizationCode(_ value: String) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= maximumAuthorizationCodeByteCount else { return false }
    return bytes.allSatisfy { byte in
      (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
        || byte == 45 || byte == 46 || byte == 95
    }
  }

  private static func isJSONResponse(_ response: HTTPURLResponse) -> Bool {
    guard let contentType = response.value(forHTTPHeaderField: "content-type") else { return false }
    return contentType.split(separator: ";", maxSplits: 1).first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() == "application/json"
  }

  private static func hasNoStoreDirective(_ response: HTTPURLResponse) -> Bool {
    guard let cacheControl = response.value(forHTTPHeaderField: "cache-control") else { return false }
    return cacheControl.split(separator: ",").contains { directive in
      directive.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "no-store"
    }
  }
}
