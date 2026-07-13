import Foundation
import XCTest
@testable import AddressAtlasMac

@MainActor
final class PasskeyWebAuthenticatorTests: XCTestCase {
  func testCallbackIsBoundToExpectedCanonicalServerOrigin() throws {
    let expected = try XCTUnwrap(URL(string: "https://sync.example.com"))
    let callback = try callbackURL(serverURL: "HTTPS://SYNC.EXAMPLE.COM:443/", state: "request-state")

    let session = try PasskeyWebAuthenticator.parse(
      callbackURL: callback,
      expectedState: "request-state",
      expectedServerURL: expected
    )

    XCTAssertEqual(session.userId, "user-1")
    XCTAssertEqual(session.sessionToken, "token-1")
    XCTAssertEqual(session.serverURL, expected.absoluteString)
  }

  func testCallbackRejectsDifferentServerOrigin() throws {
    let expected = try XCTUnwrap(URL(string: "https://sync.example.com"))
    let callback = try callbackURL(serverURL: "https://attacker.example", state: "request-state")

    XCTAssertThrowsError(
      try PasskeyWebAuthenticator.parse(
        callbackURL: callback,
        expectedState: "request-state",
        expectedServerURL: expected
      )
    )
  }

  func testCallbackRejectsWrongStateAndAuthority() throws {
    let expected = try XCTUnwrap(URL(string: "https://sync.example.com"))
    let wrongState = try callbackURL(serverURL: expected.absoluteString, state: "wrong-state")
    let wrongAuthority = try XCTUnwrap(URL(string: "address-atlas://other?state=request-state&sessionToken=token-1&userId=user-1&serverURL=https%3A%2F%2Fsync.example.com"))

    XCTAssertThrowsError(
      try PasskeyWebAuthenticator.parse(
        callbackURL: wrongState,
        expectedState: "request-state",
        expectedServerURL: expected
      )
    )
    XCTAssertThrowsError(
      try PasskeyWebAuthenticator.parse(
        callbackURL: wrongAuthority,
        expectedState: "request-state",
        expectedServerURL: expected
      )
    )
  }

  private func callbackURL(serverURL: String, state: String) throws -> URL {
    var components = URLComponents()
    components.scheme = "address-atlas"
    components.host = "sync-auth"
    components.queryItems = [
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "sessionToken", value: "token-1"),
      URLQueryItem(name: "userId", value: "user-1"),
      URLQueryItem(name: "serverURL", value: serverURL)
    ]
    return try XCTUnwrap(components.url)
  }
}
