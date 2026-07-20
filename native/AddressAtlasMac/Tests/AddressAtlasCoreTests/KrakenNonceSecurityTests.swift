import CryptoKit
import Foundation
import XCTest

@testable import AddressAtlasCore

final class KrakenNonceSecurityTests: XCTestCase {
  func testKrakenNonceGeneratorIsMonotonicAcrossIndependentInstancesAndClockRegression()
    async throws
  {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let firstGenerator = fixture.makeGenerator()
    let secondGenerator = fixture.makeGenerator()
    let deviceIdentifier = try await firstGenerator.deviceIdentifier()
    let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    let apiKey = "same-key-that-must-not-appear-in-local-state"
    let concurrent = try await withThrowingTaskGroup(of: String.self, returning: [String].self) {
      group in
      for index in 0..<16 {
        let generator = index.isMultiple(of: 2) ? firstGenerator : secondGenerator
        group.addTask {
          try await generator.next(
            apiKey: apiKey,
            at: baseDate,
            expectedDeviceIdentifier: deviceIdentifier
          )
        }
      }
      var values: [String] = []
      for try await value in group { values.append(value) }
      return values
    }
    let sorted = concurrent.compactMap(Int64.init).sorted()
    let first = Int64(1_700_000_000_000)
    let regressed = try await secondGenerator.next(
      apiKey: apiKey,
      at: baseDate.addingTimeInterval(-60),
      expectedDeviceIdentifier: deviceIdentifier
    )
    let otherKey = try await firstGenerator.next(
      apiKey: "different-key",
      at: baseDate,
      expectedDeviceIdentifier: deviceIdentifier
    )

    XCTAssertEqual(sorted, Array(first..<(first + 16)))
    XCTAssertEqual(regressed, String(first + 16))
    XCTAssertEqual(otherKey, String(first))
    let stateText = try String(contentsOf: fixture.stateURL, encoding: .utf8)
    XCTAssertFalse(stateText.contains(apiKey))
    let statePermissions =
      try XCTUnwrap(
        FileManager.default.attributesOfItem(atPath: fixture.stateURL.path)[.posixPermissions]
          as? NSNumber
      ).intValue & 0o777
    let directoryPermissions =
      try XCTUnwrap(
        FileManager.default.attributesOfItem(atPath: fixture.directory.path)[.posixPermissions]
          as? NSNumber
      ).intValue & 0o777
    XCTAssertEqual(statePermissions, 0o600)
    XCTAssertEqual(directoryPermissions, 0o700)
  }

  func testKrakenNonceGeneratorCoordinatesAcrossClientInstances() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      if request.url?.path == "/0/private/Balance" {
        return scannerResponse(request, #"{"error":[],"result":{}}"#)
      }
      return scannerResponse(request, #"{"error":[],"result":{}}"#)
    }
    let now: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }
    let firstClient = NativeExchangeBalanceClient(
      http: http,
      now: now,
      krakenNonceGenerator: fixture.makeGenerator()
    )
    let secondClient = NativeExchangeBalanceClient(
      http: http,
      now: now,
      krakenNonceGenerator: fixture.makeGenerator()
    )
    let credentials = ExchangeCredentials(
      apiKey: "nonce-test-\(UUID().uuidString)",
      secret: Data("secret".utf8).base64EncodedString()
    )

    async let firstBalance = firstClient.fetchBalance(provider: .kraken, credentials: credentials)
    async let secondBalance = secondClient.fetchBalance(provider: .kraken, credentials: credentials)
    _ = try await (firstBalance, secondBalance)

    let nonces = requests.snapshot().compactMap { request -> Int64? in
      guard request.url?.path == "/0/private/Balance",
        let body = request.httpBody.flatMap({ String(data: $0, encoding: .utf8) }),
        body.hasPrefix("nonce=")
      else { return nil }
      return Int64(body.dropFirst("nonce=".count))
    }.sorted()
    XCTAssertEqual(nonces.count, 2)
    XCTAssertEqual(nonces[1], nonces[0] + 1)
  }

  func testCopiedKrakenStateRotatesLocallyButCannotAuthorizeSourceInstallation() async throws {
    let apiKey = "copied-state-api-key"
    let credentials = ExchangeCredentials(
      apiKey: apiKey,
      secret: Data("secret".utf8).base64EncodedString()
    )
    let source = try krakenStateFixture(secret: Data(repeating: 0x11, count: 32))
    defer { try? FileManager.default.removeItem(at: source.directory) }
    let sourceGenerator = source.makeGenerator()
    let sourceIdentifier = try await sourceGenerator.deviceIdentifier()
    _ = try await sourceGenerator.next(
      apiKey: apiKey,
      at: Date(timeIntervalSince1970: 1_700_000_000),
      expectedDeviceIdentifier: sourceIdentifier
    )
    let copiedBytes = try Data(contentsOf: source.stateURL)
    let copiedText = String(decoding: copiedBytes, as: UTF8.self)
    XCTAssertFalse(copiedText.contains(apiKey))
    XCTAssertFalse(copiedText.contains("credentialIdentifierKey"))
    XCTAssertFalse(copiedText.contains(Data(repeating: 0x11, count: 32).base64EncodedString()))

    // Cover both a fresh Mac with no Keychain item and an established Mac with
    // a different device-only item. Each replaces the unusable copied file,
    // but neither can adopt its identity or send under its old binding.
    let destinationSecrets: [Data?] = [nil, Data(repeating: 0x22, count: 32)]
    for destinationSecret in destinationSecrets {
      let destination = try krakenStateFixture(secret: destinationSecret)
      defer { try? FileManager.default.removeItem(at: destination.directory) }
      try copiedBytes.write(to: destination.stateURL, options: .withoutOverwriting)
      let requests = ScannerRequestLog()
      let client = NativeExchangeBalanceClient(
        http: ScannerHTTPStub { request in
          _ = requests.append(request)
          return scannerResponse(request, #"{"error":[],"result":{}}"#)
        },
        now: { Date(timeIntervalSince1970: 1_699_999_000) },
        krakenNonceGenerator: destination.makeGenerator()
      )

      do {
        _ = try await client.fetchBalance(
          provider: .kraken,
          credentials: credentials,
          krakenDeviceIdentifier: sourceIdentifier
        )
        XCTFail("A copied JSON state must not authorize its source device binding.")
      } catch {
        XCTAssertEqual(error as? KrakenNonceError, .localStateChanged)
      }

      XCTAssertEqual(requests.snapshot().count, 0)
      let replacementBytes = try Data(contentsOf: destination.stateURL)
      XCTAssertNotEqual(replacementBytes, copiedBytes)
      let replacement = try XCTUnwrap(
        JSONSerialization.jsonObject(with: replacementBytes) as? [String: Any]
      )
      let replacementIdentifier = try XCTUnwrap(replacement["deviceIdentifier"] as? String)
      XCTAssertNotEqual(replacementIdentifier, sourceIdentifier)
      XCTAssertEqual(replacement["version"] as? Int, 2)
      XCTAssertEqual((replacement["lastNonceByCredential"] as? [String: String])?.count, 0)
      if let destinationSecret {
        XCTAssertEqual(destination.secretStore.snapshotSecret(), destinationSecret)
      } else {
        XCTAssertEqual(destination.secretStore.snapshotSecret()?.count, 32)
      }
      let persistedReplacementIdentifier = try await destination.makeGenerator().deviceIdentifier()
      XCTAssertEqual(persistedReplacementIdentifier, replacementIdentifier)

      _ = try await client.fetchBalance(
        provider: .kraken,
        credentials: ExchangeCredentials(
          apiKey: "replacement-key-\(destinationSecret == nil ? "fresh" : "established")",
          secret: Data("replacement-secret".utf8).base64EncodedString()
        ),
        krakenDeviceIdentifier: replacementIdentifier
      )
      XCTAssertEqual(requests.snapshot().count, 2)
    }
  }

  func testKrakenInstallationSecretStoreFailuresFailClosedBeforeHTTP() async throws {
    for failureMode in [
      ScannerKrakenInstallationSecretStore.FailureMode.load,
      .save,
    ] {
      let fixture = try krakenStateFixture()
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      fixture.secretStore.setFailureMode(failureMode)
      let requests = ScannerRequestLog()
      let client = NativeExchangeBalanceClient(
        http: ScannerHTTPStub { request in
          _ = requests.append(request)
          return scannerResponse(request, #"{"error":[],"result":{}}"#)
        },
        krakenNonceGenerator: fixture.makeGenerator()
      )

      do {
        _ = try await client.fetchBalance(
          provider: .kraken,
          credentials: ExchangeCredentials(
            apiKey: "keychain-failure-key",
            secret: Data("secret".utf8).base64EncodedString()
          ),
          krakenDeviceIdentifier: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        )
        XCTFail("Keychain failures must prevent Kraken request generation.")
      } catch {
        XCTAssertEqual(error as? KrakenNonceError, .localStateUnavailable)
      }

      XCTAssertEqual(requests.snapshot().count, 0)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stateURL.path))
      XCTAssertNil(fixture.secretStore.snapshotSecret())
    }

    let existing = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: existing.directory) }
    let generator = existing.makeGenerator()
    let identifier = try await generator.deviceIdentifier()
    let originalState = try Data(contentsOf: existing.stateURL)
    existing.secretStore.setFailureMode(.load)
    do {
      _ = try await generator.next(
        apiKey: "existing-state-key",
        at: Date(timeIntervalSince1970: 1_700_000_000),
        expectedDeviceIdentifier: identifier
      )
      XCTFail("An existing v2 state must not bypass a Keychain load failure.")
    } catch {
      XCTAssertEqual(error as? KrakenNonceError, .localStateUnavailable)
    }
    XCTAssertEqual(try Data(contentsOf: existing.stateURL), originalState)
  }

  func testMissingKrakenInstallationSecretRotatesBeforeRejectingOldBindingAndRecovers() async throws
  {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let generator = fixture.makeGenerator()
    let originalIdentifier = try await generator.deviceIdentifier()
    _ = try await generator.next(
      apiKey: "old-api-key",
      at: Date(timeIntervalSince1970: 1_700_000_000),
      expectedDeviceIdentifier: originalIdentifier
    )
    fixture.secretStore.removeSecret()

    let requests = ScannerRequestLog()
    let client = NativeExchangeBalanceClient(
      http: ScannerHTTPStub { request in
        _ = requests.append(request)
        return scannerResponse(request, #"{"error":[],"result":{}}"#)
      },
      now: { Date(timeIntervalSince1970: 1_699_999_000) },
      krakenNonceGenerator: generator
    )

    do {
      _ = try await client.fetchBalance(
        provider: .kraken,
        credentials: ExchangeCredentials(
          apiKey: "old-api-key",
          secret: Data("old-secret".utf8).base64EncodedString()
        ),
        krakenDeviceIdentifier: originalIdentifier
      )
      XCTFail("A saved connection must not send after its installation secret disappears.")
    } catch {
      XCTAssertEqual(error as? KrakenNonceError, .localStateChanged)
    }

    XCTAssertEqual(requests.snapshot().count, 0)
    XCTAssertEqual(fixture.secretStore.snapshotSecret()?.count, 32)
    let replacementIdentifier = try await generator.deviceIdentifier()
    XCTAssertNotEqual(replacementIdentifier, originalIdentifier)

    _ = try await client.fetchBalance(
      provider: .kraken,
      credentials: ExchangeCredentials(
        apiKey: "new-read-only-api-key",
        secret: Data("new-secret".utf8).base64EncodedString()
      ),
      krakenDeviceIdentifier: replacementIdentifier
    )
    XCTAssertEqual(requests.snapshot().count, 2)
  }

  func testMalformedOwnedKrakenStateRotatesBeforeRejectingOldBinding() async throws {
    let installationSecret = Data(repeating: 0x55, count: 32)
    let fixture = try krakenStateFixture(secret: installationSecret)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let oldIdentifier = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    try Data(#"{"deviceIdentifier":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}"#.utf8)
      .write(to: fixture.stateURL)
    let requests = ScannerRequestLog()
    let client = NativeExchangeBalanceClient(
      http: ScannerHTTPStub { request in
        _ = requests.append(request)
        return scannerResponse(request, #"{"error":[],"result":{}}"#)
      },
      krakenNonceGenerator: fixture.makeGenerator()
    )

    do {
      _ = try await client.fetchBalance(
        provider: .kraken,
        credentials: ExchangeCredentials(
          apiKey: "old-key",
          secret: Data("secret".utf8).base64EncodedString()
        ),
        krakenDeviceIdentifier: oldIdentifier
      )
      XCTFail("Malformed local state must not authorize a saved old connection.")
    } catch {
      XCTAssertEqual(error as? KrakenNonceError, .localStateChanged)
    }

    XCTAssertEqual(requests.snapshot().count, 0)
    XCTAssertEqual(fixture.secretStore.snapshotSecret(), installationSecret)
    let replacement = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixture.stateURL)) as? [String: Any]
    )
    XCTAssertEqual(replacement["version"] as? Int, 2)
    XCTAssertNotEqual(replacement["deviceIdentifier"] as? String, oldIdentifier)
  }

  func testLegacyCloneableKrakenStateMigratesByRotatingIdentityAndDiscardingNonceMaterial()
    async throws
  {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let legacyIdentifier = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let legacyCredentialID = String(repeating: "b", count: 64)
    let legacy: [String: Any] = [
      "version": 1,
      "deviceIdentifier": legacyIdentifier,
      "credentialIdentifierKey": Data(repeating: 0x44, count: 32).base64EncodedString(),
      "lastNonceByCredential": [legacyCredentialID: "1700000000000"],
    ]
    try JSONSerialization.data(withJSONObject: legacy).write(to: fixture.stateURL)
    let generator = fixture.makeGenerator()

    do {
      _ = try await generator.next(
        apiKey: "legacy-key",
        at: Date(timeIntervalSince1970: 1_699_999_000),
        expectedDeviceIdentifier: legacyIdentifier
      )
      XCTFail("A legacy cloneable identity must never be carried into v2.")
    } catch {
      XCTAssertEqual(error as? KrakenNonceError, .localStateChanged)
    }

    let migratedData = try Data(contentsOf: fixture.stateURL)
    let migrated = try XCTUnwrap(
      JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
    )
    XCTAssertEqual(migrated["version"] as? Int, 2)
    XCTAssertNotEqual(migrated["deviceIdentifier"] as? String, legacyIdentifier)
    XCTAssertNil(migrated["credentialIdentifierKey"])
    XCTAssertEqual((migrated["lastNonceByCredential"] as? [String: String])?.count, 0)
    XCTAssertNotNil(migrated["installationBinding"] as? String)
    XCTAssertNotNil(fixture.secretStore.snapshotSecret())
    let currentIdentifier = try await generator.deviceIdentifier()
    XCTAssertEqual(currentIdentifier, migrated["deviceIdentifier"] as? String)
  }

  func testDeletingKrakenStateInvalidatesExistingDeviceBindingBeforeNonceReuse() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let generator = fixture.makeGenerator()
    let originalIdentifier = try await generator.deviceIdentifier()
    _ = try await generator.next(
      apiKey: "bound-key",
      at: Date(timeIntervalSince1970: 1_700_000_000),
      expectedDeviceIdentifier: originalIdentifier
    )

    try FileManager.default.removeItem(at: fixture.stateURL)

    do {
      _ = try await generator.next(
        apiKey: "bound-key",
        at: Date(timeIntervalSince1970: 1_699_999_000),
        expectedDeviceIdentifier: originalIdentifier
      )
      XCTFail("Deleted state must invalidate the old device binding before sending a lower nonce.")
    } catch {
      XCTAssertEqual(error as? KrakenNonceError, .localStateChanged)
    }
    let replacementIdentifier = try await generator.deviceIdentifier()
    XCTAssertNotEqual(replacementIdentifier, originalIdentifier)
  }

  func testKrakenStateRejectsSymlinkedLockSymlinkedStateAndOversizedState() throws {
    for symlinkTarget in ["state", "lock"] {
      let fixture = try krakenStateFixture()
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      let protectedTarget = fixture.directory.appending(path: "protected-\(symlinkTarget).txt")
      try Data("do-not-touch".utf8).write(to: protectedTarget)
      let link =
        symlinkTarget == "state"
        ? fixture.stateURL
        : fixture.stateURL.appendingPathExtension("lock")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: protectedTarget)

      XCTAssertThrowsError(
        try KrakenDeviceIdentity.currentIdentifier(
          storageURL: fixture.stateURL,
          installationSecretStore: fixture.secretStore
        )
      ) { error in
        XCTAssertEqual(error as? KrakenNonceError, .localStateUnavailable)
      }
      XCTAssertEqual(try String(contentsOf: protectedTarget, encoding: .utf8), "do-not-touch")
    }

    let oversized = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: oversized.directory) }
    try Data(repeating: 0x61, count: 256 * 1_024 + 1).write(to: oversized.stateURL)
    XCTAssertThrowsError(
      try KrakenDeviceIdentity.currentIdentifier(
        storageURL: oversized.stateURL,
        installationSecretStore: oversized.secretStore
      )
    ) { error in
      XCTAssertEqual(error as? KrakenNonceError, .localStateUnavailable)
    }

    let hardLinked = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: hardLinked.directory) }
    _ = try KrakenDeviceIdentity.currentIdentifier(
      storageURL: hardLinked.stateURL,
      installationSecretStore: hardLinked.secretStore
    )
    let originalState = try Data(contentsOf: hardLinked.stateURL)
    let originalSecret = hardLinked.secretStore.snapshotSecret()
    let secondLink = hardLinked.directory.appending(path: "second-state-link.json")
    try FileManager.default.linkItem(at: hardLinked.stateURL, to: secondLink)

    XCTAssertThrowsError(
      try KrakenDeviceIdentity.currentIdentifier(
        storageURL: hardLinked.stateURL,
        installationSecretStore: hardLinked.secretStore
      )
    ) { error in
      XCTAssertEqual(error as? KrakenNonceError, .localStateUnavailable)
    }
    XCTAssertEqual(try Data(contentsOf: hardLinked.stateURL), originalState)
    XCTAssertEqual(try Data(contentsOf: secondLink), originalState)
    XCTAssertEqual(hardLinked.secretStore.snapshotSecret(), originalSecret)

    let futureVersion = try krakenStateFixture(secret: Data(repeating: 0x66, count: 32))
    defer { try? FileManager.default.removeItem(at: futureVersion.directory) }
    let futureBytes = Data(#"{"version":3,"future":"do-not-replace"}"#.utf8)
    try futureBytes.write(to: futureVersion.stateURL)
    XCTAssertThrowsError(
      try KrakenDeviceIdentity.currentIdentifier(
        storageURL: futureVersion.stateURL,
        installationSecretStore: futureVersion.secretStore
      )
    ) { error in
      XCTAssertEqual(error as? KrakenNonceError, .localStateUnavailable)
    }
    XCTAssertEqual(try Data(contentsOf: futureVersion.stateURL), futureBytes)
  }

}
