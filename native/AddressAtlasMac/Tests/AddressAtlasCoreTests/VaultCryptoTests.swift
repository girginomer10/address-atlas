import CryptoKit
import Foundation
import XCTest

@testable import AddressAtlasCore

final class VaultCryptoTests: XCTestCase {
  func testVaultEncryptionRoundTripsAndRejectsWrongKey() throws {
    let crypto = VaultCrypto()
    let vaultKey = try crypto.generateVaultKey()
    let key = try crypto.deriveKey(from: vaultKey, purpose: .syncBlob)
    let document = VaultDocument(wallets: [
      WalletRecord(
        label: "Vitalik", address: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", chainKind: .evm)
    ])

    let envelope = try crypto.sealJSON(
      document,
      with: key,
      keyId: "sync-v2",
      schemaVersion: VaultDocument.currentSchemaVersion
    )
    let opened = try crypto.openJSON(VaultDocument.self, envelope: envelope, with: key)

    XCTAssertEqual(opened.wallets.first?.address, document.wallets.first?.address)

    let wrongKey = try crypto.deriveKey(from: crypto.generateVaultKey(), purpose: .syncBlob)
    XCTAssertThrowsError(
      try crypto.openJSON(VaultDocument.self, envelope: envelope, with: wrongKey))
  }

  func testAuthenticatedVaultDecodeBindsInnerSchemaToEnvelope() throws {
    let key = try VaultCrypto().deriveKey(
      from: Data(repeating: 0x44, count: VaultCrypto.vaultKeyByteCount),
      purpose: .localDatabase
    )
    let crypto = VaultCrypto()
    let currentDocument = VaultDocument()
    var currentObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder.addressAtlas.encode(currentDocument))
        as? [String: Any]
    )
    currentObject.removeValue(forKey: "schemaVersion")
    let missingCurrentSchema = try JSONSerialization.data(
      withJSONObject: currentObject,
      options: [.sortedKeys]
    )
    let invalidCurrentEnvelope = try crypto.seal(
      missingCurrentSchema,
      with: key,
      keyId: "local-db",
      schemaVersion: VaultDocument.currentSchemaVersion
    )
    XCTAssertThrowsError(
      try crypto.openJSON(VaultDocument.self, envelope: invalidCurrentEnvelope, with: key)
    )

    let legacyPlaintext = Data(
      #"{"wallets":[],"updatedAt":"2026-01-01T00:00:00Z"}"#.utf8
    )
    let legacyEnvelope = try crypto.seal(
      legacyPlaintext,
      with: key,
      keyId: "local-db",
      schemaVersion: 1
    )
    XCTAssertNoThrow(
      try crypto.openJSON(VaultDocument.self, envelope: legacyEnvelope, with: key)
    )

    let mismatchedEnvelope = try crypto.seal(
      JSONEncoder.addressAtlas.encode(currentDocument),
      with: key,
      keyId: "local-db",
      schemaVersion: 1
    )
    XCTAssertThrowsError(
      try crypto.openJSON(VaultDocument.self, envelope: mismatchedEnvelope, with: key)
    )
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
