import Foundation
import XCTest
@testable import AddressAtlasCore

final class EndpointConfigTrustStoreTests: XCTestCase {
  func testSuccessfulVersion20SurvivesStoreRecreationAndRejectsVersion19() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let origin = URL(string: "https://sync.example")!

    let firstProcess = EndpointConfigTrustStore(fileURL: fixture.file)
    try await firstProcess.validateAndRecord(config(version: 20), for: origin)

    let relaunchedProcess = EndpointConfigTrustStore(fileURL: fixture.file)
    do {
      try await relaunchedProcess.validateAndRecord(config(version: 19), for: origin)
      XCTFail("Expected a persistent rollback rejection")
    } catch {
      XCTAssertEqual(
        error as? EndpointConfigTrustStoreError,
        .rollback(previous: 20, received: 19)
      )
    }
  }

  func testReadOnlyVersion20CandidateDoesNotBlockVersion19InAnotherStoreInstance() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let origin = URL(string: "https://sync.example")!

    try await EndpointConfigTrustStore(fileURL: fixture.file)
      .validate(config(version: 20), for: origin)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))

    try await EndpointConfigTrustStore(fileURL: fixture.file)
      .validateAndRecord(config(version: 19), for: origin)
    do {
      try await EndpointConfigTrustStore(fileURL: fixture.file)
        .validate(config(version: 18), for: origin)
      XCTFail("Expected the committed version 19 high-water mark to reject version 18")
    } catch {
      XCTAssertEqual(
        error as? EndpointConfigTrustStoreError,
        .rollback(previous: 19, received: 18)
      )
    }
  }

  func testCommitRevalidatesAfterAnotherStoreAdvancesDuringCandidateWindow() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let origin = URL(string: "https://sync.example")!
    let candidateStore = EndpointConfigTrustStore(fileURL: fixture.file)
    let advancingStore = EndpointConfigTrustStore(fileURL: fixture.file)

    try await candidateStore.validate(config(version: 20), for: origin)
    try await advancingStore.validateAndRecord(config(version: 21), for: origin)

    do {
      try await candidateStore.validateAndRecord(config(version: 20), for: origin)
      XCTFail("Expected commit-time rollback rejection after an independent advance")
    } catch {
      XCTAssertEqual(
        error as? EndpointConfigTrustStoreError,
        .rollback(previous: 21, received: 20)
      )
    }
  }

  func testCommitRevalidatesAfterAnotherStoreCommitsEquivocationDuringCandidateWindow()
    async throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let origin = URL(string: "https://sync.example")!
    let candidateStore = EndpointConfigTrustStore(fileURL: fixture.file)
    let competingStore = EndpointConfigTrustStore(fileURL: fixture.file)

    let candidate = config(version: 20, message: "candidate")
    try await candidateStore.validate(candidate, for: origin)
    try await competingStore.validateAndRecord(
      config(version: 20, message: "competing"),
      for: origin
    )

    do {
      try await candidateStore.validateAndRecord(candidate, for: origin)
      XCTFail("Expected commit-time equivocation rejection after an independent commit")
    } catch {
      XCTAssertEqual(error as? EndpointConfigTrustStoreError, .equivocation(version: 20))
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
    let firstConfig = config(version: 15, message: "first")
    let secondConfig = config(version: 15, message: "second")

    async let first = Self.acceptance(
      by: firstStore,
      config: firstConfig,
      origin: origin
    )
    async let second = Self.acceptance(
      by: secondStore,
      config: secondConfig,
      origin: origin
    )
    let outcomes = await [first, second]

    XCTAssertEqual(outcomes.filter { $0 }.count, 1)
  }

  func testPostRenameDirectorySyncFailureReportsUncertainUntilRetryIsDurable() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let origin = URL(string: "https://sync.example")!
    let directorySync = DirectorySyncResultSequence([false, true])
    let store = EndpointConfigTrustStore(
      fileURL: fixture.file,
      postRenameDirectorySync: { _ in directorySync.next() }
    )

    // Once rename has published the new file, a later durability-barrier error
    // cannot truthfully be surfaced as rollback. Report the distinct state so
    // callers keep sensitive network work fail-closed while preserving the
    // visible high-water mark.
    let firstOutcome = try await store.validateAndRecord(config(version: 20), for: origin)
    XCTAssertEqual(firstOutcome, .committedDurabilityUncertain)

    do {
      try await EndpointConfigTrustStore(fileURL: fixture.file)
        .validateAndRecord(config(version: 19), for: origin)
      XCTFail("Expected the post-rename version 20 record to remain authoritative")
    } catch {
      XCTAssertEqual(
        error as? EndpointConfigTrustStoreError,
        .rollback(previous: 20, received: 19)
      )
    }

    // An exact same-record retry performs the missing directory barrier rather
    // than incorrectly treating mere visibility as proof of durability.
    let relaunchedStore = EndpointConfigTrustStore(
      fileURL: fixture.file,
      postRenameDirectorySync: { _ in directorySync.next() }
    )
    let retryOutcome = try await relaunchedStore.validateAndRecord(
      config(version: 20),
      for: origin
    )
    XCTAssertEqual(retryOutcome, .durable)
    XCTAssertEqual(directorySync.callCount, 2)
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

  private static func acceptance(
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
      return false
    }
  }
}

private final class DirectorySyncResultSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [Bool]
  private var count = 0

  init(_ results: [Bool]) {
    self.results = results
  }

  func next() -> Bool {
    lock.withLock {
      count += 1
      return results.isEmpty ? true : results.removeFirst()
    }
  }

  var callCount: Int {
    lock.withLock { count }
  }
}
