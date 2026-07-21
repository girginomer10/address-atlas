import CryptoKit
import Foundation
import XCTest

@testable import AddressAtlasCore

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
    let databaseStore = try EncryptedSQLiteVaultStore(
      path: vaultURL, vaultKey: vaultKey, crypto: crypto)
    try databaseStore.save(
      VaultDocument(wallets: [
        WalletRecord(
          label: "Recovered from file",
          address: "0x0000000000000000000000000000000000000abc",
          chainKind: .evm
        )
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
    try store.save(
      VaultDocument(wallets: [
        WalletRecord(
          label: "Recovered",
          address: "0x0000000000000000000000000000000000000abc",
          chainKind: .evm
        )
      ]))
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
    try store.save(
      VaultDocument(wallets: [
        WalletRecord(
          label: "Protected",
          address: "0x0000000000000000000000000000000000000abc",
          chainKind: .evm
        )
      ]))
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
