import CryptoKit
import Foundation
import SQLite3
import XCTest

@testable import AddressAtlasCore

final class SyncClientTests: XCTestCase {
  func testSyncClientRevokesOnlyCurrentSessionWithAuthenticatedDelete() async throws {
    let token = testSessionToken(accountId: "11111111-1111-4111-8111-111111111111")
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.url?.absoluteString, "https://sync.example/account/session")
      XCTAssertEqual(request.httpMethod, "DELETE")
      XCTAssertEqual(request.value(forHTTPHeaderField: "accept"), "application/json")
      XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer \(token)")
      XCTAssertNil(request.value(forHTTPHeaderField: "x-address-atlas-confirm"))
      XCTAssertNil(request.httpBody)
      return (Data(#"{"ok":true}"#.utf8), httpResponse(for: request))
    }
    let client = ZeroKnowledgeSyncClient(
      baseURL: URL(string: "https://sync.example")!,
      http: http
    )
    await client.setBearerToken(token)

    try await client.revokeCurrentSession()
  }

  func testSyncClientDeletesAccountWithFixedConfirmationHeader() async throws {
    let operationKey = Base64URL.encode(Data(repeating: 7, count: 32))
    let token = testSessionToken(accountId: "11111111-1111-4111-8111-111111111111")
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.url?.absoluteString, "https://sync.example/account")
      XCTAssertEqual(request.httpMethod, "DELETE")
      XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer \(token)")
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "x-address-atlas-confirm"),
        "delete-account"
      )
      XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), operationKey)
      XCTAssertNil(request.httpBody)
      return (Data(#"{"ok":true}"#.utf8), httpResponse(for: request))
    }
    let client = ZeroKnowledgeSyncClient(
      baseURL: URL(string: "https://sync.example")!,
      http: http
    )
    await client.setBearerToken(token)

    try await client.deleteAccount(idempotencyKey: operationKey)
  }

  func testAccountDeletionReceiptCanReplayWithoutADeletedBearerGrant() async throws {
    let operationKey = Base64URL.encode(Data(repeating: 9, count: 32))
    let http = StubHTTPClient { request in
      XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
      XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), operationKey)
      return (Data(#"{"ok":true}"#.utf8), httpResponse(for: request))
    }
    let client = ZeroKnowledgeSyncClient(
      baseURL: URL(string: "https://sync.example")!,
      http: http
    )

    try await client.deleteAccount(idempotencyKey: operationKey)
  }

  func testAccountDeletionRejectsNonCanonicalOperationKeyBeforeHTTP() async throws {
    let http = StubHTTPClient { request in
      XCTFail("Invalid operation key must not reach HTTP: \(request)")
      throw URLError(.badURL)
    }
    let client = ZeroKnowledgeSyncClient(
      baseURL: URL(string: "https://sync.example")!,
      http: http
    )

    do {
      try await client.deleteAccount(idempotencyKey: "not-a-32-byte-operation")
      XCTFail("Expected invalid operation rejection.")
    } catch SyncClientError.requestFailed(let statusCode, _) {
      XCTAssertEqual(statusCode, 400)
    }
  }

  func testSyncLifecycleDeleteFailsClosedWithoutAuthenticationOrValidAcknowledgement() async throws
  {
    let unauthenticatedHTTP = StubHTTPClient { request in
      XCTFail("Unauthenticated lifecycle operations must not reach HTTP: \(request)")
      throw URLError(.userAuthenticationRequired)
    }
    let unauthenticatedClient = ZeroKnowledgeSyncClient(
      baseURL: URL(string: "https://sync.example")!,
      http: unauthenticatedHTTP
    )

    do {
      try await unauthenticatedClient.revokeCurrentSession()
      XCTFail("Expected missing authentication to fail locally.")
    } catch SyncClientError.authenticationRequired {
      // Expected; the HTTP stub above proves no request escaped.
    }

    let falseAcknowledgementHTTP = StubHTTPClient { request in
      return (Data(#"{"ok":false}"#.utf8), httpResponse(for: request))
    }
    let client = ZeroKnowledgeSyncClient(
      baseURL: URL(string: "https://sync.example")!,
      http: falseAcknowledgementHTTP
    )

    await client.setBearerToken(
      testSessionToken(accountId: "11111111-1111-4111-8111-111111111111")
    )
    do {
      try await client.revokeCurrentSession()
      XCTFail("Expected a false server acknowledgement to fail closed.")
    } catch SyncClientError.requestFailed(let statusCode, let message) {
      XCTAssertEqual(statusCode, 502)
      XCTAssertEqual(message, "Sync server returned an invalid response.")
    }
  }

  func testSyncClientDecodesFractionalServerTimestamps() async throws {
    let snapshot = RemoteVaultSnapshot(
      version: 1,
      envelope: EncryptedVaultEnvelope(
        keyId: "sync-v1",
        nonce: "AA",
        ciphertext: "AA",
        checksum: String(repeating: "a", count: 64),
        createdAt: Date(timeIntervalSince1970: 0)
      ),
      byteSize: 2,
      checksum: String(repeating: "b", count: 64),
      updatedAt: Date(timeIntervalSince1970: 0)
    )
    var wireObject = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: JSONEncoder.addressAtlas.encode(snapshot))
        as? [String: Any]
    )
    wireObject["updatedAt"] = "2026-07-12T12:34:56.789Z"
    var envelopeObject = try XCTUnwrap(wireObject["envelope"] as? [String: Any])
    envelopeObject["createdAt"] = "2026-07-12T12:34:56Z"
    wireObject["envelope"] = envelopeObject
    let wireData = try JSONSerialization.data(withJSONObject: wireObject)
    let http = StubHTTPClient { request in
      (wireData, httpResponse(for: request))
    }
    let client = ZeroKnowledgeSyncClient(baseURL: URL(string: "https://sync.example")!, http: http)

    let response = try await client.latestVault()
    let decoded = try XCTUnwrap(response)

    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let expected = try XCTUnwrap(fractionalFormatter.date(from: "2026-07-12T12:34:56.789Z"))
    XCTAssertEqual(
      decoded.updatedAt.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.000_001)
    let wholeSecondsFormatter = ISO8601DateFormatter()
    wholeSecondsFormatter.formatOptions = [.withInternetDateTime]
    XCTAssertEqual(
      decoded.envelope.createdAt,
      try XCTUnwrap(wholeSecondsFormatter.date(from: "2026-07-12T12:34:56Z"))
    )
  }

  func testSyncClientDecodesServerShapedVaultLatestResponse() async throws {
    // Literal JSON mirroring the GET /vault/latest response built in
    // src/app/vault/latest/route.ts:66-75: `envelope` is the raw jsonb object
    // stored at upload time and `updatedAt` is a Postgres Date rendered with
    // JS toISOString(), which always includes fractional seconds. This fixture
    // is deliberately NOT produced by re-encoding the Swift model, so a codec
    // drift between the server wire shape and RemoteVaultSnapshot fails here.
    let json = """
      {
        "version": 7,
        "envelope": {
          "schemaVersion": 2,
          "cryptoVersion": 2,
          "keyId": "sync-v2",
          "nonce": "AAAAAAAAAAAAAAAA",
          "ciphertext": "AAAA",
          "checksum": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          "createdAt": "2026-07-12T09:15:04Z"
        },
        "byteSize": 4096,
        "checksum": "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
        "updatedAt": "2026-07-13T08:30:15.123Z"
      }
      """
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.url?.path, "/vault/latest")
      return (Data(json.utf8), httpResponse(for: request))
    }
    let client = ZeroKnowledgeSyncClient(baseURL: URL(string: "https://sync.example")!, http: http)

    let response = try await client.latestVault()
    let decoded = try XCTUnwrap(response)

    XCTAssertEqual(decoded.version, 7)
    XCTAssertEqual(decoded.byteSize, 4096)
    XCTAssertEqual(
      decoded.checksum,
      "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
    )
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    XCTAssertEqual(
      decoded.updatedAt,
      try XCTUnwrap(fractionalFormatter.date(from: "2026-07-13T08:30:15.123Z"))
    )
    XCTAssertEqual(decoded.envelope.schemaVersion, 2)
    XCTAssertEqual(decoded.envelope.cryptoVersion, 2)
    XCTAssertEqual(decoded.envelope.keyId, "sync-v2")
    XCTAssertEqual(decoded.envelope.nonce, "AAAAAAAAAAAAAAAA")
    XCTAssertEqual(decoded.envelope.ciphertext, "AAAA")
    XCTAssertEqual(
      decoded.envelope.checksum,
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    )
    let wholeSecondsFormatter = ISO8601DateFormatter()
    wholeSecondsFormatter.formatOptions = [.withInternetDateTime]
    XCTAssertEqual(
      decoded.envelope.createdAt,
      try XCTUnwrap(wholeSecondsFormatter.date(from: "2026-07-12T09:15:04Z"))
    )
  }

  func testSyncClientSurfacesExpiredSession() async throws {
    let token = testSessionToken(accountId: "11111111-1111-4111-8111-111111111111")
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer \(token)")
      let json = """
        { "error": "Token expired." }
        """
      return (Data(json.utf8), httpResponse(for: request, statusCode: 401))
    }
    let client = ZeroKnowledgeSyncClient(baseURL: URL(string: "https://sync.example")!, http: http)
    await client.setBearerToken(token)

    do {
      _ = try await client.latestVault()
      XCTFail("Expected expired session to throw.")
    } catch SyncClientError.authenticationRequired(let message) {
      XCTAssertEqual(message, "Token expired.")
    }
  }

  func testSyncClientDropsHeaderUnsafeOrOversizedBearerTokens() async throws {
    for token in [
      "unsafe\r\nheader",
      String(repeating: "a", count: SyncSessionToken.maximumUTF8ByteCount + 1),
    ] {
      let http = StubHTTPClient { request in
        XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
        return (
          Data("{\"error\":\"Authentication required.\"}".utf8),
          httpResponse(for: request, statusCode: 401)
        )
      }
      let client = ZeroKnowledgeSyncClient(
        baseURL: URL(string: "https://sync.example")!,
        http: http
      )
      await client.setBearerToken(token)

      do {
        _ = try await client.latestVault()
        XCTFail("Expected authentication failure.")
      } catch SyncClientError.authenticationRequired {
        // Expected; the request assertion above proves the invalid token was not sent.
      } catch {
        XCTFail("Expected authenticationRequired, got \(error).")
      }
    }
  }

  func testSyncClientSurfacesStaleUploadConflict() async throws {
    let token = testSessionToken(accountId: "11111111-1111-4111-8111-111111111111")
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.httpMethod, "PUT")
      let json = """
        { "error": "Remote vault snapshot is newer. Download before uploading again." }
        """
      return (Data(json.utf8), httpResponse(for: request, statusCode: 409))
    }
    let snapshot = RemoteVaultSnapshot(
      version: 1,
      envelope: EncryptedVaultEnvelope(
        keyId: "sync-v1",
        nonce: "abc",
        ciphertext: "ciphertext",
        checksum: String(repeating: "a", count: 64)
      ),
      byteSize: 128,
      checksum: String(repeating: "b", count: 64)
    )
    let client = ZeroKnowledgeSyncClient(baseURL: URL(string: "https://sync.example")!, http: http)
    await client.setBearerToken(token)

    do {
      try await client.upload(snapshot: snapshot)
      XCTFail("Expected stale upload conflict.")
    } catch SyncClientError.requestFailed(let statusCode, let message) {
      XCTAssertEqual(statusCode, 409)
      XCTAssertTrue(message.contains("Remote vault snapshot is newer"))
    }
  }

  func testSyncClientSanitizesAndBoundsUntrustedServerErrors() async throws {
    let rawSecret = String(repeating: "s", count: 80)
    let json = try JSONSerialization.data(withJSONObject: [
      "error":
        "authorization: Bearer \(rawSecret)\napi_key=\(rawSecret) \(String(repeating: "x", count: 2_000))"
    ])
    let http = StubHTTPClient { request in
      (json, httpResponse(for: request, statusCode: 500))
    }
    let client = ZeroKnowledgeSyncClient(baseURL: URL(string: "https://sync.example")!, http: http)

    do {
      _ = try await client.latestVault()
      XCTFail("Expected server error.")
    } catch SyncClientError.requestFailed(let statusCode, let message) {
      XCTAssertEqual(statusCode, 500)
      XCTAssertFalse(message.contains(rawSecret))
      XCTAssertFalse(message.contains("\n"))
      XCTAssertTrue(message.contains("[redacted]"))
      XCTAssertLessThanOrEqual(
        message.unicodeScalars.count,
        ProviderErrorSanitizer.maximumScalarCount + 1
      )
    }
  }

  func testSyncClientDoesNotDecodeOversizedErrorBodies() async throws {
    let oversized = Data(
      "{\"error\":\"\(String(repeating: "x", count: 20_000))\"}".utf8
    )
    let http = StubHTTPClient { request in
      (oversized, httpResponse(for: request, statusCode: 503))
    }
    let client = ZeroKnowledgeSyncClient(baseURL: URL(string: "https://sync.example")!, http: http)

    do {
      _ = try await client.latestVault()
      XCTFail("Expected server error.")
    } catch SyncClientError.requestFailed(let statusCode, let message) {
      XCTAssertEqual(statusCode, 503)
      XCTAssertEqual(message, HTTPURLResponse.localizedString(forStatusCode: 503))
    }
  }
}
