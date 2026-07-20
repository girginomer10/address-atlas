import CryptoKit
import Foundation
import XCTest

@testable import AddressAtlasCore

private let syncAccountA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private let syncAccountB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
private let syncAccountC = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

final class VaultSyncAuthenticatedMetadataTests: XCTestCase {
  func testDecodingSyncStateNormalizesValidUUIDAndClearsMalformedCredentialState() throws {
    let valid = SyncState(
      accountId: syncAccountA.uppercased(),
      serverURL: "https://sync.example",
      sessionToken: "valid-token",
      latestRemoteVersion: 7,
      lastSyncedAt: Date(timeIntervalSince1970: 100),
      lastChecksum: "snapshot",
      lastSyncedContentChecksum: "content"
    )
    let decodedValid = try JSONDecoder.addressAtlas.decode(
      SyncState.self,
      from: JSONEncoder.addressAtlas.encode(valid)
    )
    XCTAssertEqual(decodedValid.accountId, syncAccountA)
    XCTAssertEqual(decodedValid.sessionToken, "valid-token")
    XCTAssertEqual(decodedValid.latestRemoteVersion, 7)

    let malformed = SyncState(
      accountId: "not-a-server-uuid",
      serverURL: "https://sync.example",
      sessionToken: "must-not-survive",
      latestRemoteVersion: 9,
      lastSyncedAt: Date(timeIntervalSince1970: 100),
      lastChecksum: "snapshot",
      lastSyncedContentChecksum: "content"
    )
    let decodedMalformed = try JSONDecoder.addressAtlas.decode(
      SyncState.self,
      from: JSONEncoder.addressAtlas.encode(malformed)
    )
    XCTAssertNil(decodedMalformed.accountId)
    XCTAssertEqual(decodedMalformed.serverURL, "https://sync.example")
    XCTAssertEqual(decodedMalformed.sessionToken, "")
    XCTAssertEqual(decodedMalformed.latestRemoteVersion, 0)
    XCTAssertNil(decodedMalformed.lastSyncedAt)
    XCTAssertNil(decodedMalformed.lastChecksum)
    XCTAssertNil(decodedMalformed.lastSyncedContentChecksum)

    let missingAccountJSON = #"""
      {
        "serverURL": "https://sync.example",
        "sessionToken": "orphaned-token",
        "latestRemoteVersion": 5,
        "lastChecksum": "orphaned-baseline"
      }
      """#
    let decodedMissing = try JSONDecoder.addressAtlas.decode(
      SyncState.self,
      from: Data(missingAccountJSON.utf8)
    )
    XCTAssertNil(decodedMissing.accountId)
    XCTAssertEqual(decodedMissing.sessionToken, "")
    XCTAssertEqual(decodedMissing.latestRemoteVersion, 0)
    XCTAssertNil(decodedMissing.lastChecksum)
  }

  func testSyncStateRejectsHeaderUnsafeOrOversizedSessionTokensWithoutLosingBaseline() throws {
    for token in [
      "unsafe\r\nheader",
      "contains a space",
      String(repeating: "a", count: SyncSessionToken.maximumUTF8ByteCount + 1),
    ] {
      let state = SyncState(
        accountId: syncAccountA,
        serverURL: "https://sync.example",
        sessionToken: token,
        latestRemoteVersion: 7,
        lastChecksum: String(repeating: "a", count: 64),
        lastSyncedContentChecksum: String(repeating: "b", count: 64)
      )
      let decoded = try JSONDecoder.addressAtlas.decode(
        SyncState.self,
        from: JSONEncoder.addressAtlas.encode(state)
      )

      XCTAssertEqual(decoded.accountId, syncAccountA)
      XCTAssertEqual(decoded.sessionToken, "")
      XCTAssertEqual(decoded.latestRemoteVersion, 7)
      XCTAssertEqual(decoded.lastChecksum, String(repeating: "a", count: 64))
      XCTAssertEqual(decoded.lastSyncedContentChecksum, String(repeating: "b", count: 64))
    }

    var state = SyncState()
    XCTAssertFalse(
      state.connect(
        accountId: syncAccountA,
        serverURL: "https://sync.example",
        sessionToken: "bad\nvalue"
      ))
    XCTAssertNil(state.accountId)
  }

  func testAccountDeletionOperationKeyRequiresCanonical32ByteBase64URL() throws {
    let valid = Base64URL.encode(Data(repeating: 0xA5, count: 32))
    XCTAssertEqual(valid.count, 43)
    XCTAssertEqual(AccountDeletionIdempotencyKey.normalized(valid), valid)
    for invalid in [
      valid + "=",
      String(valid.dropLast()),
      String(repeating: "!", count: 43),
      Base64URL.encode(Data(repeating: 0xA5, count: 31)),
    ] {
      XCTAssertNil(AccountDeletionIdempotencyKey.normalized(invalid), invalid)
    }

    let decoded = try JSONDecoder.addressAtlas.decode(
      SyncState.self,
      from: JSONEncoder.addressAtlas.encode(
        SyncState(
          accountId: syncAccountA,
          accountDeletionIdempotencyKey: valid
        )
      )
    )
    XCTAssertEqual(decoded.accountDeletionIdempotencyKey, valid)
  }

  func testCodecUsesTheCanonicalServerUUIDAccountRule() throws {
    let codec = VaultSyncCodec()
    let vaultKey = try VaultCrypto().generateVaultKey()
    let uppercaseAndPadded = "  \(syncAccountA.uppercased())  "

    XCTAssertTrue(codec.isValidAccountId(uppercaseAndPadded))
    for invalid in [
      "account-a",
      "00000000-0000-0000-0000-000000000000",
      "aaaaaaaa-aaaa-9aaa-8aaa-aaaaaaaaaaaa",
      "aaaaaaaa-aaaa-4aaa-7aaa-aaaaaaaaaaaa",
      String(repeating: "a", count: 200),
    ] {
      XCTAssertFalse(codec.isValidAccountId(invalid), invalid)
      XCTAssertThrowsError(
        try codec.encodedSnapshotByteCount(document: VaultDocument(), accountId: invalid)
      ) {
        XCTAssertEqual($0 as? VaultSyncCodecError, .invalidAccount)
      }
    }

    let snapshot = try codec.seal(
      document: VaultDocument(),
      vaultKey: vaultKey,
      version: 1,
      accountId: uppercaseAndPadded
    )
    let opened = try codec.open(
      snapshot: snapshot,
      vaultKey: vaultKey,
      expectedAccountId: syncAccountA
    )
    XCTAssertEqual(opened.document.syncState.accountId, syncAccountA)
  }

  func testEncodedSnapshotByteCountExactlyMatchesSealedEnvelope() throws {
    let codec = VaultSyncCodec()
    let vaultKey = try VaultCrypto().generateVaultKey()
    let accountId = syncAccountA

    for warningLength in [0, 1, 2, 3, 31, 512] {
      let document = VaultDocument(
        scanRuns: [
          ScanRunRecord(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            totalUsd: 0,
            inputCount: 0,
            holdings: [],
            warnings: [String(repeating: "x", count: warningLength)]
          )
        ],
        syncState: SyncState(
          accountId: "  \(accountId)  ",
          serverURL: "https://sync.example",
          sessionToken: "must-not-be-projected"
        ),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
      )

      let projected = try codec.encodedSnapshotByteCount(
        document: document,
        accountId: "  \(accountId)  "
      )
      let snapshot = try codec.seal(
        document: document,
        vaultKey: vaultKey,
        version: 1,
        accountId: "  \(accountId)  "
      )

      XCTAssertEqual(projected, snapshot.byteSize, "warning length \(warningLength)")
      XCTAssertEqual(
        projected,
        try JSONEncoder.addressAtlas.encode(snapshot.envelope).count,
        "warning length \(warningLength)"
      )
    }
  }

  func testPostSyncProjectionReservesExactMarkSyncedMetadataHeadroom() throws {
    let codec = VaultSyncCodec()
    let vaultKey = try VaultCrypto().generateVaultKey()
    let accountId = syncAccountB
    var document = VaultDocument(syncState: SyncState(accountId: accountId))
    let beforeMark = try codec.encodedSnapshotByteCount(
      document: document,
      accountId: accountId
    )
    let projectedAfterMark = try codec.projectedPostSyncSnapshotByteCount(
      document: document,
      version: 7,
      accountId: accountId
    )
    let snapshot = try codec.seal(
      document: document,
      vaultKey: vaultKey,
      version: 7,
      accountId: accountId
    )

    try codec.markSynced(
      document: &document,
      snapshot: snapshot,
      at: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let actualAfterMark = try codec.encodedSnapshotByteCount(
      document: document,
      accountId: accountId
    )

    XCTAssertGreaterThan(projectedAfterMark, beforeMark)
    XCTAssertEqual(projectedAfterMark, actualAfterMark)
  }

  func testSealReportsActualAndMaximumBytesForOversizedSnapshot() throws {
    let codec = VaultSyncCodec()
    let vaultKey = try VaultCrypto().generateVaultKey()
    let document = VaultDocument(
      scanRuns: [
        ScanRunRecord(
          totalUsd: 0,
          inputCount: 0,
          holdings: [],
          warnings: [String(repeating: "x", count: 6_100_000)]
        )
      ]
    )
    let actual = try codec.encodedSnapshotByteCount(
      document: document,
      accountId: syncAccountC
    )
    XCTAssertGreaterThan(actual, VaultSyncCodec.maximumSnapshotByteCount)

    XCTAssertThrowsError(
      try codec.seal(
        document: document,
        vaultKey: vaultKey,
        version: 1,
        accountId: syncAccountC
      )
    ) { error in
      XCTAssertEqual(
        error as? VaultSyncSnapshotTooLargeError,
        VaultSyncSnapshotTooLargeError(
          actualByteCount: actual,
          maximumByteCount: VaultSyncCodec.maximumSnapshotByteCount
        )
      )
      XCTAssertTrue(error.localizedDescription.contains("\(actual) bytes"))
    }
  }

  func testRemoteSnapshotRejectsMalformedMetadataBeforeVersionUse() throws {
    let vaultKey = try VaultCrypto().generateVaultKey()
    let codec = VaultSyncCodec()
    let snapshot = try codec.seal(
      document: VaultDocument(),
      vaultKey: vaultKey,
      version: 1,
      accountId: syncAccountA
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
    XCTAssertEqual(
      try codec.versionForNextSyncSizeProjection(after: 2_000_000_000),
      2_000_000_000
    )
    XCTAssertEqual(
      try codec.versionForNextSyncSizeProjection(after: Int.max),
      2_000_000_000
    )
    XCTAssertThrowsError(try codec.versionForNextSyncSizeProjection(after: -1)) { error in
      XCTAssertEqual(error as? VaultSyncCodecError, .invalidVersion)
    }
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
    let accountId = syncAccountA
    let snapshot = try codec.seal(
      document: VaultDocument(syncState: SyncState(accountId: accountId)),
      vaultKey: vaultKey,
      version: 7,
      accountId: accountId
    )

    XCTAssertFalse(
      try codec.open(snapshot: snapshot, vaultKey: vaultKey, expectedAccountId: accountId)
        .requiresV2Upgrade)

    var relabeled = snapshot
    relabeled.version = 99
    relabeled.checksum = try v2SnapshotChecksum(
      version: relabeled.version, envelope: relabeled.envelope)

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
      accountId: syncAccountA
    )

    XCTAssertThrowsError(
      try codec.open(snapshot: snapshot, vaultKey: vaultKey, expectedAccountId: syncAccountB)
    ) { error in
      XCTAssertEqual(error as? VaultCryptoError, .authenticationFailed)
    }
  }

  func testLegacyV1SnapshotOpensOnlyWithConsistentEncryptedVersionAndSignalsUpgrade() throws {
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let accountId = syncAccountC
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

    let opened = try codec.open(
      snapshot: snapshot, vaultKey: vaultKey, expectedAccountId: accountId)

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
    var document = VaultDocument(
      syncState: SyncState(accountId: syncAccountA, sessionToken: "first"))
    let snapshot = try codec.seal(
      document: document, vaultKey: vaultKey, version: 1, accountId: syncAccountA)
    try codec.markSynced(document: &document, snapshot: snapshot)

    XCTAssertFalse(try codec.hasLocalChanges(in: document))
    document.syncState.sessionToken = "refreshed"
    XCTAssertFalse(try codec.hasLocalChanges(in: document))
    let deletionOperation = Base64URL.encode(Data(repeating: 0x4D, count: 32))
    document.syncState.accountDeletionIdempotencyKey = deletionOperation
    XCTAssertFalse(try codec.hasLocalChanges(in: document))
    let pendingSnapshot = try codec.seal(
      document: document,
      vaultKey: vaultKey,
      version: 2,
      accountId: syncAccountA
    )
    let opened = try codec.open(
      snapshot: pendingSnapshot,
      vaultKey: vaultKey,
      expectedAccountId: syncAccountA
    )
    XCTAssertNil(opened.document.syncState.accountDeletionIdempotencyKey)
    document.wallets.append(WalletRecord(label: "New", address: "0xabc", chainKind: .evm))
    XCTAssertTrue(try codec.hasLocalChanges(in: document))
  }

  func testChangingServerOrAccountClearsTokenAndRemoteBaseline() {
    var state = SyncState(
      accountId: syncAccountA,
      serverURL: "https://sync-a.example",
      sessionToken: "token-a",
      latestRemoteVersion: 9,
      lastChecksum: "snapshot-a",
      lastSyncedContentChecksum: "content-a",
      accountDeletionIdempotencyKey: Base64URL.encode(Data(repeating: 3, count: 32))
    )

    state.changeServer(to: "https://sync-b.example")

    XCTAssertEqual(state.serverURL, "https://sync-b.example")
    XCTAssertNil(state.accountId)
    XCTAssertEqual(state.sessionToken, "")
    XCTAssertEqual(state.latestRemoteVersion, 0)
    XCTAssertNil(state.lastChecksum)
    XCTAssertNil(state.lastSyncedContentChecksum)
    XCTAssertNil(state.accountDeletionIdempotencyKey)

    XCTAssertTrue(
      state.connect(accountId: syncAccountB, serverURL: state.serverURL, sessionToken: "token-b"))
    XCTAssertEqual(state.accountId, syncAccountB)
    XCTAssertEqual(state.sessionToken, "token-b")
    XCTAssertEqual(state.latestRemoteVersion, 0)

    state.latestRemoteVersion = 4
    state.lastChecksum = "snapshot-b"
    state.clearSession()
    XCTAssertEqual(state.accountId, syncAccountB)
    XCTAssertEqual(state.serverURL, "https://sync-b.example")
    XCTAssertEqual(state.sessionToken, "")
    XCTAssertEqual(state.latestRemoteVersion, 4)
    XCTAssertEqual(state.lastChecksum, "snapshot-b")

    state.disconnectAccount()
    XCTAssertNil(state.accountId)
    XCTAssertEqual(state.serverURL, "https://sync-b.example")
    XCTAssertEqual(state.sessionToken, "")
    XCTAssertEqual(state.latestRemoteVersion, 0)
    XCTAssertNil(state.lastChecksum)
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

final class InMemoryVaultKeyStore: VaultKeyStore, @unchecked Sendable {
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
final class SimulatedFirstRunRaceVaultKeyStore: VaultKeyStore, @unchecked Sendable {
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
