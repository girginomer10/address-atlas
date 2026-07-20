import AddressAtlasCore
import AppKit
import AuthenticationServices
import Foundation

struct PasskeyWebSession: Sendable {
  var userId: String
  var sessionToken: String
  var serverURL: String
}

enum PasskeyWebMode: String, Sendable {
  case register
  case authenticate
}

/// Injection seam for AppState behavior tests. Production always uses the real
/// ASWebAuthenticationSession ceremony implemented by PasskeyWebAuthenticator.
@MainActor
protocol PasskeyAuthenticating {
  func authenticate(serverURL: URL, mode: PasskeyWebMode) async throws -> PasskeyWebSession
}

@MainActor
final class PasskeyWebAuthenticator: NSObject, PasskeyAuthenticating, ASWebAuthenticationPresentationContextProviding {
  private var session: ASWebAuthenticationSession?

  func authenticate(serverURL: URL, mode: PasskeyWebMode) async throws -> PasskeyWebSession {
    let state = UUID().uuidString
    var components = URLComponents(url: serverURL.appending(path: "auth/native"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "mode", value: mode.rawValue),
      URLQueryItem(name: "callback", value: "address-atlas://sync-auth"),
      URLQueryItem(name: "state", value: state)
    ]
    guard let authURL = components?.url else {
      throw URLError(.badURL)
    }

    return try await withCheckedThrowingContinuation { continuation in
      let webSession = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "address-atlas") { [weak self] callbackURL, error in
        Task { @MainActor in
          self?.session = nil
          if let error {
            continuation.resume(throwing: error)
            return
          }
          guard let callbackURL else {
            continuation.resume(throwing: URLError(.badServerResponse))
            return
          }
          do {
            continuation.resume(returning: try Self.parse(
              callbackURL: callbackURL,
              expectedState: state,
              expectedServerURL: serverURL
            ))
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
      webSession.presentationContextProvider = self
      // The passkey ceremony does not require Safari cookies. Avoid retaining
      // or reusing web-session state on shared Macs.
      webSession.prefersEphemeralWebBrowserSession = true
      session = webSession
      if !webSession.start() {
        session = nil
        continuation.resume(throwing: URLError(.cannotLoadFromNetwork))
      }
    }
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
  }

  static func parse(
    callbackURL: URL,
    expectedState: String,
    expectedServerURL: URL
  ) throws -> PasskeyWebSession {
    // Accept exactly the callback registered with ASWebAuthenticationSession.
    // Userinfo, ports, paths, and fragments are not part of that callback and
    // accepting them would make authority validation needlessly ambiguous.
    guard callbackURL.scheme == "address-atlas",
          callbackURL.host == "sync-auth",
          callbackURL.user == nil,
          callbackURL.password == nil,
          callbackURL.port == nil,
          callbackURL.path.isEmpty,
          callbackURL.fragment == nil
    else {
      throw URLError(.badURL)
    }
    let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? {
      let matches = items.filter { $0.name == name }
      return matches.count == 1 ? matches[0].value : nil
    }
    // Bind the callback to the request we started (CSRF / replay protection).
    guard let returnedState = value("state"), returnedState == expectedState else {
      throw URLError(.badServerResponse)
    }
    guard
      let token = value("sessionToken"), SyncSessionToken.isValid(token),
      let rawUserId = value("userId"),
      let userId = SyncAccountIdentifier.normalized(rawUserId),
      let serverURL = value("serverURL"), !serverURL.isEmpty
    else {
      throw URLError(.badServerResponse)
    }
    guard let returnedOrigin = SyncServerURL.validatedOrigin(serverURL),
          returnedOrigin.absoluteString == expectedServerURL.absoluteString
    else {
      throw URLError(.badServerResponse)
    }
    return PasskeyWebSession(
      userId: userId,
      sessionToken: token,
      serverURL: expectedServerURL.absoluteString
    )
  }
}
