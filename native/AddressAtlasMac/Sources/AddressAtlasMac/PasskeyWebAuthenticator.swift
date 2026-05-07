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

@MainActor
final class PasskeyWebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var session: ASWebAuthenticationSession?

  func authenticate(serverURL: URL, mode: PasskeyWebMode) async throws -> PasskeyWebSession {
    var components = URLComponents(url: serverURL.appending(path: "auth/native"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "mode", value: mode.rawValue),
      URLQueryItem(name: "callback", value: "address-atlas://sync-auth")
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
            continuation.resume(returning: try Self.parse(callbackURL: callbackURL))
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
      webSession.presentationContextProvider = self
      webSession.prefersEphemeralWebBrowserSession = false
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

  private static func parse(callbackURL: URL) throws -> PasskeyWebSession {
    guard callbackURL.scheme == "address-atlas" else {
      throw URLError(.badURL)
    }
    let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? {
      items.first(where: { $0.name == name })?.value
    }
    guard
      let token = value("sessionToken"), !token.isEmpty,
      let userId = value("userId"), !userId.isEmpty,
      let serverURL = value("serverURL"), !serverURL.isEmpty
    else {
      throw URLError(.badServerResponse)
    }
    return PasskeyWebSession(userId: userId, sessionToken: token, serverURL: serverURL)
  }
}
