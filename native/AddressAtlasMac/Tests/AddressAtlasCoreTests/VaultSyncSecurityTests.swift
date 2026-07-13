import CryptoKit
import Foundation
import XCTest
@testable import AddressAtlasCore

final class VaultSyncAuthenticatedMetadataTests: XCTestCase {
  func testRemoteSnapshotRejectsMalformedMetadataBeforeVersionUse() throws {
    let vaultKey = try VaultCrypto().generateVaultKey()
    let codec = VaultSyncCodec()
    let snapshot = try codec.seal(
      document: VaultDocument(),
      vaultKey: vaultKey,
      version: 1,
      accountId: "account-a"
    )

    var oversizedVersion = snapshot
    oversizedVersion.version = Int.max
    XCTAssertThrowsError(try codec.validateRemoteSnapshot(oversizedVersion)) { error in
      XCTAssertEqual(error as? VaultSyncCodecError, .invalidVersion)
    }

    var malformedMetadata = snapshot
    malformedMetadata.byteSize += 1
    XCTAssertThrowsError(try codec.validateRemoteSnapshot(malformedMetadata)) { error in
      XCTAssertEqual(error as? VaultSyncCodecError, .invalidSnapshot)
    }
  }

  func testNextSnapshotVersionUsesCheckedArithmetic() throws {
    let codec = VaultSyncCodec()

    XCTAssertEqual(try codec.nextVersion(after: 0), 1)
    XCTAssertEqual(try codec.nextVersion(after: 7), 8)
    for latestVersion in [-1, 2_000_000_000, Int.max] {
      XCTAssertThrowsError(try codec.nextVersion(after: latestVersion)) { error in
        XCTAssertEqual(error as? VaultSyncCodecError, .invalidVersion)
      }
    }
  }

  func testV2SnapshotRejectsPubliclyRechecksummedVersionRelabel() throws {
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let codec = VaultSyncCodec(crypto: crypto)
    let accountId = "account-123"
    let snapshot = try codec.seal(
      document: VaultDocument(syncState: SyncState(accountId: accountId)),
      vaultKey: vaultKey,
      version: 7,
      accountId: accountId
    )

    XCTAssertFalse(try codec.open(snapshot: snapshot, vaultKey: vaultKey, expectedAccountId: accountId).requiresV2Upgrade)

    var relabeled = snapshot
    relabeled.version = 99
    relabeled.checksum = try v2SnapshotChecksum(version: relabeled.version, envelope: relabeled.envelope)

    XCTAssertThrowsError(
      try codec.open(snapshot: relabeled, vaultKey: vaultKey, expectedAccountId: accountId)
    ) { error in
      XCTAssertEqual(error as? VaultCryptoError, .authenticationFailed)
    }
  }

  func testV2SnapshotRejectsDifferentExpectedAccount() throws {
    let vaultKey = try VaultCrypto().generateVaultKey()
    let codec = VaultSyncCodec()
    let snapshot = try codec.seal(
      document: VaultDocument(),
      vaultKey: vaultKey,
      version: 1,
      accountId: "account-a"
    )

    XCTAssertThrowsError(
      try codec.open(snapshot: snapshot, vaultKey: vaultKey, expectedAccountId: "account-b")
    ) { error in
      XCTAssertEqual(error as? VaultCryptoError, .authenticationFailed)
    }
  }

  func testLegacyV1SnapshotOpensOnlyWithConsistentEncryptedVersionAndSignalsUpgrade() throws {
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let accountId = "legacy-account"
    let document = VaultDocument(
      schemaVersion: 1,
      wallets: [WalletRecord(label: "Legacy", address: "0x123", chainKind: .evm)],
      syncState: SyncState(accountId: accountId, latestRemoteVersion: 4)
    )
    let key = try crypto.deriveKey(from: vaultKey, purpose: .syncBlob)
    let envelope = try crypto.sealJSON(document, with: key, keyId: "sync-v1", schemaVersion: 1)
    let encoded = try JSONEncoder.addressAtlas.encode(envelope)
    let snapshot = RemoteVaultSnapshot(
      version: 5,
      envelope: envelope,
      byteSize: encoded.count,
      checksum: Data(SHA256.hash(data: encoded)).hexString
    )
    let codec = VaultSyncCodec(crypto: crypto)

    let opened = try codec.open(snapshot: snapshot, vaultKey: vaultKey, expectedAccountId: accountId)

    XCTAssertTrue(opened.requiresV2Upgrade)
    XCTAssertEqual(opened.document.schemaVersion, VaultDocument.currentSchemaVersion)
    XCTAssertEqual(opened.document.wallets.first?.label, "Legacy")

    var relabeled = snapshot
    relabeled.version = 500
    XCTAssertThrowsError(
      try codec.open(snapshot: relabeled, vaultKey: vaultKey, expectedAccountId: accountId)
    ) { error in
      XCTAssertEqual(error as? VaultSyncCodecError, .legacyMetadataMismatch)
    }
  }

  func testContentBaselineDetectsLocalEditsAndIgnoresSessionRefresh() throws {
    let codec = VaultSyncCodec()
    let vaultKey = try VaultCrypto().generateVaultKey()
    var document = VaultDocument(syncState: SyncState(accountId: "account", sessionToken: "first"))
    let snapshot = try codec.seal(document: document, vaultKey: vaultKey, version: 1, accountId: "account")
    try codec.markSynced(document: &document, snapshot: snapshot)

    XCTAssertFalse(try codec.hasLocalChanges(in: document))
    document.syncState.sessionToken = "refreshed"
    XCTAssertFalse(try codec.hasLocalChanges(in: document))
    document.wallets.append(WalletRecord(label: "New", address: "0xabc", chainKind: .evm))
    XCTAssertTrue(try codec.hasLocalChanges(in: document))
  }

  func testChangingServerOrAccountClearsTokenAndRemoteBaseline() {
    var state = SyncState(
      accountId: "account-a",
      serverURL: "https://sync-a.example",
      sessionToken: "token-a",
      latestRemoteVersion: 9,
      lastChecksum: "snapshot-a",
      lastSyncedContentChecksum: "content-a"
    )

    state.changeServer(to: "https://sync-b.example")

    XCTAssertEqual(state.serverURL, "https://sync-b.example")
    XCTAssertNil(state.accountId)
    XCTAssertEqual(state.sessionToken, "")
    XCTAssertEqual(state.latestRemoteVersion, 0)
    XCTAssertNil(state.lastChecksum)
    XCTAssertNil(state.lastSyncedContentChecksum)

    state.connect(accountId: "account-b", serverURL: state.serverURL, sessionToken: "token-b")
    XCTAssertEqual(state.accountId, "account-b")
    XCTAssertEqual(state.sessionToken, "token-b")
    XCTAssertEqual(state.latestRemoteVersion, 0)
  }

  func testV2SnapshotChecksumMatchesBackendWireFixture() throws {
    let createdAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-12T12:00:00Z"))
    let envelope = EncryptedVaultEnvelope(
      schemaVersion: 2,
      cryptoVersion: 2,
      keyId: "sync-v2",
      nonce: Base64URL.encode(Data(repeating: 0x01, count: 12)),
      ciphertext: Base64URL.encode(Data(repeating: 0x02, count: 48)),
      checksum: "60b1cfca31587a2af4be1c9070ccdfb9dfcd74edc6c3e43efbebe3a20df7fcda",
      createdAt: createdAt
    )

    XCTAssertEqual(try JSONEncoder.addressAtlas.encode(envelope).count, 275)
    XCTAssertEqual(
      try v2SnapshotChecksum(version: 7, envelope: envelope),
      "cf86567cbc441cef3d7d7c5aa2fb5e80281905ce92c80bd50c63786577187c51"
    )
  }

  private func v2SnapshotChecksum(version: Int, envelope: EncryptedVaultEnvelope) throws -> String {
    let encoded = try JSONEncoder.addressAtlas.encode(envelope)
    var input = Data("address-atlas:sync-snapshot:v2".utf8)
    appendUInt64(UInt64(version), to: &input)
    appendUInt64(UInt64(encoded.count), to: &input)
    input.append(encoded)
    return Data(SHA256.hash(data: input)).hexString
  }

  private func appendUInt64(_ value: UInt64, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
  }
}

final class VaultSyncMigrationAndExportTests: XCTestCase {
  func testSchemaV1DocumentDecodesMissingSyncFieldsWithSafeDefaults() throws {
    let json = #"""
    {
      "schemaVersion": 1,
      "preferences": {
        "darkMode": false,
        "density": "comfy",
        "mono": false,
        "hideDust": false,
        "dustThreshold": 5,
        "autoRefresh": true,
        "currency": "USD"
      },
      "wallets": [],
      "customTokens": [],
      "manualHoldings": [],
      "exchangeConnections": [],
      "scanRuns": [],
      "syncState": {
        "accountId": "legacy-user",
        "latestRemoteVersion": 3,
        "lastChecksum": "abc"
      },
      "updatedAt": "2026-07-01T12:00:00Z"
    }
    """#

    let document = try JSONDecoder.addressAtlas.decode(VaultDocument.self, from: Data(json.utf8))

    XCTAssertEqual(document.schemaVersion, VaultDocument.currentSchemaVersion)
    XCTAssertEqual(document.syncState.accountId, "legacy-user")
    XCTAssertEqual(document.syncState.serverURL, "")
    XCTAssertEqual(document.syncState.sessionToken, "")
    XCTAssertNil(document.syncState.lastSyncedContentChecksum)
  }

  func testJSONExportOmitsSyncAndCredentialSecrets() throws {
    let credentialCiphertext = "credential-ciphertext-marker"
    let envelope = EncryptedVaultEnvelope(
      keyId: "exchange-id",
      nonce: Base64URL.encode(Data(repeating: 1, count: 12)),
      ciphertext: credentialCiphertext,
      checksum: String(repeating: "a", count: 64)
    )
    var connection = ExchangeConnectionRecord(provider: .binance, label: "Binance", encryptedCredentials: envelope)
    connection.lastError = "raw-provider-error-marker"
    let document = VaultDocument(
      exchangeConnections: [connection],
      syncState: SyncState(
        accountId: "private-account-id",
        serverURL: "https://private-sync.example",
        sessionToken: "live-bearer-token",
        lastChecksum: "private-sync-checksum"
      )
    )

    let json = try XCTUnwrap(String(data: AddressAtlasExporter.json(for: document), encoding: .utf8))

    XCTAssertFalse(json.contains("syncState"))
    XCTAssertFalse(json.contains("sessionToken"))
    XCTAssertFalse(json.contains("live-bearer-token"))
    XCTAssertFalse(json.contains("encryptedCredentials"))
    XCTAssertFalse(json.contains(credentialCiphertext))
    XCTAssertFalse(json.contains("lastError"))
    XCTAssertFalse(json.contains("raw-provider-error-marker"))
    XCTAssertTrue(json.contains("Binance"))
  }
}

final class VaultSyncKeyRecoveryTests: XCTestCase {
  func testManagerRefusesToGenerateUnrelatedKeyForExistingVault() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultURL = directory.appending(path: "vault.sqlite")
    try Data([1]).write(to: vaultURL)
    let keyStore = InMemoryVaultKeyStore()
    let manager = VaultKeyManager(store: keyStore)

    do {
      _ = try await manager.loadOrCreateVaultKey(existingVaultAt: vaultURL)
      XCTFail("Expected recovery requirement.")
    } catch {
      XCTAssertEqual(error as? VaultKeyManagerError, .recoveryRequired)
    }
    XCTAssertNil(try keyStore.loadVaultKey())
    XCTAssertEqual(keyStore.saveCount, 0)
  }

  func testConcurrentFirstRunManagersConvergeOnOneInstalledKey() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let keyStore = SimulatedFirstRunRaceVaultKeyStore()
    let firstManager = VaultKeyManager(store: keyStore)
    let secondManager = VaultKeyManager(store: keyStore)
    let vaultURL = directory.appending(path: "vault.sqlite")

    async let first = firstManager.loadOrCreateVaultKey(existingVaultAt: vaultURL)
    async let second = secondManager.loadOrCreateVaultKey(existingVaultAt: vaultURL)
    let (firstKey, secondKey) = try await (first, second)

    XCTAssertEqual(firstKey, secondKey)
    XCTAssertEqual(firstKey, try keyStore.loadVaultKey())
    XCTAssertEqual(keyStore.conditionalSaveAttempts, 2)
  }

  func testRecoveryFileImportRejectsOversizedInputBeforeDecode() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recoveryURL = directory.appending(path: "oversized.atlas-recovery")
    try Data(
      repeating: 0x41,
      count: VaultRecoveryService.maximumRecoveryFileByteCount + 1
    ).write(to: recoveryURL)
    let keyStore = InMemoryVaultKeyStore()

    XCTAssertThrowsError(
      try VaultRecoveryService().restore(
        from: recoveryURL,
        recoveryCode: String(repeating: "0", count: 64),
        vaultURL: directory.appending(path: "vault.sqlite"),
        keyStore: keyStore
      )
    ) { error in
      XCTAssertEqual(error as? RecoveryKitError, .fileTooLarge)
    }
    XCTAssertNil(try keyStore.loadVaultKey())
    XCTAssertEqual(keyStore.saveCount, 0)
  }

  func testValidRecoveryFileImportStillRestoresExistingVault() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultURL = directory.appending(path: "vault.sqlite")
    let recoveryURL = directory.appending(path: "valid.atlas-recovery")
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let databaseStore = try EncryptedSQLiteVaultStore(path: vaultURL, vaultKey: vaultKey, crypto: crypto)
    try databaseStore.save(VaultDocument(wallets: [
      WalletRecord(label: "Recovered from file", address: "0xabc", chainKind: .evm)
    ]))
    let kit = try RecoveryKitCodec().create(vaultKey: vaultKey)
    let encodedKit = try JSONEncoder.addressAtlas.encode(kit.document)
    XCTAssertLessThan(encodedKit.count, VaultRecoveryService.maximumRecoveryFileByteCount)
    try encodedKit.write(to: recoveryURL, options: [.atomic])
    let keyStore = InMemoryVaultKeyStore()

    let recovered = try VaultRecoveryService().restore(
      from: recoveryURL,
      recoveryCode: kit.recoveryCode,
      vaultURL: vaultURL,
      keyStore: keyStore
    )

    XCTAssertEqual(recovered.document.wallets.map(\.label), ["Recovered from file"])
    XCTAssertEqual(try keyStore.loadVaultKey(), vaultKey)
    XCTAssertEqual(keyStore.saveCount, 1)
  }

  func testRecoveryValidatesDatabaseBeforeAtomicallyInstallingKey() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultURL = directory.appending(path: "vault.sqlite")
    let crypto = VaultCrypto()
    let correctKey = try crypto.generateVaultKey()
    let oldKeychainKey = try crypto.generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(path: vaultURL, vaultKey: correctKey, crypto: crypto)
    try store.save(VaultDocument(wallets: [WalletRecord(label: "Recovered", address: "0xabc", chainKind: .evm)]))
    let kit = try RecoveryKitCodec().create(vaultKey: correctKey)
    let keyStore = InMemoryVaultKeyStore(key: oldKeychainKey)

    let recovered = try VaultRecoveryService().restore(
      document: kit.document,
      recoveryCode: kit.recoveryCode,
      vaultURL: vaultURL,
      keyStore: keyStore
    )

    XCTAssertEqual(recovered.document.wallets.first?.label, "Recovered")
    XCTAssertEqual(try keyStore.loadVaultKey(), correctKey)
    XCTAssertEqual(keyStore.saveCount, 1)
  }

  func testRecoveryDoesNotReplaceKeyWhenKitCannotDecryptExistingVault() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultURL = directory.appending(path: "vault.sqlite")
    let crypto = VaultCrypto()
    let databaseKey = try crypto.generateVaultKey()
    let unrelatedKit = try RecoveryKitCodec().create(vaultKey: try crypto.generateVaultKey())
    let existingKeychainKey = try crypto.generateVaultKey()
    let store = try EncryptedSQLiteVaultStore(path: vaultURL, vaultKey: databaseKey, crypto: crypto)
    try store.save(VaultDocument(wallets: [WalletRecord(label: "Protected", address: "0xabc", chainKind: .evm)]))
    let keyStore = InMemoryVaultKeyStore(key: existingKeychainKey)

    XCTAssertThrowsError(
      try VaultRecoveryService().restore(
        document: unrelatedKit.document,
        recoveryCode: unrelatedKit.recoveryCode,
        vaultURL: vaultURL,
        keyStore: keyStore
      )
    )
    XCTAssertEqual(try keyStore.loadVaultKey(), existingKeychainKey)
    XCTAssertEqual(keyStore.saveCount, 0)
  }
}

final class KeychainVaultKeyStoreTests: XCTestCase {
  func testRealKeychainStoreRoundTripsAndPreservesFirstInsertWinner() throws {
    let identifier = UUID().uuidString
    let store = KeychainVaultKeyStore(
      service: "com.addressatlas.tests.\(identifier)",
      account: "vault-key-\(identifier)"
    )
    defer { try? store.deleteVaultKey() }
    let first = Data(repeating: 0x11, count: VaultCrypto.vaultKeyByteCount)
    let competing = Data(repeating: 0x22, count: VaultCrypto.vaultKeyByteCount)
    let replacement = Data(repeating: 0x33, count: VaultCrypto.vaultKeyByteCount)

    XCTAssertNil(try store.loadVaultKey())
    XCTAssertEqual(try store.saveVaultKeyIfAbsent(first), first)
    XCTAssertEqual(try store.saveVaultKeyIfAbsent(competing), first)
    XCTAssertEqual(try store.loadVaultKey(), first)

    try store.saveVaultKey(replacement)
    XCTAssertEqual(try store.loadVaultKey(), replacement)
    try store.deleteVaultKey()
    XCTAssertNil(try store.loadVaultKey())
  }
}

final class VaultSyncEndpointAndEnvelopeTests: XCTestCase {
  func testSyncServerURLCanonicalizesOriginsAndRejectsEndpointComponents() {
    XCTAssertEqual(
      SyncServerURL.validatedOrigin(" HTTPS://Sync.Example.COM:443/ ")?.absoluteString,
      "https://sync.example.com"
    )
    XCTAssertEqual(
      SyncServerURL.validatedOrigin("http://localhost:80/")?.absoluteString,
      "http://localhost"
    )
    for invalid in [
      "https:",
      "https:///vault",
      "https://user:secret@sync.example.com",
      "https://sync.example.com/path",
      "https://sync.example.com?query=1",
      "https://sync.example.com#fragment",
      "http://sync.example.com"
    ] {
      XCTAssertNil(SyncServerURL.validatedOrigin(invalid), invalid)
    }
  }

  func testRemoteConfigCannotRedirectExchangeSignedRequests() throws {
    let malicious = NativeEndpointConfig(
      exchanges: [
        ExchangeProvider.kraken.rawValue: ExchangeEndpointOverride(
          baseURL: URL(string: "https://attacker.example")!,
          accountPath: "/0/private/CancelAll"
        )
      ]
    )

    XCTAssertThrowsError(try malicious.validated()) { error in
      XCTAssertEqual(error as? NativeEndpointConfigError, .invalidEndpoint("exchanges"))
    }
    XCTAssertEqual(malicious.exchangeBaseURL(for: .kraken)?.absoluteString, "https://api.kraken.com")
    XCTAssertEqual(malicious.exchangeAccountPath(for: .kraken), "/0/private/Balance")
  }

  func testRemoteEndpointConfigIsPinnedToBundledOrigins() throws {
    XCTAssertNoThrow(
      try NativeEndpointConfig(
        priceBaseURL: URL(string: "https://api.coingecko.com/api/v3/simple/price")!,
        chains: [
          "ethereum": ChainEndpointOverride(rpcURL: URL(string: "https://eth.llamarpc.com/alternate-path"))
        ]
      ).validated()
    )
    XCTAssertThrowsError(
      try NativeEndpointConfig(priceBaseURL: URL(string: "http://prices.example/price")!).validated()
    )
    XCTAssertThrowsError(
      try NativeEndpointConfig(priceBaseURL: URL(string: "http://127.0.0.1:8080/price")!).validated()
    )
    XCTAssertThrowsError(
      try NativeEndpointConfig(priceBaseURL: URL(string: "https://api.coingecko.com/api/v3/coins/list")!).validated()
    )
    XCTAssertThrowsError(
      try NativeEndpointConfig(
        chains: ["ethereum": ChainEndpointOverride(rpcURL: URL(string: "https://attacker.example/rpc"))]
      ).validated()
    )
    XCTAssertThrowsError(
      try NativeEndpointConfig(
        chains: ["ethereum": ChainEndpointOverride(rpcURL: URL(string: "http://127.0.0.1:8545"))]
      ).validated()
    )
  }

  func testEnvelopeRejectsWrongNonceLengthAndNonCanonicalBase64URL() throws {
    let crypto = VaultCrypto()
    let key = try crypto.deriveKey(from: try crypto.generateVaultKey(), purpose: .localDatabase)
    var envelope = try crypto.seal(Data("vault".utf8), with: key, keyId: "local-db")
    envelope.nonce = Base64URL.encode(Data(repeating: 0, count: 11))

    XCTAssertThrowsError(try crypto.open(envelope, with: key)) { error in
      XCTAssertEqual(error as? VaultCryptoError, .invalidEnvelope)
    }
    XCTAssertThrowsError(try Base64URL.decode("AA==")) { error in
      XCTAssertEqual(error as? VaultCryptoError, .invalidBase64)
    }
  }
}

private final class InMemoryVaultKeyStore: VaultKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var key: Data?
  private(set) var saveCount = 0

  init(key: Data? = nil) {
    self.key = key
  }

  func loadVaultKey() throws -> Data? {
    lock.withLock { key }
  }

  func saveVaultKey(_ key: Data) throws {
    lock.withLock {
      self.key = key
      saveCount += 1
    }
  }

  func saveVaultKeyIfAbsent(_ key: Data) throws -> Data {
    lock.withLock {
      if let existing = self.key { return existing }
      self.key = key
      saveCount += 1
      return key
    }
  }

  func deleteVaultKey() throws {
    lock.withLock { key = nil }
  }
}

/// Simulates two processes that both observed a missing Keychain item before
/// either attempted the atomic insert.
private final class SimulatedFirstRunRaceVaultKeyStore: VaultKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var key: Data?
  private var staleMissingReads = 2
  private var saveAttempts = 0

  var conditionalSaveAttempts: Int {
    lock.withLock { saveAttempts }
  }

  func loadVaultKey() throws -> Data? {
    lock.withLock {
      if staleMissingReads > 0 {
        staleMissingReads -= 1
        return nil
      }
      return key
    }
  }

  func saveVaultKey(_ key: Data) throws {
    lock.withLock { self.key = key }
  }

  func saveVaultKeyIfAbsent(_ key: Data) throws -> Data {
    lock.withLock {
      saveAttempts += 1
      if let existing = self.key { return existing }
      self.key = key
      return key
    }
  }

  func deleteVaultKey() throws {
    lock.withLock { key = nil }
  }
}
