import AddressAtlasCore
import XCTest

final class EndpointConfigTrustStoreTests: XCTestCase {
  func testHighWaterSurvivesStoreRecreationAndRejectsRollback() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let origin = URL(string: "https://sync.example")!

    let firstProcess = EndpointConfigTrustStore(fileURL: fixture.file)
    try await firstProcess.validateAndRecord(config(version: 7), for: origin)

    let relaunchedProcess = EndpointConfigTrustStore(fileURL: fixture.file)
    do {
      try await relaunchedProcess.validateAndRecord(config(version: 6), for: origin)
      XCTFail("Expected a persistent rollback rejection")
    } catch {
      XCTAssertEqual(
        error as? EndpointConfigTrustStoreError,
        .rollback(previous: 7, received: 6)
      )
    }
  }

  func testHighWaterSurvivesStoreRecreationAndRejectsSameVersionEquivocation() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let origin = URL(string: "https://sync.example")!

    try await EndpointConfigTrustStore(fileURL: fixture.file)
      .validateAndRecord(config(version: 9, message: "first"), for: origin)

    let relaunchedProcess = EndpointConfigTrustStore(fileURL: fixture.file)
    do {
      try await relaunchedProcess.validateAndRecord(
        config(version: 9, message: "different"),
        for: origin
      )
      XCTFail("Expected persistent same-version equivocation rejection")
    } catch {
      XCTAssertEqual(error as? EndpointConfigTrustStoreError, .equivocation(version: 9))
    }
  }

  func testHistoricalHighWaterBelowCurrentBundledVersionCanAdvanceAfterAppUpgrade() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let origin = URL(string: "https://sync.example")!

    try await EndpointConfigTrustStore(fileURL: fixture.file)
      .validateAndRecord(config(version: 5), for: origin)
    let currentDocument = try String(contentsOf: fixture.file, encoding: .utf8)
    let historicalDocument = currentDocument.replacingOccurrences(
      of: "\"version\":5",
      with: "\"version\":4"
    )
    XCTAssertNotEqual(historicalDocument, currentDocument)
    try historicalDocument.write(to: fixture.file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o600))],
      ofItemAtPath: fixture.file.path
    )

    let upgradedAppStore = EndpointConfigTrustStore(fileURL: fixture.file)
    try await upgradedAppStore.validateAndRecord(config(version: 6), for: origin)
    do {
      try await upgradedAppStore.validateAndRecord(config(version: 5), for: origin)
      XCTFail("Expected the advanced post-upgrade high-water mark to reject rollback")
    } catch {
      XCTAssertEqual(
        error as? EndpointConfigTrustStoreError,
        .rollback(previous: 6, received: 5)
      )
    }
  }

  func testHighWaterIsScopedPerCanonicalOrigin() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = EndpointConfigTrustStore(fileURL: fixture.file)

    try await store.validateAndRecord(
      config(version: 20),
      for: URL(string: "https://one.example")!
    )
    try await store.validateAndRecord(
      config(version: 5),
      for: URL(string: "https://two.example")!
    )
  }

  func testCorruptStoreFailsClosedWithoutReplacingIt() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let original = Data("not-json".utf8)
    try original.write(to: fixture.file)

    do {
      try await EndpointConfigTrustStore(fileURL: fixture.file).validateAndRecord(
        config(version: 8),
        for: URL(string: "https://sync.example")!
      )
      XCTFail("Expected corrupt trust store rejection")
    } catch {
      XCTAssertEqual(error as? EndpointConfigTrustStoreError, .invalidStore)
    }
    XCTAssertEqual(try Data(contentsOf: fixture.file), original)
  }

  func testIndependentStoreInstancesSerializeSameVersionRace() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let origin = URL(string: "https://sync.example")!
    let firstStore = EndpointConfigTrustStore(fileURL: fixture.file)
    let secondStore = EndpointConfigTrustStore(fileURL: fixture.file)

    async let first = acceptance(
      by: firstStore,
      config: config(version: 15, message: "first"),
      origin: origin
    )
    async let second = acceptance(
      by: secondStore,
      config: config(version: 15, message: "second"),
      origin: origin
    )
    let outcomes = await [first, second]

    XCTAssertEqual(outcomes.filter { $0 }.count, 1)
  }

  private func config(version: Int, message: String? = nil) -> NativeEndpointConfig {
    var config = NativeEndpointConfig.bundled
    config.configVersion = version
    config.message = message
    return config
  }

  private func makeFixture() throws -> (directory: URL, file: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "EndpointConfigTrustStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, directory.appending(path: "trust.json"))
  }

  private func acceptance(
    by store: EndpointConfigTrustStore,
    config: NativeEndpointConfig,
    origin: URL
  ) async -> Bool {
    do {
      try await store.validateAndRecord(config, for: origin)
      return true
    } catch EndpointConfigTrustStoreError.equivocation {
      return false
    } catch {
      XCTFail("Unexpected trust-store error: \(error)")
      return false
    }
  }
}
