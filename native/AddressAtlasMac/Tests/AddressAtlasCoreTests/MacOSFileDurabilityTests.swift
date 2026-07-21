import Darwin
import Foundation
import XCTest

@testable import AddressAtlasCore

final class MacOSFileDurabilityTests: XCTestCase {
  func testRegularFileEINVALIsFailureRatherThanFsyncDowngrade() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let descriptor = Darwin.open(fixture.file.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    defer { Darwin.close(descriptor) }

    XCTAssertFalse(
      MacOSFileDurability.fullSynchronizeRegularFileForTesting(descriptor) {
        (-1, EINVAL)
      }
    )
  }

  func testRegularFileFullSyncRetriesOnlyEINTRAndRevalidatesIdentity() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let descriptor = Darwin.open(fixture.file.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    defer { Darwin.close(descriptor) }
    var calls = 0

    XCTAssertTrue(
      MacOSFileDurability.fullSynchronizeRegularFileForTesting(descriptor) {
        calls += 1
        return calls == 1 ? (-1, EINTR) : (0, 0)
      }
    )
    XCTAssertEqual(calls, 2)
  }

  func testDirectoryEINVALLeavesParentMetadataDurabilityUncertain() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let descriptor = Darwin.open(
      fixture.directory.path,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    defer { Darwin.close(descriptor) }

    XCTAssertFalse(
      MacOSFileDurability.synchronizeDirectoryForTesting(descriptor) {
        (-1, EINVAL)
      }
    )
  }

  func testFullSyncRejectsDirectoriesAndPipesBeforeCallingKernelOperation() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let directoryDescriptor = Darwin.open(
      fixture.directory.path,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
    defer { Darwin.close(directoryDescriptor) }
    var invoked = false

    XCTAssertFalse(
      MacOSFileDurability.fullSynchronizeRegularFileForTesting(directoryDescriptor) {
        invoked = true
        return (0, 0)
      }
    )
    XCTAssertFalse(invoked)
  }

  private func makeFixture() throws -> (directory: URL, file: URL) {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "MacOSFileDurabilityTests-\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "state")
    try Data("state".utf8).write(to: file)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o600))],
      ofItemAtPath: file.path
    )
    return (directory, file)
  }
}
