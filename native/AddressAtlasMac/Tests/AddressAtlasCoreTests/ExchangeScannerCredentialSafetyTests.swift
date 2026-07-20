import CryptoKit
import Foundation
import XCTest

@testable import AddressAtlasCore

final class ExchangeScannerCredentialSafetyTests: XCTestCase {
  func testLegacyUnboundKrakenConnectionDecodesButNeverSendsARequest() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      return scannerResponse(request, #"{"error":[],"result":{}}"#)
    }
    let vaultKey = try VaultCrypto().generateVaultKey()
    let credentialVault = ExchangeCredentialVault()
    let connectionID = UUID()
    let envelope = try credentialVault.seal(
      ExchangeCredentials(
        apiKey: "legacy-key",
        secret: Data("secret".utf8).base64EncodedString()
      ),
      vaultKey: vaultKey,
      connectionId: connectionID
    )
    let legacy = ExchangeConnectionRecord(
      id: connectionID,
      provider: .kraken,
      label: "Legacy Kraken",
      encryptedCredentials: envelope
    )
    let encodedLegacy = try JSONEncoder.addressAtlas.encode(legacy)
    XCTAssertFalse(
      String(decoding: encodedLegacy, as: UTF8.self).contains("krakenDeviceIdentifier"))
    let decodedLegacy = try JSONDecoder.addressAtlas.decode(
      ExchangeConnectionRecord.self,
      from: encodedLegacy
    )
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(
        http: http,
        krakenNonceGenerator: fixture.makeGenerator()
      ),
      krakenDeviceIdentifier: { "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" }
    )

    let result = try await scanner.scanThrowing(connections: [decodedLegacy], vaultKey: vaultKey)

    XCTAssertEqual(requests.snapshot().count, 0)
    XCTAssertEqual(result.connections.first?.status, .failed)
    XCTAssertTrue(result.connections.first?.lastError?.contains("different Kraken API key") == true)
    XCTAssertTrue(result.connections.first?.lastError?.contains("every device") == true)
  }

  func testSyncedDuplicateBinanceAndCoinbaseKeysFailAllBeforeHTTPOrDoubleCounting() async throws {
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      return scannerResponse(request, #"{"balances":[]}"#)
    }
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let credentialVault = ExchangeCredentialVault(crypto: crypto)
    var records: [ExchangeConnectionRecord] = []
    for provider in [ExchangeProvider.binance, .coinbase] {
      for apiKey in [" synced-shared-key ", "synced-shared-key"] {
        let id = UUID()
        records.append(
          ExchangeConnectionRecord(
            id: id,
            provider: provider,
            label: "\(provider.label) duplicate",
            encryptedCredentials: try credentialVault.seal(
              ExchangeCredentials(apiKey: apiKey, secret: "not-used"),
              vaultKey: vaultKey,
              connectionId: id
            )
          ))
      }
    }
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(http: http),
      credentialVault: credentialVault,
      priceProvider: ScannerStaticPriceProvider(values: [:])
    )

    let result = try await scanner.scanThrowing(connections: records, vaultKey: vaultKey)

    XCTAssertEqual(requests.snapshot().count, 0)
    XCTAssertTrue(result.holdings.isEmpty)
    XCTAssertEqual(result.connections.map(\.status), [.failed, .failed, .failed, .failed])
    XCTAssertTrue(
      result.connections.prefix(2).allSatisfy {
        $0.lastError?.contains("same Binance API key") == true
      })
    XCTAssertTrue(
      result.connections.suffix(2).allSatisfy {
        $0.lastError?.contains("same Coinbase API key") == true
      })
  }

  func testConvergedDuplicateKrakenKeyAcrossDeviceBindingsFailsAllBeforeHTTP() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      return scannerResponse(request, #"{"error":[],"result":{}}"#)
    }
    let vaultKey = try VaultCrypto().generateVaultKey()
    let credentialVault = ExchangeCredentialVault()
    let deviceA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let deviceB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let records = try [(deviceA, " shared-key "), (deviceB, "shared-key")].map { device, apiKey in
      let id = UUID()
      return ExchangeConnectionRecord(
        id: id,
        provider: .kraken,
        label: "Kraken \(device)",
        encryptedCredentials: try credentialVault.seal(
          ExchangeCredentials(
            apiKey: apiKey,
            secret: Data("secret".utf8).base64EncodedString()
          ),
          vaultKey: vaultKey,
          connectionId: id
        ),
        krakenDeviceIdentifier: device
      )
    }
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(
        http: http,
        krakenNonceGenerator: fixture.makeGenerator()
      ),
      krakenDeviceIdentifier: { deviceA }
    )

    let result = try await scanner.scanThrowing(connections: records, vaultKey: vaultKey)

    XCTAssertEqual(requests.snapshot().count, 0)
    XCTAssertEqual(result.connections.map(\.status), [.failed, .failed])
    XCTAssertTrue(
      result.connections.allSatisfy {
        $0.lastError?.contains("more than one saved connection") == true
      })
  }

  func testDuplicateKrakenKeyOnSameDeviceFailsAllBeforeHTTPOrDoubleCounting() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      return scannerResponse(request, #"{"error":[],"result":{"XXBT":"1"}}"#)
    }
    let vaultKey = try VaultCrypto().generateVaultKey()
    let credentialVault = ExchangeCredentialVault()
    let localDevice = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let records = try ["same-key", " same-key "].map { apiKey in
      let id = UUID()
      return ExchangeConnectionRecord(
        id: id,
        provider: .kraken,
        label: "Duplicate Kraken",
        encryptedCredentials: try credentialVault.seal(
          ExchangeCredentials(
            apiKey: apiKey,
            secret: Data("secret".utf8).base64EncodedString()
          ),
          vaultKey: vaultKey,
          connectionId: id
        ),
        krakenDeviceIdentifier: localDevice
      )
    }
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(
        http: http,
        krakenNonceGenerator: fixture.makeGenerator()
      ),
      credentialVault: credentialVault,
      priceProvider: ScannerStaticPriceProvider(values: [:]),
      krakenDeviceIdentifier: { localDevice }
    )

    let result = try await scanner.scanThrowing(connections: records, vaultKey: vaultKey)

    XCTAssertEqual(requests.snapshot().count, 0)
    XCTAssertTrue(result.holdings.isEmpty)
    XCTAssertEqual(result.connections.map(\.status), [.failed, .failed])
    XCTAssertTrue(
      result.connections.allSatisfy {
        $0.lastError?.contains("more than one saved connection") == true
      })
  }

  func testBoundKrakenKeyConflictingWithLegacyOrInvalidBindingFailsAllBeforeHTTP() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      return scannerResponse(request, #"{"error":[],"result":{}}"#)
    }
    let vaultKey = try VaultCrypto().generateVaultKey()
    let credentialVault = ExchangeCredentialVault()
    let localDevice = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    func connection(label: String, deviceIdentifier: String?) throws -> ExchangeConnectionRecord {
      let id = UUID()
      return ExchangeConnectionRecord(
        id: id,
        provider: .kraken,
        label: label,
        encryptedCredentials: try credentialVault.seal(
          ExchangeCredentials(
            apiKey: " shared-key ",
            secret: Data("secret".utf8).base64EncodedString()
          ),
          vaultKey: vaultKey,
          connectionId: id
        ),
        krakenDeviceIdentifier: deviceIdentifier
      )
    }

    let records = try [
      connection(label: "Bound Kraken", deviceIdentifier: localDevice),
      connection(label: "Legacy Kraken", deviceIdentifier: nil),
      connection(label: "Invalid Kraken", deviceIdentifier: "not-a-device-uuid"),
    ]
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(
        http: http,
        krakenNonceGenerator: fixture.makeGenerator()
      ),
      credentialVault: credentialVault,
      krakenDeviceIdentifier: { localDevice }
    )

    let result = try await scanner.scanThrowing(connections: records, vaultKey: vaultKey)

    XCTAssertEqual(requests.snapshot().count, 0)
    XCTAssertEqual(result.connections.map(\.status), [.failed, .failed, .failed])
    XCTAssertTrue(
      result.connections.allSatisfy {
        $0.lastError?.contains("more than one saved connection") == true
      })
  }

  func testForeignDeviceKrakenRecordIsSkippedWithoutMutatingSharedVaultState() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let generator = fixture.makeGenerator()
    let localDevice = try await generator.deviceIdentifier()
    let foreignDevice = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    XCTAssertNotEqual(localDevice, foreignDevice)

    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      if request.url?.path == "/0/private/Balance" {
        return scannerResponse(request, #"{"error":[],"result":{}}"#)
      }
      return scannerResponse(request, #"{"error":[],"result":{}}"#)
    }
    let vaultKey = try VaultCrypto().generateVaultKey()
    let credentialVault = ExchangeCredentialVault()

    func connection(
      label: String,
      apiKey: String,
      deviceIdentifier: String,
      status: ScanStatus,
      updatedAt: Date
    ) throws -> ExchangeConnectionRecord {
      let id = UUID()
      return ExchangeConnectionRecord(
        id: id,
        provider: .kraken,
        label: label,
        encryptedCredentials: try credentialVault.seal(
          ExchangeCredentials(
            apiKey: apiKey,
            secret: Data("secret".utf8).base64EncodedString()
          ),
          vaultKey: vaultKey,
          connectionId: id
        ),
        krakenDeviceIdentifier: deviceIdentifier,
        status: status,
        lastTestedAt: Date(timeIntervalSince1970: 100),
        lastSyncAt: Date(timeIntervalSince1970: 90),
        lastError: status == .failed ? "foreign-device-owned status" : nil,
        createdAt: Date(timeIntervalSince1970: 10),
        updatedAt: updatedAt
      )
    }

    let local = try connection(
      label: "Local Kraken",
      apiKey: "local-key",
      deviceIdentifier: localDevice,
      status: .empty,
      updatedAt: Date(timeIntervalSince1970: 200)
    )
    let foreign = try connection(
      label: "Foreign Kraken",
      apiKey: "foreign-key",
      deviceIdentifier: foreignDevice,
      status: .failed,
      updatedAt: Date(timeIntervalSince1970: 300)
    )
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(
        http: http,
        now: { Date(timeIntervalSince1970: 1_700_000_000) },
        krakenNonceGenerator: generator
      ),
      credentialVault: credentialVault,
      priceProvider: ScannerStaticPriceProvider(values: [:]),
      krakenDeviceIdentifier: { localDevice }
    )

    let result = try await scanner.scanThrowing(
      connections: [local, foreign],
      vaultKey: vaultKey
    )

    XCTAssertEqual(result.connections[0].status, .ok)
    XCTAssertEqual(result.connections[1], foreign)
    XCTAssertEqual(
      requests.snapshot().filter { $0.url?.path == "/0/private/Balance" }.count,
      1
    )
    XCTAssertTrue(
      result.warnings.contains {
        $0.contains("Foreign Kraken") && $0.contains("skipped on this Mac")
      })
  }

  func testKrakenScannerCanonicalizesTheLocalDeviceIdentityBeforeComparing() async throws {
    let fixture = try krakenStateFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let generator = fixture.makeGenerator()
    let localDevice = try await generator.deviceIdentifier()
    let requests = ScannerRequestLog()
    let http = ScannerHTTPStub { request in
      _ = requests.append(request)
      return scannerResponse(request, #"{"error":[],"result":{}}"#)
    }
    let vaultKey = try VaultCrypto().generateVaultKey()
    let credentialVault = ExchangeCredentialVault()
    let connectionID = UUID()
    let connection = ExchangeConnectionRecord(
      id: connectionID,
      provider: .kraken,
      label: "Local Kraken",
      encryptedCredentials: try credentialVault.seal(
        ExchangeCredentials(
          apiKey: "local-key",
          secret: Data("secret".utf8).base64EncodedString()
        ),
        vaultKey: vaultKey,
        connectionId: connectionID
      ),
      krakenDeviceIdentifier: localDevice
    )
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(
        http: http,
        krakenNonceGenerator: generator
      ),
      credentialVault: credentialVault,
      priceProvider: ScannerStaticPriceProvider(values: [:]),
      krakenDeviceIdentifier: { "  \(localDevice.uppercased())  " }
    )

    let result = try await scanner.scanThrowing(connections: [connection], vaultKey: vaultKey)

    XCTAssertEqual(result.connections.first?.status, .ok)
    XCTAssertEqual(requests.snapshot().filter { $0.url?.path == "/0/private/Balance" }.count, 1)
  }

}
