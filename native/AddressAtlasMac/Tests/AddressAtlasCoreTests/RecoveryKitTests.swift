import CryptoKit
import Foundation
import SQLite3
import XCTest

@testable import AddressAtlasCore

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
