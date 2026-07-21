import Darwin
import Foundation
import XCTest

@testable import AddressAtlasCore

final class RecoveryKitFileExportTests: XCTestCase {
  func testExportPublishesOwnerOnlyDurableDocumentBeforeReturningCode() throws {
    let fixture = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let destination = fixture.appending(path: "vault.atlas-recovery")
    // Prove replacement never inherits permissive metadata from an older file.
    try Data("old".utf8).write(to: destination)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o644))],
      ofItemAtPath: destination.path
    )
    let key = try VaultCrypto().generateVaultKey()

    let code = try RecoveryKitCodec().export(vaultKey: key, to: destination)

    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let document = try JSONDecoder.addressAtlas.decode(
      RecoveryKitDocument.self,
      from: Data(contentsOf: destination)
    )
    XCTAssertEqual(try RecoveryKitCodec().open(document, recoveryCode: code), key)
    XCTAssertEqual(try visibleNames(in: fixture), ["vault.atlas-recovery"])
  }

  func testExportFailureAtWriteDoesNotPublishOrRevealCode() throws {
    try assertPreRenameFailure { operations in
      operations.write = { _, _, _ in 0 }
    }
  }

  func testExportFailureAtFullSyncDoesNotPublishOrRevealCode() throws {
    try assertPreRenameFailure { operations in
      operations.fullSynchronize = { _ in false }
    }
  }

  func testPublishedInodeFullSyncFailureStillDoesNotRevealCode() throws {
    let fixture = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let destination = fixture.appending(path: "vault.atlas-recovery")
    var operations = AtomicFilePublicationOperations.production
    var fullSyncCalls = 0
    operations.fullSynchronize = { descriptor in
      fullSyncCalls += 1
      guard fullSyncCalls == 1 else { return false }
      return MacOSFileDurability.fullSynchronizeRegularFile(descriptor)
    }
    var revealedCode: String?

    XCTAssertThrowsError(
      try {
        revealedCode = try RecoveryKitCodec().export(
          vaultKey: VaultCrypto().generateVaultKey(),
          to: destination,
          publicationOperations: operations
        )
      }()
    ) { error in
      XCTAssertEqual(
        error as? AtomicFilePublicationError,
        .publishedFileVerificationFailed
      )
    }
    XCTAssertEqual(fullSyncCalls, 2)
    XCTAssertNil(revealedCode)
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
  }

  func testExportFailureAtRenameDoesNotPublishOrRevealCode() throws {
    try assertPreRenameFailure { operations in
      operations.rename = { _, _, _, _ in false }
    }
  }

  func testDirectorySyncFailureNeverReturnsRecoveryCode() throws {
    let fixture = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let destination = fixture.appending(path: "vault.atlas-recovery")
    let key = try VaultCrypto().generateVaultKey()
    var operations = AtomicFilePublicationOperations.production
    operations.synchronizeDirectory = { _ in false }
    var revealedCode: String?

    XCTAssertThrowsError(
      try {
        revealedCode = try RecoveryKitCodec().export(
          vaultKey: key,
          to: destination,
          publicationOperations: operations
        )
      }()
    ) { error in
      XCTAssertEqual(error as? AtomicFilePublicationError, .durabilityUnavailable)
    }
    XCTAssertNil(revealedCode)
    // Rename visibility is not durability. The file may be present, but the
    // caller receives neither success nor the only code that can unwrap it.
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
  }

  func testExportRejectsSymlinkDestinationWithoutTouchingTarget() throws {
    let fixture = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let target = fixture.appending(path: "target")
    let destination = fixture.appending(path: "vault.atlas-recovery")
    let original = Data("must remain".utf8)
    try original.write(to: target)
    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)

    XCTAssertThrowsError(
      try RecoveryKitCodec().export(
        vaultKey: VaultCrypto().generateVaultKey(),
        to: destination
      )
    ) { error in
      XCTAssertEqual(error as? AtomicFilePublicationError, .unsafeDestination)
    }
    XCTAssertEqual(try Data(contentsOf: target), original)
    XCTAssertEqual(try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
  }

  func testExportRejectsSymlinkedParentAndHardLinkedDestination() throws {
    let fixture = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let actualDirectory = fixture.appending(path: "actual")
    let linkedDirectory = fixture.appending(path: "linked")
    try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(
      at: linkedDirectory,
      withDestinationURL: actualDirectory
    )
    XCTAssertThrowsError(
      try RecoveryKitCodec().export(
        vaultKey: VaultCrypto().generateVaultKey(),
        to: linkedDirectory.appending(path: "vault.atlas-recovery")
      )
    ) { error in
      XCTAssertEqual(error as? AtomicFilePublicationError, .unsafeDestination)
    }

    let original = actualDirectory.appending(path: "original")
    let hardLink = actualDirectory.appending(path: "vault.atlas-recovery")
    let originalBytes = Data("linked original".utf8)
    try originalBytes.write(to: original)
    try FileManager.default.linkItem(at: original, to: hardLink)
    XCTAssertThrowsError(
      try RecoveryKitCodec().export(
        vaultKey: VaultCrypto().generateVaultKey(),
        to: hardLink
      )
    ) { error in
      XCTAssertEqual(error as? AtomicFilePublicationError, .unsafeDestination)
    }
    XCTAssertEqual(try Data(contentsOf: original), originalBytes)
  }

  private func assertPreRenameFailure(
    mutate: (inout AtomicFilePublicationOperations) -> Void
  ) throws {
    let fixture = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let destination = fixture.appending(path: "vault.atlas-recovery")
    var operations = AtomicFilePublicationOperations.production
    mutate(&operations)
    var revealedCode: String?

    XCTAssertThrowsError(
      try {
        revealedCode = try RecoveryKitCodec().export(
          vaultKey: VaultCrypto().generateVaultKey(),
          to: destination,
          publicationOperations: operations
        )
      }()
    )
    XCTAssertNil(revealedCode)
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertEqual(try visibleNames(in: fixture), [])
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "RecoveryKitFileExportTests-" + UUID().uuidString
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    return directory
  }

  private func visibleNames(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ).map(\.lastPathComponent).sorted()
  }
}
