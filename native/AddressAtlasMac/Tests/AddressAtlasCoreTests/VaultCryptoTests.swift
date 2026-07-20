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

    let envelope = try crypto.sealJSON(document, with: key, keyId: "sync-v1")
    let opened = try crypto.openJSON(VaultDocument.self, envelope: envelope, with: key)

    XCTAssertEqual(opened.wallets.first?.address, document.wallets.first?.address)

    let wrongKey = try crypto.deriveKey(from: crypto.generateVaultKey(), purpose: .syncBlob)
    XCTAssertThrowsError(
      try crypto.openJSON(VaultDocument.self, envelope: envelope, with: wrongKey))
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
