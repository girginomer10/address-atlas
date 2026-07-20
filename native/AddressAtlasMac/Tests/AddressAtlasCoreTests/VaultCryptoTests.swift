import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import AddressAtlasCore

final class VaultCryptoTests: XCTestCase {
  func testVaultEncryptionRoundTripsAndRejectsWrongKey() throws {
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let key = try crypto.deriveKey(from: vaultKey, purpose: .syncBlob)
    let document = VaultDocument(wallets: [
      WalletRecord(label: "Vitalik", address: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", chainKind: .evm)
    ])

    let envelope = try crypto.sealJSON(document, with: key, keyId: "sync-v1")
    let opened = try crypto.openJSON(VaultDocument.self, envelope: envelope, with: key)

    XCTAssertEqual(opened.wallets.first?.address, document.wallets.first?.address)

    let wrongKey = try crypto.deriveKey(from: crypto.generateVaultKey(), purpose: .syncBlob)
    XCTAssertThrowsError(try crypto.openJSON(VaultDocument.self, envelope: envelope, with: wrongKey))
  }

  func testEnvelopeNonceChangesForSamePlaintext() throws {
    let crypto = VaultCrypto()
    let key = try crypto.deriveKey(from: crypto.generateVaultKey(), purpose: .syncBlob)
    let plaintext = Data("same plaintext".utf8)

    let first = try crypto.seal(plaintext, with: key, keyId: "sync-v1")
    let second = try crypto.seal(plaintext, with: key, keyId: "sync-v1")

    XCTAssertNotEqual(first.nonce, second.nonce)
    XCTAssertNotEqual(first.ciphertext, second.ciphertext)
  }

  func testSealRejectsPlaintextThatWouldProduceAnEnvelopeOpenCannotRead() throws {
    let crypto = VaultCrypto(maximumEnvelopeBodyByteCount: 64)
    let key = try crypto.deriveKey(from: crypto.generateVaultKey(), purpose: .syncBlob)
    let maximumReadablePlaintext = Data(repeating: 0x41, count: 48)

    let readable = try crypto.seal(maximumReadablePlaintext, with: key, keyId: "sync-v1")
    XCTAssertEqual(try crypto.open(readable, with: key), maximumReadablePlaintext)

    XCTAssertThrowsError(
      try crypto.seal(Data(repeating: 0x42, count: 49), with: key, keyId: "sync-v1")
    ) { error in
      XCTAssertEqual(
        error as? VaultCryptoPlaintextTooLargeError,
        VaultCryptoPlaintextTooLargeError(actualByteCount: 49, maximumByteCount: 48)
      )
    }
  }
}

final class RecoveryKitTests: XCTestCase {
  func testRecoveryKitWrapsAndRestoresVaultKey() throws {
    let vaultKey = try VaultCrypto().generateVaultKey()
    let codec = RecoveryKitCodec()

    let export = try codec.create(vaultKey: vaultKey)
    let restored = try codec.open(export.document, recoveryCode: export.recoveryCode)

    XCTAssertEqual(restored, vaultKey)
    XCTAssertEqual(try RecoveryKitCodec.recoveryCodeBytes(export.recoveryCode).count, 32)
    XCTAssertFalse(export.recoveryCode.isEmpty)
    XCTAssertFalse(export.document.wrappedVaultKey.contains(vaultKey.hexString))
  }

  func testRecoveryKitRejectsWrongCodeAndMissingCode() throws {
    let codec = RecoveryKitCodec()
    let vaultKey = try VaultCrypto().generateVaultKey()
    let export = try codec.create(vaultKey: vaultKey)
    let otherCode = try codec.create(vaultKey: try VaultCrypto().generateVaultKey()).recoveryCode

    XCTAssertThrowsError(try codec.open(export.document, recoveryCode: otherCode))
    XCTAssertThrowsError(try codec.open(export.document, recoveryCode: ""))
  }

  func testRecoveryKitRejectsTamperedFile() throws {
    let codec = RecoveryKitCodec()
    let vaultKey = try VaultCrypto().generateVaultKey()
    let export = try codec.create(vaultKey: vaultKey)
    var document = export.document
    var wrapped = try Base64URL.decode(document.wrappedVaultKey)

    wrapped[0] ^= 0x01
    document.wrappedVaultKey = Base64URL.encode(wrapped)

    XCTAssertThrowsError(try codec.open(document, recoveryCode: export.recoveryCode)) { error in
      XCTAssertEqual(error as? RecoveryKitError, .checksumMismatch)
    }
  }
}

final class NativeEndpointConfigTests: XCTestCase {
  func testBundledEndpointConfigCoversExpandedEvmChains() {
    XCTAssertEqual(NativeEndpointConfig.bundled.configVersion, 5)
    XCTAssertEqual(
      NativeEndpointConfig.bundled.chains["ethereum"]?.rpcURL?.absoluteString,
      "https://ethereum-rpc.publicnode.com"
    )
    XCTAssertEqual(
      NativeEndpointConfig.bundled.chains["polygon"]?.rpcURL?.absoluteString,
      "https://polygon.drpc.org"
    )
    XCTAssertEqual(
      NativeEndpointConfig.bundled.chains["scroll"]?.rpcURL?.absoluteString,
      "https://rpc.scroll.io"
    )
    XCTAssertEqual(
      NativeEndpointConfig.bundled.chains["zksync-era"]?.rpcURL?.absoluteString,
      "https://mainnet.era.zksync.io"
    )
    XCTAssertNil(NativeEndpointConfig.bundled.chains["stargaze"])
  }

  func testEndpointConfigOverridesChainsButKeepsExchangeEndpointsFixed() throws {
    let config = NativeEndpointConfig(
      configVersion: 5,
      priceBaseURL: URL(string: "https://prices.example/simple/price")!,
      chains: [
        "ethereum": ChainEndpointOverride(rpcURL: URL(string: "https://ethereum-rpc.publicnode.com/rotated-rpc"))
      ],
      exchanges: [
        ExchangeProvider.binance.rawValue: ExchangeEndpointOverride(
          baseURL: URL(string: "https://binance.example")!,
          accountPath: "/api/v4/account"
        )
      ]
    )

    let chain = config.applying(to: ChainRegistry.evmChains.first { $0.id == "ethereum" }!)

    XCTAssertEqual(config.configVersion, 5)
    XCTAssertEqual(chain.rpcUrl?.absoluteString, "https://ethereum-rpc.publicnode.com/rotated-rpc")
    XCTAssertEqual(config.exchangeBaseURL(for: .binance)?.absoluteString, "https://api.binance.com")
    XCTAssertEqual(config.exchangeAccountPath(for: .binance), "/api/v3/account")
    XCTAssertEqual(config.exchangeBaseURL(for: .coinbase)?.absoluteString, "https://api.coinbase.com")
  }

  func testEndpointConfigClientFetchesNativeConfig() async throws {
    let expected = NativeEndpointConfig(
      configVersion: 5,
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      priceBaseURL: URL(string: "https://api.coingecko.com/api/v3/simple/price")!,
      chains: ["solana": ChainEndpointOverride(rpcURL: URL(string: "https://api.mainnet-beta.solana.com/rotated"))],
      exchanges: [:]
    )
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.url?.path, "/config/native")
      return (try JSONEncoder.addressAtlas.encode(expected), httpResponse(for: request))
    }
    let client = NativeEndpointConfigClient(http: http)

    let config = try await client.fetch(from: URL(string: "https://sync.example")!)

    XCTAssertEqual(config, expected)
  }

  func testEndpointConfigClientDecodesServerShapedNativeConfigJSON() async throws {
    // Bundled configVersion is cross-pinned to the server's
    // BUNDLED_NATIVE_ENDPOINT_CONFIG_VERSION (src/lib/sync/native-config.ts:31).
    // Deploy ordering rule: the server value must be raised FIRST, because the
    // native client rejects any payload version below its own bundled version.
    XCTAssertEqual(NativeEndpointConfig.bundled.configVersion, 5)

    // Literal JSON mirroring the wire shape of getNativeEndpointConfig() in
    // src/lib/sync/native-config.ts (served by GET /config/native). Note the
    // server-side casing `priceBaseUrl` and the JS toISOString() timestamp
    // with fractional seconds.
    let json = """
    {
      "schemaVersion": 1,
      "configVersion": 5,
      "updatedAt": "2026-07-14T00:00:00.000Z",
      "refreshAfterSeconds": 21600,
      "minSupportedAppVersion": "0.2.0",
      "message": "Planned maintenance this weekend.",
      "priceBaseUrl": "https://api.coingecko.com/api/v3/simple/price",
      "chains": {
        "bitcoin": { "restUrl": "https://blockstream.info/api" },
        "solana": { "rpcUrl": "https://api.mainnet-beta.solana.com" },
        "tron": { "restUrl": "https://api.trongrid.io" },
        "xrp": { "rpcUrl": "https://s1.ripple.com:51234/" },
        "ethereum": { "rpcUrl": "https://ethereum-rpc.publicnode.com" },
        "base": { "rpcUrl": "https://mainnet.base.org" },
        "arbitrum": { "rpcUrl": "https://arb1.arbitrum.io/rpc" },
        "optimism": { "rpcUrl": "https://mainnet.optimism.io" },
        "polygon": { "rpcUrl": "https://polygon.drpc.org" },
        "bsc": { "rpcUrl": "https://bsc-dataseed.binance.org" },
        "avalanche": { "rpcUrl": "https://api.avax.network/ext/bc/C/rpc" },
        "gnosis": { "rpcUrl": "https://rpc.gnosischain.com" },
        "linea": { "rpcUrl": "https://rpc.linea.build" },
        "mantle": { "rpcUrl": "https://rpc.mantle.xyz" },
        "scroll": { "rpcUrl": "https://rpc.scroll.io" },
        "zksync-era": { "rpcUrl": "https://mainnet.era.zksync.io" },
        "cosmoshub": { "restUrl": "https://cosmos-api.polkachu.com" },
        "osmosis": { "restUrl": "https://lcd.osmosis.zone" },
        "celestia": { "restUrl": "https://celestia-api.polkachu.com" },
        "stride": { "restUrl": "https://stride-api.polkachu.com" }
      },
      "exchanges": {}
    }
    """
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.url?.path, "/config/native")
      return (Data(json.utf8), httpResponse(for: request))
    }
    let client = NativeEndpointConfigClient(http: http)

    let config = try await client.fetch(from: URL(string: "https://sync.example")!)

    XCTAssertEqual(config.schemaVersion, 1)
    XCTAssertEqual(config.configVersion, 5)
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    XCTAssertEqual(
      config.updatedAt,
      try XCTUnwrap(fractionalFormatter.date(from: "2026-07-14T00:00:00.000Z"))
    )
    XCTAssertEqual(config.refreshAfterSeconds, 21_600)
    XCTAssertEqual(config.minSupportedAppVersion, "0.2.0")
    XCTAssertEqual(config.message, "Planned maintenance this weekend.")
    XCTAssertEqual(
      config.priceBaseURL.absoluteString,
      "https://api.coingecko.com/api/v3/simple/price"
    )
    XCTAssertEqual(config.chains.count, 20)
    XCTAssertEqual(config.chains["bitcoin"]?.restURL?.absoluteString, "https://blockstream.info/api")
    XCTAssertEqual(config.chains["solana"]?.rpcURL?.absoluteString, "https://api.mainnet-beta.solana.com")
    XCTAssertEqual(config.chains["tron"]?.restURL?.absoluteString, "https://api.trongrid.io")
    XCTAssertEqual(config.chains["xrp"]?.rpcURL?.absoluteString, "https://s1.ripple.com:51234/")
    XCTAssertEqual(config.chains["ethereum"]?.rpcURL?.absoluteString, "https://ethereum-rpc.publicnode.com")
    XCTAssertEqual(config.chains["base"]?.rpcURL?.absoluteString, "https://mainnet.base.org")
    XCTAssertEqual(config.chains["arbitrum"]?.rpcURL?.absoluteString, "https://arb1.arbitrum.io/rpc")
    XCTAssertEqual(config.chains["optimism"]?.rpcURL?.absoluteString, "https://mainnet.optimism.io")
    XCTAssertEqual(config.chains["polygon"]?.rpcURL?.absoluteString, "https://polygon.drpc.org")
    XCTAssertEqual(config.chains["bsc"]?.rpcURL?.absoluteString, "https://bsc-dataseed.binance.org")
    XCTAssertEqual(config.chains["avalanche"]?.rpcURL?.absoluteString, "https://api.avax.network/ext/bc/C/rpc")
    XCTAssertEqual(config.chains["gnosis"]?.rpcURL?.absoluteString, "https://rpc.gnosischain.com")
    XCTAssertEqual(config.chains["linea"]?.rpcURL?.absoluteString, "https://rpc.linea.build")
    XCTAssertEqual(config.chains["mantle"]?.rpcURL?.absoluteString, "https://rpc.mantle.xyz")
    XCTAssertEqual(config.chains["scroll"]?.rpcURL?.absoluteString, "https://rpc.scroll.io")
    XCTAssertEqual(config.chains["zksync-era"]?.rpcURL?.absoluteString, "https://mainnet.era.zksync.io")
    XCTAssertEqual(config.chains["cosmoshub"]?.restURL?.absoluteString, "https://cosmos-api.polkachu.com")
    XCTAssertEqual(config.chains["osmosis"]?.restURL?.absoluteString, "https://lcd.osmosis.zone")
    XCTAssertEqual(config.chains["celestia"]?.restURL?.absoluteString, "https://celestia-api.polkachu.com")
    XCTAssertEqual(config.chains["stride"]?.restURL?.absoluteString, "https://stride-api.polkachu.com")
    XCTAssertTrue(config.exchanges.isEmpty)
  }

  func testEndpointConfigClientRejectsAStaleOrOutOfRangePayloadVersion() async throws {
    for version in [4, 2_000_000_001] {
      let response = NativeEndpointConfig(
        configVersion: version,
        priceBaseURL: NativeEndpointConfig.bundled.priceBaseURL,
        exchanges: [:]
      )
      let http = StubHTTPClient { request in
        (try JSONEncoder.addressAtlas.encode(response), httpResponse(for: request))
      }
      let client = NativeEndpointConfigClient(http: http)

      do {
        _ = try await client.fetch(from: URL(string: "https://sync.example")!)
        XCTFail("Expected config version \(version) to be rejected.")
      } catch let error as NativeEndpointConfigError {
        XCTAssertEqual(error, .invalidConfigVersion)
      }
    }
  }

  func testEndpointConfigClientRejectsIPLiteralAndNonOriginServersBeforeRequest() async throws {
    let rejectingHTTP = StubHTTPClient { _ in
      XCTFail("Passkey-incompatible or malformed servers must be rejected before any HTTP request.")
      throw URLError(.badURL)
    }
    let rejectingClient = NativeEndpointConfigClient(http: rejectingHTTP)
    for raw in [
      "https://sync.example:0",
      "https://sync.example:65536",
      "http://127.0.0.1:8787",
      "http://[::1]:8787",
      "https://127.0.0.1:8787",
      "https://[2001:db8::1]:8787",
      "http://[::1]:99999",
      "https://sync.example/prefix",
      "https://sync.example?tenant=other",
      "https://sync.example#fragment"
    ] {
      do {
        _ = try await rejectingClient.fetch(from: URL(string: raw)!)
        XCTFail("Expected incompatible server to be rejected: \(raw)")
      } catch let error as NativeEndpointConfigError {
        XCTAssertEqual(error, .invalidEndpoint("serverUrl"))
      }
    }
  }

  func testEndpointConfigRejectsUnsafeRefreshIntervals() {
    for seconds in [299, 86_401] {
      XCTAssertThrowsError(try NativeEndpointConfig(refreshAfterSeconds: seconds).validated()) { error in
        XCTAssertEqual(error as? NativeEndpointConfigError, .invalidRefreshInterval)
      }
    }
    XCTAssertNoThrow(try NativeEndpointConfig(refreshAfterSeconds: 300).validated())
    XCTAssertNoThrow(try NativeEndpointConfig(refreshAfterSeconds: 86_400).validated())
  }

  func testEndpointConfigUsesBoundedDottedAppVersions() {
    for version in ["0.2", "0.2.0", "2000000000.0.0.0"] {
      XCTAssertNoThrow(
        try NativeEndpointConfig(minSupportedAppVersion: version).validated(),
        "Expected valid version \(version)"
      )
    }

    for version in [
      "2000000001.0",
      "9223372036854775808.0",
      "999999999999999999999999999999.0",
      "1",
      "1..2",
      "1.2.3.4.5",
      " 1.2.3 "
    ] {
      XCTAssertThrowsError(try NativeEndpointConfig(minSupportedAppVersion: version).validated()) { error in
        XCTAssertEqual(error as? NativeEndpointConfigError, .invalidMinimumAppVersion)
      }
    }
  }

  func testEndpointConfigClientRejectsUnsafeURLsAndPaths() async throws {
    let invalid = NativeEndpointConfig(
      configVersion: 5,
      priceBaseURL: URL(string: "file:///tmp/prices")!,
      exchanges: [
        ExchangeProvider.binance.rawValue: ExchangeEndpointOverride(
          baseURL: URL(string: "https://binance.example")!,
          accountPath: "https://bad.example/account"
        )
      ]
    )
    let http = StubHTTPClient { request in
      (try JSONEncoder.addressAtlas.encode(invalid), httpResponse(for: request))
    }
    let client = NativeEndpointConfigClient(http: http)

    do {
      _ = try await client.fetch(from: URL(string: "https://sync.example")!)
      XCTFail("Expected unsafe endpoint config to fail.")
    } catch NativeEndpointConfigError.invalidEndpoint(_) {
      // Expected.
    }
  }

  func testEndpointConfigClientRejectsRemoteExchangeOverrides() async throws {
    let invalid = NativeEndpointConfig(
      configVersion: 5,
      exchanges: [
        ExchangeProvider.binance.rawValue: ExchangeEndpointOverride(
          baseURL: URL(string: "https://api.binance.com")!,
          accountPath: "/api/v3/account"
        )
      ]
    )
    let http = StubHTTPClient { request in
      (try JSONEncoder.addressAtlas.encode(invalid), httpResponse(for: request))
    }
    let client = NativeEndpointConfigClient(http: http)

    do {
      _ = try await client.fetch(from: URL(string: "https://sync.example")!)
      XCTFail("Expected plain HTTP exchange endpoint config to fail.")
    } catch NativeEndpointConfigError.invalidEndpoint(let field) {
      XCTAssertEqual(field, "exchanges")
    }
  }
}

final class EncryptedSQLiteVaultStoreTests: XCTestCase {
  func testStorePersistsEncryptedDocumentWithoutPlaintextWalletLeak() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(path: tempDir.appending(path: "vault.sqlite"), vaultKey: vaultKey, crypto: crypto)
    let wallet = WalletRecord(label: "Wallet", address: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", chainKind: .evm)

    try store.save(VaultDocument(wallets: [wallet]))
    let loaded = try store.load()
    let raw = try XCTUnwrap(store.rawStoredEnvelopeBytes())
    let rawText = String(decoding: raw, as: UTF8.self)

    XCTAssertEqual(loaded.wallets.first?.address, wallet.address)
    XCTAssertFalse(rawText.contains(wallet.address))
    XCTAssertTrue(rawText.contains("ciphertext"))
  }

  func testOversizedSavePreservesReadableRowAndStoreBaseline() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let crypto = VaultCrypto(maximumEnvelopeBodyByteCount: 2_048)
    let vaultKey = try crypto.generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey, crypto: crypto)
    _ = try store.load()
    var baseline = VaultDocument(wallets: [
      WalletRecord(label: "Readable", address: "0x1", chainKind: .evm)
    ])
    baseline = try store.saveReturningPersistedDocument(baseline)
    let envelopeBeforeRejectedSave = try XCTUnwrap(store.rawStoredEnvelopeBytes())

    let oversized = VaultDocument(wallets: [
      WalletRecord(
        label: String(repeating: "x", count: 4_096),
        address: "0x2",
        chainKind: .evm
      )
    ])
    XCTAssertThrowsError(try store.save(oversized)) { error in
      XCTAssertNotNil(error as? VaultCryptoPlaintextTooLargeError)
    }
    XCTAssertEqual(try store.rawStoredEnvelopeBytes(), envelopeBeforeRejectedSave)

    let verifierAfterFailure = try EncryptedSQLiteVaultStore(
      path: databaseURL,
      vaultKey: vaultKey,
      crypto: crypto
    )
    XCTAssertEqual(try verifierAfterFailure.load().wallets.map(\.label), ["Readable"])

    // A normal follow-up save through the original store proves the failed
    // preflight did not advance or invalidate its compare-and-swap baseline.
    baseline.wallets[0].label = "Saved after rejection"
    try store.save(baseline)
    let finalVerifier = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey, crypto: crypto)
    XCTAssertEqual(try finalVerifier.load().wallets.map(\.label), ["Saved after rejection"])
  }

  func testSaveReturningPersistedDocumentReturnsTheExactPersistedTimestamp() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let vaultKey = try VaultCrypto().generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    let originalTimestamp = Date(timeIntervalSince1970: 0)

    let saved = try store.saveReturningPersistedDocument(
      VaultDocument(updatedAt: originalTimestamp)
    )
    let verifier = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    let loaded = try verifier.load()

    XCTAssertGreaterThan(saved.updatedAt, originalTimestamp)
    XCTAssertEqual(saved.updatedAt, loaded.updatedAt)

    // Keep the original public API source-compatible for callers that expect
    // a Void-returning persistence operation.
    let voidSave: (VaultDocument) throws -> Void = store.save
    try voidSave(saved)
  }

  func testStoreCreatesAndRepairsDatabaseAsOwnerOnly() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let store = try EncryptedSQLiteVaultStore(
      path: databaseURL,
      vaultKey: try VaultCrypto().generateVaultKey()
    )

    try store.initialize()
    var attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: databaseURL.path)
    try store.initialize()
    attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testSequentialWholeDocumentSavesAdvanceWithoutConflict() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let vaultKey = try VaultCrypto().generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    _ = try store.load()

    var document = VaultDocument(wallets: [
      WalletRecord(label: "First", address: "0x1", chainKind: .evm)
    ])
    try store.save(document)
    document.wallets.append(WalletRecord(label: "Second", address: "0x2", chainKind: .evm))
    try store.save(document)

    let verifier = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    XCTAssertEqual(try verifier.load().wallets.map(\.label), ["First", "Second"])
  }

  func testStaleStoreCannotOverwriteAnotherProcessChanges() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let vaultKey = try VaultCrypto().generateVaultKey()
    let firstProcess = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    let secondProcess = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    _ = try firstProcess.load()
    _ = try secondProcess.load()

    try firstProcess.save(VaultDocument(wallets: [
      WalletRecord(label: "First process", address: "0x1", chainKind: .evm)
    ]))
    XCTAssertThrowsError(
      try secondProcess.save(VaultDocument(wallets: [
        WalletRecord(label: "Second process", address: "0x2", chainKind: .evm)
      ]))
    ) { error in
      XCTAssertEqual(error as? EncryptedSQLiteVaultStoreError, .staleDocument)
    }

    let verifier = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    XCTAssertEqual(try verifier.load().wallets.map(\.label), ["First process"])
  }

  func testStoreCannotOverwriteExistingDocumentWithoutLoadingABaseline() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let vaultKey = try VaultCrypto().generateVaultKey()
    let seededStore = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    try seededStore.save(VaultDocument(wallets: [
      WalletRecord(label: "Existing", address: "0x1", chainKind: .evm)
    ]))

    let unbasedStore = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    XCTAssertThrowsError(
      try unbasedStore.save(VaultDocument(wallets: [
        WalletRecord(label: "Blind overwrite", address: "0x2", chainKind: .evm)
      ]))
    ) { error in
      XCTAssertEqual(error as? EncryptedSQLiteVaultStoreError, .staleDocument)
    }

    let verifier = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    XCTAssertEqual(try verifier.load().wallets.map(\.label), ["Existing"])
  }

  func testRevisionGuardRejectsLegacyWriterThatDoesNotIncrementRevision() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let currentProcess = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    try currentProcess.save(VaultDocument(wallets: [
      WalletRecord(label: "Current writer", address: "0x1", chainKind: .evm)
    ]))
    let localKey = try crypto.deriveKey(from: vaultKey, purpose: .localDatabase)
    let legacyEnvelope = try crypto.sealJSON(
      VaultDocument(wallets: [WalletRecord(label: "Legacy writer", address: "0x2", chainKind: .evm)]),
      with: localKey,
      keyId: "local-db"
    )

    XCTAssertThrowsError(
      try overwriteVaultWithoutRevisionIncrement(
        at: databaseURL,
        envelopeBytes: JSONEncoder.addressAtlas.encode(legacyEnvelope)
      )
    )
    let verifier = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    XCTAssertEqual(try verifier.load().wallets.map(\.label), ["Current writer"])
  }

  func testBlobCasDetectsLegacyWriterIfRevisionGuardIsMissing() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let seededStore = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    try seededStore.save(VaultDocument(wallets: [
      WalletRecord(label: "Initial", address: "0x1", chainKind: .evm)
    ]))

    let currentProcess = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    let staleDocument = try currentProcess.load()
    try dropRevisionGuard(at: databaseURL)
    let localKey = try crypto.deriveKey(from: vaultKey, purpose: .localDatabase)
    let legacyEnvelope = try crypto.sealJSON(
      VaultDocument(wallets: [WalletRecord(label: "Legacy writer", address: "0x2", chainKind: .evm)]),
      with: localKey,
      keyId: "local-db"
    )
    try overwriteVaultWithoutRevisionIncrement(
      at: databaseURL,
      envelopeBytes: JSONEncoder.addressAtlas.encode(legacyEnvelope)
    )

    XCTAssertThrowsError(try currentProcess.save(staleDocument)) { error in
      XCTAssertEqual(error as? EncryptedSQLiteVaultStoreError, .staleDocument)
    }
    let verifier = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    XCTAssertEqual(try verifier.load().wallets.map(\.label), ["Legacy writer"])
  }

  func testLegacyDatabaseMigratesRevisionWithoutLosingDocument() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let databaseURL = tempDir.appending(path: "vault.sqlite")
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let localKey = try crypto.deriveKey(from: vaultKey, purpose: .localDatabase)
    let legacyDocument = VaultDocument(wallets: [
      WalletRecord(label: "Legacy", address: "0x1", chainKind: .evm)
    ])
    let envelope = try crypto.sealJSON(legacyDocument, with: localKey, keyId: "local-db")
    try createLegacyVaultDatabase(
      at: databaseURL,
      envelopeBytes: JSONEncoder.addressAtlas.encode(envelope)
    )

    let migratedStore = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    var migrated = try migratedStore.load()
    XCTAssertEqual(migrated.wallets.map(\.label), ["Legacy"])
    migrated.wallets.append(WalletRecord(label: "After migration", address: "0x2", chainKind: .evm))
    try migratedStore.save(migrated)

    let verifier = try EncryptedSQLiteVaultStore(path: databaseURL, vaultKey: vaultKey)
    XCTAssertEqual(try verifier.load().wallets.map(\.label), ["Legacy", "After migration"])
  }

  private func createLegacyVaultDatabase(at url: URL, envelopeBytes: Data) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
          let db
    else {
      throw EncryptedSQLiteVaultStoreError.openFailed("Could not create legacy test database.")
    }
    defer { sqlite3_close(db) }
    let sql = """
    CREATE TABLE encrypted_vault_documents (
      id TEXT PRIMARY KEY NOT NULL,
      envelope_json BLOB NOT NULL,
      updated_at TEXT NOT NULL
    );
    INSERT INTO encrypted_vault_documents (id, envelope_json, updated_at)
    VALUES ('primary', X'\(envelopeBytes.hexString)', '2026-07-01T00:00:00Z');
    """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
    }
  }

  private func overwriteVaultWithoutRevisionIncrement(at url: URL, envelopeBytes: Data) throws {
    try executeVaultSQL(
      at: url,
      sql: """
      UPDATE encrypted_vault_documents
      SET envelope_json = X'\(envelopeBytes.hexString)', updated_at = '2026-07-01T00:00:01Z'
      WHERE id = 'primary';
      """
    )
  }

  private func dropRevisionGuard(at url: URL) throws {
    try executeVaultSQL(
      at: url,
      sql: "DROP TRIGGER encrypted_vault_documents_revision_guard;"
    )
  }

  private func executeVaultSQL(at url: URL, sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
          let db
    else {
      throw EncryptedSQLiteVaultStoreError.openFailed("Could not open test database.")
    }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw EncryptedSQLiteVaultStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
    }
  }
}

final class ExchangeRequestSigningTests: XCTestCase {
  func testBinanceSignerBuildsExpectedQueryAndHeader() {
    let signed = ExchangeRequestSigner.binanceAccountRequest(
      credentials: ExchangeCredentials(apiKey: "key", secret: "secret"),
      timestampMs: 1_700_000_000_000
    )

    XCTAssertEqual(signed.method, "GET")
    XCTAssertEqual(signed.path, "/api/v3/account")
    XCTAssertTrue(signed.query.contains("timestamp=1700000000000"))
    XCTAssertTrue(signed.query.contains("signature="))
    XCTAssertEqual(signed.headers["X-MBX-APIKEY"], "key")
  }

  func testKrakenSignerAcceptsStandardBase64SecretAndMatchesExpectedSignature() throws {
    // Kraken's published example secret contains '/', '+' and '=' characters,
    // so this also guards against accidentally using Base64URL decoding again.
    let signed = try ExchangeRequestSigner.krakenBalanceRequest(
      credentials: ExchangeCredentials(
        apiKey: "key",
        secret: "kQH5HW/8p1uGOVjbgWA7FunAmGO8lsSUXNsu3eow76sz84Q18fWxnyRzBHCd3pd5nE9qa99HAZtuZuj6F1huXg=="
      ),
      nonce: "1616492376594"
    )

    XCTAssertEqual(signed.body, "nonce=1616492376594")
    XCTAssertEqual(
      signed.headers["API-Sign"],
      "1nH4vwR+8FHiYh1QT649xXkGd3JR3x0DWkgv3u9Ed/Qqv6KPtgQpEU4m+Emb/VgpEji3j1XNwI+HCbfXxmrTOg=="
    )
  }

  func testAddressDetectionRejectsSeedLikeInput() {
    let phrase = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima"
    XCTAssertFalse(AddressDetection.isSafePublicAddress(phrase))
  }

  func testAddressDetectionPrefersSpecificBase58ChainsBeforeSolana() {
    XCTAssertEqual(
      AddressDetection.detectChains(for: "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7").map(\.id),
      ["tron"]
    )
    XCTAssertEqual(
      AddressDetection.detectChains(for: "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn").map(\.id),
      ["xrp"]
    )
  }
}

final class NativeScannerTokenTests: XCTestCase {
  func testErc20BalanceOfDataPadsOwnerAddress() {
    let data = NativeScanner.erc20BalanceOfData("0x000000000000000000000000000000000000dEaD")

    XCTAssertEqual(data.count, 74)
    XCTAssertTrue(data.hasPrefix("0x70a08231"))
    XCTAssertTrue(data.hasSuffix("000000000000000000000000000000000000dead"))
  }

  func testHexQuantityParserAcceptsOddLengthRpcQuantities() {
    XCTAssertEqual(NativeScanner.hexQuantityToDouble("0xf", decimals: 0), 15)
    XCTAssertEqual(NativeScanner.hexQuantityToDouble("0x280de80", decimals: 6), 42)
  }

  func testHexQuantityParserRejectsMalformedOrUnprefixedValues() {
    XCTAssertNil(NativeScanner.hexQuantityToDouble("0x10x20", decimals: 0))
    XCTAssertNil(NativeScanner.hexQuantityToDouble("120", decimals: 0))
    XCTAssertNil(NativeScanner.hexQuantityToDouble("0x", decimals: 0))
    XCTAssertNil(NativeScanner.hexQuantityToDouble("0x12", decimals: 37))
  }

  func testCustomTokenRegistryKeepsBuiltinOnDuplicate() {
    let duplicateUsdc = CustomTokenRecord(
      chainKind: .evm,
      chainId: "ethereum",
      address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      symbol: "FAKE",
      name: "Fake USDC",
      decimals: 6
    )
    let custom = CustomTokenRecord(
      chainKind: .evm,
      chainId: "ethereum",
      address: "0x0000000000000000000000000000000000000001",
      symbol: "ONE",
      name: "One",
      decimals: 18,
      priceUsd: 1
    )

    let registries = NativeScanner.tokenRegistries(customTokens: [duplicateUsdc, custom])
    let ethereum = registries.evm["ethereum"] ?? []

    XCTAssertEqual(ethereum.filter { $0.address.lowercased() == duplicateUsdc.address.lowercased() }.count, 1)
    XCTAssertTrue(ethereum.contains { $0.symbol == "USDC" })
    XCTAssertTrue(ethereum.contains { $0.symbol == "ONE" })
  }

  func testEvmTokenBalancesUseJsonRpcBatchAndWarnOnPartialErrors() async throws {
    let address = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
    let recorder = BatchRequestRecorder()
    let http = StubHTTPClient { request in
      let bodyData = request.httpBody ?? Data()
      let bodyText = String(data: bodyData, encoding: .utf8) ?? ""

      if bodyText.contains("\"eth_getBalance\"") {
        return (Data(#"{"result":"0x0"}"#.utf8), httpResponse(for: request))
      }

      if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
        let payload = try JSONSerialization.jsonObject(with: bodyData) as? [[String: Any]] ?? []
        recorder.append(payload.count)
        let responses: [[String: Any]] = payload.map { item in
          let id = item["id"] as? Int ?? 0
          let params = item["params"] as? [Any] ?? []
          let call = params.first as? [String: Any] ?? [:]
          let tokenAddress = (call["to"] as? String ?? "").lowercased()

          if tokenAddress == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" {
            return ["jsonrpc": "2.0", "id": id, "result": "0x" + String(42_000_000, radix: 16)]
          }
          if tokenAddress == "0xd533a949740bb3306d119cc777fa900ba034cd52" {
            return ["jsonrpc": "2.0", "id": id, "error": ["message": "token-rpc-down"]]
          }
          return ["jsonrpc": "2.0", "id": id, "result": "0x0"]
        }
        return (try JSONSerialization.data(withJSONObject: responses), httpResponse(for: request))
      }

      XCTFail("Unexpected EVM scanner request: \(bodyText)")
      return (Data("{}".utf8), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: ["usd-coin": PricePoint(usd: 1)])
    )

    let result = try await scanner.scan(addresses: address)
    let usdc = result.holdings.first { $0.chainId == "ethereum" && $0.symbol == "USDC" }

    XCTAssertTrue(recorder.snapshot().contains { $0 > 1 })
    XCTAssertEqual(usdc?.amount, 42)
    XCTAssertEqual(usdc?.valueUsd, 42)
    XCTAssertTrue(result.warnings.contains { warning in
      warning.contains("Ethereum") && warning.contains("CRV")
    })
  }

  func testChainRegistryIncludesExpandedNetworksAndAssets() {
    let evmIds = Set(ChainRegistry.evmChains.map(\.id))
    XCTAssertTrue(evmIds.isSuperset(of: ["gnosis", "linea", "mantle", "scroll", "zksync-era"]))
    XCTAssertEqual(ChainRegistry.commonErc20Tokens["gnosis"]?.first { $0.symbol == "GNO" }?.decimals, 18)
    XCTAssertEqual(
      ChainRegistry.commonErc20Tokens["scroll"]?.first { $0.symbol == "USDC" }?.address,
      "0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4"
    )
    XCTAssertEqual(
      ChainRegistry.commonErc20Tokens["zksync-era"]?.first { $0.symbol == "ZK" }?.address,
      "0x5A7d6b2F92C77FAD6CCaBd7EE0624E64907Eaf3E"
    )
    XCTAssertEqual(ChainRegistry.commonSplTokens["solana"]?.first { $0.symbol == "PYTH" }?.decimals, 6)
    for chainID in ["arbitrum", "polygon"] {
      let usdt0 = ChainRegistry.commonErc20Tokens[chainID]?.first { $0.symbol == "USDT0" }
      XCTAssertEqual(usdt0?.name, "USDT0")
      XCTAssertEqual(usdt0?.decimals, 6)
      XCTAssertEqual(usdt0?.coinGeckoId, "usdt0")
      XCTAssertFalse(ChainRegistry.commonErc20Tokens[chainID]?.contains { $0.symbol == "USDT" } == true)
    }
    XCTAssertEqual(ExchangeBalanceNormalizer.coinGeckoIds["ZK"], "zksync")
    XCTAssertEqual(ExchangeBalanceNormalizer.coinGeckoIds["SCR"], "scroll")
  }

  func testBuiltinRegistriesCoverReferenceTokenSet() {
    let registries = NativeScanner.tokenRegistries(customTokens: [])

    XCTAssertTrue(registries.evm["base"]?.contains { $0.symbol == "cbBTC" } == true)
    XCTAssertTrue(registries.evm["arbitrum"]?.contains { $0.symbol == "ARB" } == true)
    XCTAssertTrue(registries.evm["optimism"]?.contains { $0.symbol == "OP" } == true)
    XCTAssertTrue(registries.evm["bsc"]?.contains { $0.symbol == "CAKE" } == true)
    XCTAssertTrue(registries.evm["avalanche"]?.contains { $0.symbol == "BTC.b" } == true)

    let solana = registries.spl["solana"] ?? []
    XCTAssertEqual(
      solana.first(where: { $0.symbol == "USDT" })?.address,
      "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"
    )
    XCTAssertEqual(
      solana.first(where: { $0.symbol == "BONK" })?.address,
      "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263"
    )
    XCTAssertEqual(
      solana.first(where: { $0.symbol == "WIF" })?.address,
      "EKpQGSJtjMFqKZ9KQanSqYXRcF8fBopzLHYxdM65zcjm"
    )
    XCTAssertTrue(solana.contains { $0.symbol == "JitoSOL" })
  }

  func testSolanaTokenAccountParserReadsJsonParsedBalances() throws {
    let json = """
    {
      "result": {
        "value": [
          {
            "account": {
              "data": {
                "parsed": {
                  "info": {
                    "mint": "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
                    "tokenAmount": {
                      "amount": "1234500",
                      "decimals": 6
                    }
                  }
                }
              }
            }
          }
        ]
      }
    }
    """
    let response = try JSONDecoder.addressAtlas.decode(SolanaTokenAccountsResponse.self, from: Data(json.utf8))
    let parsed = NativeScanner.parseSolanaTokenAccounts(response.result?.value ?? [])

    XCTAssertEqual(parsed, [
      ParsedSplAccount(
        mint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
        rawAmount: 1_234_500,
        decimals: 6
      )
    ])
  }

  func testSolanaScannerSurfacesPartialTokenProgramWarnings() async throws {
    let address = "So11111111111111111111111111111111111111112"
    let http = StubHTTPClient { request in
      let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      if body.contains("getBalance") {
        let json = """
        { "result": { "value": 1000000000 } }
        """
        return (Data(json.utf8), httpResponse(for: request))
      }
      if body.contains("getTokenAccountsByOwner") {
        throw URLError(.timedOut)
      }
      XCTFail("Unexpected scanner request: \(body)")
      return (Data("{}".utf8), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: ["solana": PricePoint(usd: 10)])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertEqual(result.holdings.first?.symbol, "SOL")
    XCTAssertEqual(result.holdings.first?.valueUsd, 10)
    XCTAssertTrue(result.warnings.contains { warning in
      warning.contains("Solana") && warning.contains("SPL Token token account scan failed")
    })
    XCTAssertTrue(result.warnings.contains { warning in
      warning.contains("Solana") && warning.contains("Token-2022 token account scan failed")
    })
  }

  func testSolanaJsonRpcErrorsDoNotBecomeZeroBalances() async throws {
    let address = "So11111111111111111111111111111111111111112"
    let http = StubHTTPClient { request in
      let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      if body.contains("getBalance") {
        let json = """
        { "error": { "code": -32000, "message": "node is behind" } }
        """
        return (Data(json.utf8), httpResponse(for: request))
      }
      if body.contains("getTokenAccountsByOwner") {
        let json = """
        { "result": { "value": [] } }
        """
        return (Data(json.utf8), httpResponse(for: request))
      }
      XCTFail("Unexpected scanner request: \(body)")
      return (Data("{}".utf8), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: ["solana": PricePoint(usd: 10)])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertFalse(result.holdings.contains { $0.symbol == "SOL" })
    XCTAssertTrue(result.warnings.contains { warning in
      warning.contains("Solana") && warning.contains("node is behind")
    })
  }

  func testXrpJsonRpcErrorsDoNotBecomeZeroBalances() async throws {
    let address = "rG1QQv2nh2gr7RCZ1P8YYcBUKCCN633jCn"
    let http = StubHTTPClient { request in
      let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      if body.contains("account_info") {
        let json = """
        {
          "result": {
            "status": "error",
            "error": "internal",
            "error_message": "ledger unavailable"
          }
        }
        """
        return (Data(json.utf8), httpResponse(for: request))
      }
      XCTFail("Unexpected scanner request: \(body)")
      return (Data("{}".utf8), httpResponse(for: request))
    }
    let scanner = NativeScanner(
      http: JSONHTTPClient(http: http),
      priceProvider: StaticPriceProvider(values: ["ripple": PricePoint(usd: 2)])
    )

    let result = try await scanner.scan(addresses: address)

    XCTAssertTrue(result.holdings.isEmpty)
    XCTAssertTrue(result.warnings.contains { warning in
      warning.contains("XRP Ledger") && warning.contains("ledger unavailable")
    })
  }

  func testCosmosParsersReadLiquidStakedAndRewardsBalances() throws {
    let bankJSON = """
    { "balances": [{ "denom": "uatom", "amount": "1200000" }] }
    """
    let delegationJSON = """
    {
      "delegation_responses": [
        { "balance": { "denom": "uatom", "amount": "2500000" } },
        { "balance": { "denom": "uother", "amount": "9999999" } }
      ]
    }
    """
    let rewardsJSON = """
    { "total": [{ "denom": "uatom", "amount": "340000" }] }
    """

    let bank = try JSONDecoder.addressAtlas.decode(CosmosBankResponse.self, from: Data(bankJSON.utf8))
    let delegations = try JSONDecoder.addressAtlas.decode(CosmosDelegationResponse.self, from: Data(delegationJSON.utf8))
    let rewards = try JSONDecoder.addressAtlas.decode(CosmosRewardsResponse.self, from: Data(rewardsJSON.utf8))

    XCTAssertEqual(NativeScanner.parseCosmosLiquid(bank, denom: "uatom", decimals: 6), 1.2)
    XCTAssertEqual(NativeScanner.parseCosmosDelegations(delegations, denom: "uatom", decimals: 6), 2.5)
    XCTAssertEqual(NativeScanner.parseCosmosRewards(rewards, denom: "uatom", decimals: 6), 0.34)
  }

  func testTronTrc20ParserReadsRegisteredBalances() {
    let token = TokenConfig(
      symbol: "USDT",
      name: "Tether",
      address: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
      decimals: 6,
      coinGeckoId: "tether"
    )

    let parsed = NativeScanner.parseTronTrc20Balances(
      [
        ["TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t": "1250000"],
        ["other": "999999"]
      ],
      tokens: [token]
    )

    XCTAssertEqual(parsed.count, 1)
    XCTAssertEqual(parsed.first?.token.symbol, "USDT")
    XCTAssertEqual(parsed.first?.amount, 1.25)
  }

  func testXrpTrustLineParserDecodesIssuedAssets() {
    let lines = [
      XrpTrustLine(
        account: "rIssuer111111111111111111111111111111111",
        balance: "42.5",
        currency: "5553440000000000000000000000000000000000"
      ),
      XrpTrustLine(
        account: "rIssuer222222222222222222222222222222222",
        balance: "-1",
        currency: "IGNORED"
      )
    ]

    let parsed = NativeScanner.parseXrpTrustLines(
      lines,
      address: "rWallet111111111111111111111111111111111",
      chain: ChainRegistry.xrp
    )

    XCTAssertEqual(NativeScanner.decodeXrplCurrency("5553440000000000000000000000000000000000"), "USD")
    XCTAssertEqual(parsed.count, 1)
    XCTAssertEqual(parsed.first?.symbol, "USD")
    XCTAssertEqual(parsed.first?.source, .issued)
    XCTAssertEqual(parsed.first?.amount, 42.5)
  }
}

final class ExchangeCredentialVaultTests: XCTestCase {
  func testExchangeCredentialsUseDedicatedSubkey() throws {
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let credentialVault = ExchangeCredentialVault(crypto: crypto)
    let credentials = ExchangeCredentials(apiKey: "api", secret: "secret", passphrase: "pass")

    let envelope = try credentialVault.seal(credentials, vaultKey: vaultKey, connectionId: UUID())
    let opened = try credentialVault.open(envelope, vaultKey: vaultKey)

    XCTAssertEqual(opened, credentials)

    let localKey = try crypto.deriveKey(from: vaultKey, purpose: .localDatabase)
    XCTAssertThrowsError(try crypto.openJSON(ExchangeCredentials.self, envelope: envelope, with: localKey))
  }
}

final class NativeExchangeClientTests: XCTestCase {
  func testBinanceClientSignsRequestAndParsesBalances() async throws {
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.url?.path, "/api/v3/account")
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-MBX-APIKEY"), "key")
      XCTAssertTrue(request.url?.query?.contains("timestamp=1700000000000") == true)
      XCTAssertTrue(request.url?.query?.contains("signature=") == true)
      let json = """
      {
        "balances": [
          { "asset": "BTC", "free": "0.25", "locked": "0.25" },
          { "asset": "EMPTY", "free": "0", "locked": "0" }
        ]
      }
      """
      return (Data(json.utf8), httpResponse(for: request))
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    let balance = try await client.fetchBalance(
      provider: .binance,
      credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
    )

    XCTAssertEqual(balance.total["BTC"], 0.5)
    XCTAssertEqual(balance.free["BTC"], 0.25)
    XCTAssertNil(balance.total["EMPTY"])
  }

  func testExchangeClientIgnoresRemoteEndpointConfigForSignedRequests() async throws {
    let config = NativeEndpointConfig(
      exchanges: [
        ExchangeProvider.binance.rawValue: ExchangeEndpointOverride(
          baseURL: URL(string: "https://binance.example")!,
          accountPath: "/api/v4/account"
        )
      ]
    )
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.url?.host, "api.binance.com")
      XCTAssertEqual(request.url?.path, "/api/v3/account")
      return (Data("{\"balances\":[]}".utf8), httpResponse(for: request))
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      endpointConfig: config,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    _ = try await client.fetchBalance(
      provider: .binance,
      credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
    )
  }

  func testExchangeClientReportsHTTPErrorBody() async throws {
    let http = StubHTTPClient { request in
      let json = """
      { "msg": "Invalid API-key, IP, or permissions for action." }
      """
      return (Data(json.utf8), httpResponse(for: request, statusCode: 401))
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    do {
      _ = try await client.fetchBalance(
        provider: .binance,
        credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
      )
      XCTFail("Expected exchange HTTP error.")
    } catch ExchangeClientError.httpError(let statusCode, let message) {
      XCTAssertEqual(statusCode, 401)
      XCTAssertEqual(message, "Invalid API-key, IP, or permissions for action.")
    }
  }

  func testExchangeClientRedactsAndCapsUntrustedErrorBody() async throws {
    let rawSecret = String(repeating: "s", count: 80)
    let http = StubHTTPClient { request in
      let data = try JSONSerialization.data(withJSONObject: [
        "message": "authorization: Bearer \(rawSecret)\n\(String(repeating: "x", count: 1_000))"
      ])
      return (data, httpResponse(for: request, statusCode: 401))
    }
    let client = NativeExchangeBalanceClient(
      http: http,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    do {
      _ = try await client.fetchBalance(
        provider: .binance,
        credentials: ExchangeCredentials(apiKey: "key", secret: "secret")
      )
      XCTFail("Expected exchange HTTP error.")
    } catch ExchangeClientError.httpError(_, let message) {
      XCTAssertFalse(message.contains(rawSecret))
      XCTAssertFalse(message.contains("\n"))
      XCTAssertTrue(message.contains("[redacted]"))
      XCTAssertLessThanOrEqual(message.unicodeScalars.count, ProviderErrorSanitizer.maximumScalarCount + 1)
    }
  }

  func testExchangeBalanceNormalizerUsesLiveStablecoinPricesAndExactUSD() async throws {
    // Every non-USD stablecoin must have a CoinGecko identity so the live
    // price can win; the $1.00 fallback below is only for missing prices.
    XCTAssertTrue(
      ExchangeBalanceNormalizer.usdStableSymbols.subtracting(["USD"]).allSatisfy {
        ExchangeBalanceNormalizer.coinGeckoIds[$0] != nil
      }
    )
    let id = UUID()
    let result = try await ExchangeBalanceNormalizer.normalizeWithWarnings(
      balance: ExchangeBalance(total: [
        "BUSD": 100, "DAI": 100, "FDUSD": 100, "TUSD": 100,
        "USD": 100, "USDC": 100, "USDP": 100, "USDT": 100, "XBT": 0.5
      ]),
      id: id,
      provider: .kraken,
      label: "Kraken main",
      priceProvider: StaticPriceProvider(values: [
        "bitcoin": PricePoint(usd: 100_000, usd24hChange: 1.5),
        "binance-usd": PricePoint(usd: 0.96),
        "first-digital-usd": PricePoint(usd: 0.98),
        "pax-dollar": PricePoint(usd: 1.01),
        "usd-coin": PricePoint(usd: 0.97, usd24hChange: -3),
        "tether": PricePoint(usd: 1.02, usd24hChange: 2),
        "dai": PricePoint(usd: 0.99, usd24hChange: -1),
        "true-usd": PricePoint(usd: 0.95)
      ])
    )
    let holdings = result.holdings

    XCTAssertEqual(
      holdings.map(\.symbol),
      ["BTC", "BUSD", "DAI", "FDUSD", "TUSD", "USD", "USDC", "USDP", "USDT"]
    )
    XCTAssertEqual(holdings.first(where: { $0.symbol == "BTC" })?.valueUsd, 50_000)
    XCTAssertEqual(try XCTUnwrap(holdings.first(where: { $0.symbol == "BUSD" })?.valueUsd), 96, accuracy: 0.000_001)
    XCTAssertEqual(try XCTUnwrap(holdings.first(where: { $0.symbol == "DAI" })?.valueUsd), 99, accuracy: 0.000_001)
    XCTAssertEqual(try XCTUnwrap(holdings.first(where: { $0.symbol == "FDUSD" })?.valueUsd), 98, accuracy: 0.000_001)
    XCTAssertEqual(try XCTUnwrap(holdings.first(where: { $0.symbol == "TUSD" })?.valueUsd), 95, accuracy: 0.000_001)
    XCTAssertEqual(try XCTUnwrap(holdings.first(where: { $0.symbol == "USD" })?.priceUsd), 1, accuracy: 0.000_001)
    XCTAssertEqual(try XCTUnwrap(holdings.first(where: { $0.symbol == "USDC" })?.valueUsd), 97, accuracy: 0.000_001)
    XCTAssertEqual(try XCTUnwrap(holdings.first(where: { $0.symbol == "USDP" })?.valueUsd), 101, accuracy: 0.000_001)
    XCTAssertEqual(try XCTUnwrap(holdings.first(where: { $0.symbol == "USDT" })?.valueUsd), 102, accuracy: 0.000_001)
    XCTAssertEqual(holdings.first?.source, .exchange)
    XCTAssertTrue(result.warnings.isEmpty)
  }

  func testExchangeBalanceNormalizerFallsBackToOneDollarOnlyForMissingStablecoinPrices() async throws {
    // A live CoinGecko price always wins; the exact $1.00 fallback applies
    // only when the response omits a USD stablecoin. Non-stablecoins with a
    // missing price remain visibly unpriced at $0.
    let result = try await ExchangeBalanceNormalizer.normalizeWithWarnings(
      balance: ExchangeBalance(total: ["USDC": 42, "USDT": 10, "USD": 5, "BTC": 1]),
      id: UUID(),
      provider: .binance,
      label: "Binance main",
      priceProvider: StaticPriceProvider(values: ["tether": PricePoint(usd: 0.98)])
    )

    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "USDC" })?.priceUsd, 1)
    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "USDC" })?.valueUsd, 42)
    XCTAssertEqual(
      try XCTUnwrap(result.holdings.first(where: { $0.symbol == "USDT" })?.valueUsd),
      9.8,
      accuracy: 0.000_001
    )
    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "USD" })?.valueUsd, 5)
    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "BTC" })?.priceUsd, 0)
    XCTAssertEqual(result.holdings.first(where: { $0.symbol == "BTC" })?.valueUsd, 0)
    XCTAssertTrue(result.warnings.contains(where: {
      $0.contains("USDC") && $0.contains("$1.00") && !$0.contains("BTC")
    }))
    XCTAssertTrue(result.warnings.contains(where: {
      $0.contains("BTC") && $0.contains("shown unpriced") && !$0.contains("USDC")
    }))
  }

  func testNativeExchangeScannerDecryptsCredentialsAndUpdatesConnection() async throws {
    let http = StubHTTPClient { request in
      let json = """
      {
        "balances": [
          { "asset": "USDC", "free": "10", "locked": "0" }
        ]
      }
      """
      return (Data(json.utf8), httpResponse(for: request))
    }
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let connectionId = UUID()
    let credentials = try ExchangeCredentialVault(crypto: crypto).seal(
      ExchangeCredentials(apiKey: "key", secret: "secret"),
      vaultKey: vaultKey,
      connectionId: connectionId
    )
    let connection = ExchangeConnectionRecord(
      id: connectionId,
      provider: .binance,
      label: "Binance main",
      encryptedCredentials: credentials
    )
    let scanner = NativeExchangeScanner(
      client: NativeExchangeBalanceClient(http: http, now: { Date(timeIntervalSince1970: 1_700_000_000) }),
      credentialVault: ExchangeCredentialVault(crypto: crypto),
      priceProvider: StaticPriceProvider(values: ["usd-coin": PricePoint(usd: 1)])
    )

    let result = try await scanner.scanThrowing(connections: [connection], vaultKey: vaultKey)

    XCTAssertEqual(result.holdings.first?.symbol, "USDC")
    XCTAssertEqual(result.holdings.first?.valueUsd, 10)
    XCTAssertEqual(result.connections.first?.status, .ok)
    XCTAssertNil(result.connections.first?.lastError)
    XCTAssertTrue(result.warnings.isEmpty)
  }

  func testLiveExchangeReadOnlySmokeWhenConfigured() async throws {
    let credentials = try liveExchangeCredentials()
    let client = NativeExchangeBalanceClient()

    for (provider, credential) in credentials {
      let balance = try await client.fetchBalance(provider: provider, credentials: credential)
      let entries = ExchangeBalanceNormalizer.balanceEntries(balance)
      XCTAssertTrue(
        entries.allSatisfy { _, amount in amount.isFinite && amount > 0 },
        "\(provider.label) returned non-finite balance entries."
      )
    }
  }

  func testLiveInvalidExchangeCredentialsFailCleanlyWhenConfigured() async throws {
    _ = try liveExchangeCredentials()
    let client = NativeExchangeBalanceClient()
    let invalidCredentials: [(ExchangeProvider, ExchangeCredentials)] = [
      (.binance, ExchangeCredentials(apiKey: "invalid", secret: "invalid")),
      (.coinbase, ExchangeCredentials(apiKey: "invalid", secret: "invalid", passphrase: "invalid")),
      (.kraken, ExchangeCredentials(apiKey: "invalid", secret: Data("invalid".utf8).base64EncodedString()))
    ]

    for (provider, credentials) in invalidCredentials {
      do {
        _ = try await client.fetchBalance(provider: provider, credentials: credentials)
        XCTFail("Expected \(provider.label) invalid credentials to fail.")
      } catch {
        XCTAssertFalse(error.localizedDescription.isEmpty)
      }
    }
  }

  private func liveExchangeCredentials() throws -> [(ExchangeProvider, ExchangeCredentials)] {
    let environment = ProcessInfo.processInfo.environment
    guard environment["ADDRESS_ATLAS_LIVE_EXCHANGE_TESTS"] == "1" else {
      throw XCTSkip("Set ADDRESS_ATLAS_LIVE_EXCHANGE_TESTS=1 to run live exchange smoke tests.")
    }

    var missing: [String] = []
    func require(_ name: String) -> String {
      guard let value = environment[name], !value.isEmpty else {
        missing.append(name)
        return ""
      }
      return value
    }

    let binance = ExchangeCredentials(
      apiKey: require("ADDRESS_ATLAS_BINANCE_API_KEY"),
      secret: require("ADDRESS_ATLAS_BINANCE_SECRET")
    )
    let coinbase = ExchangeCredentials(
      apiKey: require("ADDRESS_ATLAS_COINBASE_API_KEY"),
      secret: require("ADDRESS_ATLAS_COINBASE_SECRET"),
      passphrase: environment["ADDRESS_ATLAS_COINBASE_PASSPHRASE"]
    )
    let kraken = ExchangeCredentials(
      apiKey: require("ADDRESS_ATLAS_KRAKEN_API_KEY"),
      secret: require("ADDRESS_ATLAS_KRAKEN_SECRET")
    )

    guard missing.isEmpty else {
      throw XCTSkip("Missing live exchange smoke credentials: \(missing.sorted().joined(separator: ", ")).")
    }

    return [
      (.binance, binance),
      (.coinbase, coinbase),
      (.kraken, kraken)
    ]
  }
}

final class SyncClientTests: XCTestCase {
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
      try JSONSerialization.jsonObject(with: JSONEncoder.addressAtlas.encode(snapshot)) as? [String: Any]
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
    XCTAssertEqual(decoded.updatedAt.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.000_001)
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
    let http = StubHTTPClient { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer expired")
      let json = """
      { "error": "Token expired." }
      """
      return (Data(json.utf8), httpResponse(for: request, statusCode: 401))
    }
    let client = ZeroKnowledgeSyncClient(baseURL: URL(string: "https://sync.example")!, http: http)
    await client.setBearerToken("expired")

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
      String(repeating: "a", count: SyncSessionToken.maximumUTF8ByteCount + 1)
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
    await client.setBearerToken("current")

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
      "error": "authorization: Bearer \(rawSecret)\napi_key=\(rawSecret) \(String(repeating: "x", count: 2_000))"
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

private struct StubHTTPClient: HTTPClient, @unchecked Sendable {
  let handler: (URLRequest) throws -> (Data, HTTPURLResponse)

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try handler(request)
  }
}

private final class BatchRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var sizes: [Int] = []

  func append(_ size: Int) {
    lock.lock()
    defer { lock.unlock() }
    sizes.append(size)
  }

  func snapshot() -> [Int] {
    lock.lock()
    defer { lock.unlock() }
    return sizes
  }
}

private func httpResponse(for request: URLRequest, statusCode: Int = 200) -> HTTPURLResponse {
  HTTPURLResponse(
    url: request.url ?? URL(string: "https://example.com")!,
    statusCode: statusCode,
    httpVersion: "HTTP/1.1",
    headerFields: ["content-type": "application/json"]
  )!
}
