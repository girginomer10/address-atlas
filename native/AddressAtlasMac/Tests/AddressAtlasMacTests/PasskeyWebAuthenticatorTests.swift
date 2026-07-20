import AddressAtlasCore
import Foundation
import XCTest
@testable import AddressAtlasMac

@MainActor
final class PasskeyWebAuthenticatorTests: XCTestCase {
  private let validUserId = "11111111-1111-4111-8111-111111111111"

  func testCallbackIsBoundToExpectedCanonicalServerOrigin() throws {
    let expected = try XCTUnwrap(URL(string: "https://sync.example.com"))
    let callback = try callbackURL(serverURL: "HTTPS://SYNC.EXAMPLE.COM:443/", state: "request-state")

    let session = try PasskeyWebAuthenticator.parse(
      callbackURL: callback,
      expectedState: "request-state",
      expectedServerURL: expected
    )

    XCTAssertEqual(session.userId, validUserId)
    XCTAssertEqual(session.sessionToken, "token-1")
    XCTAssertEqual(session.serverURL, expected.absoluteString)
  }

  func testCallbackCanonicalizesWhitespaceAndCaseAroundValidUUID() throws {
    let expected = try XCTUnwrap(URL(string: "https://sync.example.com"))
    let callback = try callbackURL(
      serverURL: expected.absoluteString,
      state: "request-state",
      userId: "  \(validUserId.uppercased())\n"
    )

    let session = try PasskeyWebAuthenticator.parse(
      callbackURL: callback,
      expectedState: "request-state",
      expectedServerURL: expected
    )

    XCTAssertEqual(session.userId, validUserId)
  }

  func testCallbackRejectsMalformedOversizedAndNonRFCVariantUserIDs() throws {
    let expected = try XCTUnwrap(URL(string: "https://sync.example.com"))
    let invalidUserIds = [
      "user-1",
      String(repeating: "a", count: 201),
      "11111111-1111-0111-8111-111111111111",
      "11111111-1111-4111-7111-111111111111"
    ]

    for userId in invalidUserIds {
      let callback = try callbackURL(
        serverURL: expected.absoluteString,
        state: "request-state",
        userId: userId
      )
      XCTAssertThrowsError(
        try PasskeyWebAuthenticator.parse(
          callbackURL: callback,
          expectedState: "request-state",
          expectedServerURL: expected
        ),
        "Unexpectedly accepted user ID: \(userId)"
      )
    }
  }

  func testCallbackRejectsHeaderUnsafeAndOversizedSessionTokens() throws {
    let expected = try XCTUnwrap(URL(string: "https://sync.example.com"))
    for token in [
      "unsafe\r\nheader",
      "contains a space",
      String(repeating: "a", count: SyncSessionToken.maximumUTF8ByteCount + 1)
    ] {
      var components = URLComponents()
      components.scheme = "address-atlas"
      components.host = "sync-auth"
      components.queryItems = [
        URLQueryItem(name: "state", value: "request-state"),
        URLQueryItem(name: "sessionToken", value: token),
        URLQueryItem(name: "userId", value: validUserId),
        URLQueryItem(name: "serverURL", value: expected.absoluteString)
      ]
      let callback = try XCTUnwrap(components.url)

      XCTAssertThrowsError(try PasskeyWebAuthenticator.parse(
        callbackURL: callback,
        expectedState: "request-state",
        expectedServerURL: expected
      ))
    }
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

  func testCallbackRejectsUnexpectedAuthorityComponentsAndDuplicateParameters() throws {
    let expected = try XCTUnwrap(URL(string: "https://sync.example.com"))
    let encodedServer = "https%3A%2F%2Fsync.example.com"
    let invalidCallbacks = [
      "address-atlas://user@sync-auth?state=request-state&sessionToken=token-1&userId=\(validUserId)&serverURL=\(encodedServer)",
      "address-atlas://sync-auth:443?state=request-state&sessionToken=token-1&userId=\(validUserId)&serverURL=\(encodedServer)",
      "address-atlas://sync-auth/extra?state=request-state&sessionToken=token-1&userId=\(validUserId)&serverURL=\(encodedServer)",
      "address-atlas://sync-auth?state=request-state&sessionToken=token-1&userId=\(validUserId)&serverURL=\(encodedServer)#fragment",
      "address-atlas://sync-auth?state=request-state&state=request-state&sessionToken=token-1&userId=\(validUserId)&serverURL=\(encodedServer)"
    ]

    for rawURL in invalidCallbacks {
      let callback = try XCTUnwrap(URL(string: rawURL))
      XCTAssertThrowsError(
        try PasskeyWebAuthenticator.parse(
          callbackURL: callback,
          expectedState: "request-state",
          expectedServerURL: expected
        ),
        "Unexpectedly accepted callback: \(rawURL)"
      )
    }
  }

  private func callbackURL(
    serverURL: String,
    state: String,
    userId: String? = nil
  ) throws -> URL {
    var components = URLComponents()
    components.scheme = "address-atlas"
    components.host = "sync-auth"
    components.queryItems = [
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "sessionToken", value: "token-1"),
      URLQueryItem(name: "userId", value: userId ?? validUserId),
      URLQueryItem(name: "serverURL", value: serverURL)
    ]
    return try XCTUnwrap(components.url)
  }
}
