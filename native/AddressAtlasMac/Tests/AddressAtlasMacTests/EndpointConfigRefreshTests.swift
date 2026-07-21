import AddressAtlasCore
import Foundation
import XCTest

@testable import AddressAtlasMac

@MainActor
final class EndpointConfigRefreshTests: XCTestCase {
  func testPersistedHighWaterRejectsRollbackAndEquivocationAfterRelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "AppStateEndpointRelaunch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let trustFile = directory.appending(path: "trust.json")
    let serverURL = "https://sync.example"

    let firstProcess = AppState(
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(
          configVersion: 12, refreshAfterSeconds: 300, message: "accepted")
      ),
      endpointConfigTrustStore: EndpointConfigTrustStore(fileURL: trustFile)
    )
    firstProcess.document.syncState.serverURL = serverURL
    let firstAccepted = await firstProcess.refreshEndpointConfig(silent: true)
    XCTAssertTrue(firstAccepted)

    let relaunchedRollback = AppState(
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 11, refreshAfterSeconds: 300)
      ),
      endpointConfigTrustStore: EndpointConfigTrustStore(fileURL: trustFile)
    )
    relaunchedRollback.document.syncState.serverURL = serverURL
    let rollbackAccepted = await relaunchedRollback.refreshEndpointConfig(silent: true)
    XCTAssertFalse(rollbackAccepted)
    XCTAssertEqual(relaunchedRollback.endpointConfig, .bundled)

    let relaunchedEquivocation = AppState(
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(
          configVersion: 12, refreshAfterSeconds: 300, message: "changed")
      ),
      endpointConfigTrustStore: EndpointConfigTrustStore(fileURL: trustFile)
    )
    relaunchedEquivocation.document.syncState.serverURL = serverURL
    let equivocationAccepted = await relaunchedEquivocation.refreshEndpointConfig(silent: true)
    XCTAssertFalse(equivocationAccepted)
    XCTAssertEqual(relaunchedEquivocation.endpointConfig, .bundled)
  }

  func testAcceptedConfigMessagePublishesOperatorMessageAndAbsenceClearsIt() async {
    let client = ControllableEndpointConfigClient()
    let state = AppState(endpointConfigClient: client)
    state.document.syncState.serverURL = "https://sync.example"
    XCTAssertNil(state.operatorMessage)

    let withMessage = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    await client.resolve(
      "https://sync.example",
      with: NativeEndpointConfig(
        configVersion: 8,
        refreshAfterSeconds: 300,
        message: "  Scheduled\u{0000} maintenance\n tonight.  "
      )
    )
    let withMessageResult = await withMessage.value
    XCTAssertTrue(withMessageResult)
    XCTAssertEqual(state.operatorMessage, "Scheduled maintenance tonight.")

    let withoutMessage = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    await client.resolve(
      "https://sync.example",
      with: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300)
    )
    let withoutMessageResult = await withoutMessage.value
    XCTAssertTrue(withoutMessageResult)
    XCTAssertNil(state.operatorMessage)

    let whitespaceOnly = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    await client.resolve(
      "https://sync.example",
      with: NativeEndpointConfig(configVersion: 10, refreshAfterSeconds: 300, message: " \n\t ")
    )
    let whitespaceOnlyResult = await whitespaceOnly.value
    XCTAssertTrue(whitespaceOnlyResult)
    XCTAssertNil(state.operatorMessage)
  }

  func testConcurrentRefreshesForSameServerShareOneRequest() async {
    let client = CountingEndpointConfigClient(
      config: NativeEndpointConfig(configVersion: 24, refreshAfterSeconds: 300)
    )
    let state = AppState(endpointConfigClient: client)
    state.document.syncState.serverURL = "https://sync.example"

    async let first = state.refreshEndpointConfig(silent: true)
    async let second = state.refreshEndpointConfig(silent: true)
    let results = await (first, second)
    let requestCount = await client.requestCount

    XCTAssertTrue(results.0)
    XCTAssertTrue(results.1)
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(state.endpointConfig.configVersion, 24)
  }

  func testCancellingOneSharedRefreshDoesNotCancelTheOtherWaiter() async {
    let client = SharedEndpointConfigClient(
      config: NativeEndpointConfig(configVersion: 25, refreshAfterSeconds: 300)
    )
    let state = AppState(endpointConfigClient: client)
    state.document.syncState.serverURL = "https://sync.example"

    let first = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequestCount(1)
    let second = Task { await state.refreshEndpointConfig(silent: true) }
    await waitUntilRefreshWaiterCount(2, in: state)

    first.cancel()
    let firstResult = await first.value
    await waitUntilRefreshWaiterCount(1, in: state)
    let countsAfterCancellation = await client.counts()
    XCTAssertFalse(firstResult)
    XCTAssertEqual(countsAfterCancellation.cancellations, 0)
    XCTAssertEqual(countsAfterCancellation.requests, 1)

    await client.resolveAll()
    let secondResult = await second.value
    XCTAssertTrue(secondResult)
    XCTAssertEqual(state.endpointConfig.configVersion, 25)
    XCTAssertNil(state.endpointConfigRefreshRequest)
  }

  func testCancelledSharedWaiterKeepsRequestRegisteredForAThirdCaller() async {
    let client = SharedEndpointConfigClient(
      config: NativeEndpointConfig(configVersion: 26, refreshAfterSeconds: 300)
    )
    let state = AppState(endpointConfigClient: client)
    state.document.syncState.serverURL = "https://sync.example"

    let first = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequestCount(1)
    let second = Task { await state.refreshEndpointConfig(silent: true) }
    await waitUntilRefreshWaiterCount(2, in: state)
    let generation = state.endpointConfigRefreshRequest?.generation

    first.cancel()
    let firstResult = await first.value
    await waitUntilRefreshWaiterCount(1, in: state)
    XCTAssertFalse(firstResult)

    let third = Task { await state.refreshEndpointConfig(silent: true) }
    await waitUntilRefreshWaiterCount(2, in: state)
    let countsWithThirdWaiter = await client.counts()
    XCTAssertEqual(state.endpointConfigRefreshRequest?.generation, generation)
    XCTAssertEqual(countsWithThirdWaiter.requests, 1)
    XCTAssertEqual(countsWithThirdWaiter.cancellations, 0)

    await client.resolveAll()
    let survivingResults = await (second.value, third.value)
    XCTAssertTrue(survivingResults.0)
    XCTAssertTrue(survivingResults.1)
    XCTAssertEqual(state.endpointConfig.configVersion, 26)
    XCTAssertNil(state.endpointConfigRefreshRequest)
  }

  func testCancellingTheFinalSharedWaiterCancelsFetchAndClearsRegistry() async {
    let client = SharedEndpointConfigClient(
      config: NativeEndpointConfig(configVersion: 27, refreshAfterSeconds: 300)
    )
    let state = AppState(endpointConfigClient: client)
    state.document.syncState.serverURL = "https://sync.example"

    let first = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequestCount(1)
    let second = Task { await state.refreshEndpointConfig(silent: true) }
    await waitUntilRefreshWaiterCount(2, in: state)

    first.cancel()
    let firstResult = await first.value
    await waitUntilRefreshWaiterCount(1, in: state)
    let countsWithOneOwner = await client.counts()
    XCTAssertFalse(firstResult)
    XCTAssertEqual(countsWithOneOwner.cancellations, 0)

    second.cancel()
    let secondResult = await second.value
    await client.waitUntilCancellationCount(1)
    let finalCounts = await client.counts()
    XCTAssertFalse(secondResult)
    XCTAssertEqual(finalCounts.requests, 1)
    XCTAssertEqual(finalCounts.cancellations, 1)
    XCTAssertNil(state.endpointConfigRefreshRequest)
    XCTAssertEqual(state.endpointConfig, .bundled)
    XCTAssertEqual(state.error, "")
  }

  func testCancellingRefreshCancelsUnderlyingFetchWithoutPublishingAnEndpointFailure() async {
    let client = CancellationObservingEndpointConfigClient()
    let state = AppState(endpointConfigClient: client)
    state.document.syncState.serverURL = "https://sync.example"

    let refresh = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested()
    refresh.cancel()

    let accepted = await refresh.value
    await client.waitUntilCancellationObserved()
    let cancellationObserved = await client.cancellationObserved
    XCTAssertFalse(accepted)
    XCTAssertTrue(cancellationObserved)
    XCTAssertEqual(state.endpointConfig, .bundled)
    XCTAssertEqual(state.endpointConfigStatus, "Bundled endpoints")
    XCTAssertNil(state.endpointConfigRefreshRequest)
    XCTAssertEqual(state.error, "")
  }

  func testCancellingScanDuringEndpointRefreshReportsScanCancellation() async {
    let client = CancellationObservingEndpointConfigClient()
    let state = AppState(endpointConfigClient: client)
    state.vaultKey = Data(repeating: 0xA5, count: VaultCrypto.vaultKeyByteCount)
    state.document.syncState.serverURL = "https://sync.example"

    let scan = Task { await state.scanSavedWallets() }
    await client.waitUntilRequested()
    scan.cancel()
    await scan.value

    await client.waitUntilCancellationObserved()
    let cancellationObserved = await client.cancellationObserved
    XCTAssertTrue(cancellationObserved)
    XCTAssertFalse(state.scanning)
    XCTAssertEqual(state.notice, "Scan cancelled.")
    XCTAssertEqual(state.error, "")
    XCTAssertTrue(state.document.scanRuns.isEmpty)
  }

  func testRefreshLoopFetchesConfigProactivelyAfterUnlock() async {
    let client = ControllableEndpointConfigClient()
    let state = AppState(endpointConfigClient: client)
    state.isUnlocked = true
    state.document.syncState.serverURL = "https://sync.example"

    let refreshLoop = Task { await state.runEndpointConfigRefreshLoop() }
    await client.waitUntilRequested("https://sync.example")
    await client.resolve(
      "https://sync.example",
      with: NativeEndpointConfig(configVersion: 23, refreshAfterSeconds: 300)
    )
    // Let the accepted response cross the MainActor publication boundary
    // before cancelling the long-lived owner. Cancellation now intentionally
    // propagates into an in-flight endpoint request.
    for _ in 0..<100 where state.endpointConfig.configVersion != 23 {
      await Task.yield()
    }
    XCTAssertEqual(state.endpointConfig.configVersion, 23)
    XCTAssertEqual(state.endpointConfig.refreshAfterSeconds, 300)
    refreshLoop.cancel()
    await refreshLoop.value

    XCTAssertEqual(state.endpointConfig.configVersion, 23)
    XCTAssertEqual(state.endpointConfig.refreshAfterSeconds, 300)
  }

  func testStaleResponseCannotReplaceConfigForNewServer() async {
    let client = ControllableEndpointConfigClient()
    let state = AppState(endpointConfigClient: client)
    state.document.syncState.serverURL = "https://first.example"

    let firstRefresh = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://first.example")

    state.document.syncState.serverURL = "https://second.example"
    let secondRefresh = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://second.example")

    await client.resolve("https://second.example", with: NativeEndpointConfig(configVersion: 22))
    let secondResult = await secondRefresh.value
    XCTAssertTrue(secondResult)
    XCTAssertEqual(state.endpointConfig.configVersion, 22)

    await client.resolve("https://first.example", with: NativeEndpointConfig(configVersion: 11))
    let firstResult = await firstRefresh.value
    XCTAssertFalse(firstResult)
    XCTAssertEqual(state.endpointConfig.configVersion, 22)
  }

  func testServerSwitchPreventsCancelledRequestFromAdvancingOldOriginTrust() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "AppStateEndpointCancelledTrust-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let trustFile = directory.appending(path: "trust.json")
    let firstOrigin = "https://first.example"
    let secondOrigin = "https://second.example"
    let client = ControllableEndpointConfigClient()
    let state = AppState(
      endpointConfigClient: client,
      endpointConfigTrustStore: EndpointConfigTrustStore(fileURL: trustFile)
    )
    state.document.syncState.serverURL = firstOrigin

    let firstRefresh = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested(firstOrigin)
    let cancelledSharedTask = try XCTUnwrap(state.endpointConfigRefreshRequest?.task)

    // A direct document replacement is a supported restore/test boundary and
    // must invalidate the old authority before its delayed fetch can commit.
    state.document.syncState.serverURL = secondOrigin
    let secondRefresh = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested(secondOrigin)
    await client.resolve(
      secondOrigin,
      with: NativeEndpointConfig(configVersion: 22, refreshAfterSeconds: 300)
    )
    let secondAccepted = await secondRefresh.value
    XCTAssertTrue(secondAccepted)

    // This client deliberately ignores task cancellation until its continuation
    // is resumed, exercising the cancellation check between fetch and trust IO.
    await client.resolve(
      firstOrigin,
      with: NativeEndpointConfig(configVersion: 40, refreshAfterSeconds: 300)
    )
    let firstAccepted = await firstRefresh.value
    XCTAssertFalse(firstAccepted)
    do {
      _ = try await cancelledSharedTask.value
      XCTFail("Expected the invalidated shared request to be cancelled.")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Unexpected cancelled shared-request error: \(error)")
    }

    // If the cancelled v40 request wrote a stale durable record, this valid v39
    // response would be rejected as a rollback after the simulated relaunch.
    let revisitedOrigin = AppState(
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 39, refreshAfterSeconds: 300)
      ),
      endpointConfigTrustStore: EndpointConfigTrustStore(fileURL: trustFile)
    )
    revisitedOrigin.document.syncState.serverURL = firstOrigin
    let revisitAccepted = await revisitedOrigin.refreshEndpointConfig(silent: true)
    XCTAssertTrue(revisitAccepted)
    XCTAssertEqual(revisitedOrigin.endpointConfig.configVersion, 39)
  }

  func testServerSwitchDuringTrustStoreWriteCannotPublishStaleConfig() async {
    let client = ControllableEndpointConfigClient()
    let trustStore = FirstRecordBlockingEndpointConfigTrustStore()
    let state = AppState(
      endpointConfigClient: client,
      endpointConfigTrustStore: trustStore
    )
    state.document.syncState.serverURL = "https://first.example"

    let firstRefresh = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://first.example")
    await client.resolve(
      "https://first.example",
      with: NativeEndpointConfig(configVersion: 11, refreshAfterSeconds: 300)
    )
    await trustStore.waitUntilFirstRecordStarted()

    state.document.syncState.serverURL = "https://second.example"
    let secondRefresh = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://second.example")
    await client.resolve(
      "https://second.example",
      with: NativeEndpointConfig(configVersion: 22, refreshAfterSeconds: 300)
    )
    let secondResult = await secondRefresh.value
    XCTAssertTrue(secondResult)
    XCTAssertEqual(state.endpointConfig.configVersion, 22)

    await trustStore.resumeFirstRecord()
    let firstResult = await firstRefresh.value
    XCTAssertFalse(firstResult)
    XCTAssertEqual(state.endpointConfig.configVersion, 22)
    XCTAssertEqual(state.acceptedEndpointConfigServerURL?.absoluteString, "https://second.example")
  }

  func testSameServerRejectsRollbackAndPreservesAcceptedConfigOnFailure() async {
    let client = ControllableEndpointConfigClient()
    let state = AppState(endpointConfigClient: client)
    state.document.syncState.serverURL = "https://sync.example"

    let first = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    let accepted = NativeEndpointConfig(
      configVersion: 7,
      refreshAfterSeconds: 300,
      message: "accepted"
    )
    await client.resolve("https://sync.example", with: accepted)
    let firstResult = await first.value
    XCTAssertTrue(firstResult)

    let rollback = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    await client.resolve(
      "https://sync.example",
      with: NativeEndpointConfig(configVersion: 6, refreshAfterSeconds: 300, message: "stale")
    )
    let rollbackResult = await rollback.value
    XCTAssertFalse(rollbackResult)
    XCTAssertEqual(state.endpointConfig, accepted)
    XCTAssertTrue(state.endpointConfigStatus.contains("stale v6 rejected"))

    let unavailable = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    await client.reject("https://sync.example", with: URLError(.cannotConnectToHost))
    let unavailableResult = await unavailable.value
    XCTAssertFalse(unavailableResult)
    XCTAssertEqual(state.endpointConfig, accepted)
    XCTAssertEqual(state.endpointConfigStatus, "Remote v7 (refresh unavailable)")
  }

  func testUnsupportedAcceptedConfigKeepsUpdateRequiredAcrossRollbackEquivocationAndFailure() async
  {
    let client = ControllableEndpointConfigClient()
    let state = AppState(endpointConfigClient: client)
    state.document.syncState.serverURL = "https://sync.example"
    let unsupported = NativeEndpointConfig(
      configVersion: 7,
      refreshAfterSeconds: 300,
      minSupportedAppVersion: "999.0",
      message: "unsupported"
    )

    let initial = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    await client.resolve("https://sync.example", with: unsupported)
    let initialResult = await initial.value
    XCTAssertTrue(initialResult)
    XCTAssertFalse(state.isAppVersionSupported)
    XCTAssertEqual(state.endpointConfigStatus, "Update required")

    let rollback = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    await client.resolve(
      "https://sync.example",
      with: NativeEndpointConfig(configVersion: 6, refreshAfterSeconds: 300)
    )
    let rollbackResult = await rollback.value
    XCTAssertFalse(rollbackResult)
    XCTAssertEqual(state.endpointConfig, unsupported)
    XCTAssertTrue(state.endpointConfigStatus.contains("Update required"))
    XCTAssertTrue(state.endpointConfigStatus.contains("stale v6 rejected"))

    let equivocation = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    await client.resolve(
      "https://sync.example",
      with: NativeEndpointConfig(
        configVersion: 7,
        refreshAfterSeconds: 300,
        minSupportedAppVersion: "999.0",
        message: "changed without version"
      )
    )
    let equivocationResult = await equivocation.value
    XCTAssertFalse(equivocationResult)
    XCTAssertEqual(state.endpointConfig, unsupported)
    XCTAssertTrue(state.endpointConfigStatus.contains("Update required"))
    XCTAssertTrue(state.endpointConfigStatus.contains("conflicting refresh rejected"))

    let unavailable = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://sync.example")
    await client.reject("https://sync.example", with: URLError(.cannotConnectToHost))
    let unavailableResult = await unavailable.value
    XCTAssertFalse(unavailableResult)
    XCTAssertEqual(state.endpointConfig, unsupported)
    XCTAssertTrue(state.endpointConfigStatus.contains("Update required"))
    XCTAssertTrue(state.endpointConfigStatus.contains("refresh unavailable"))
  }

  func testServerSwitchResetsVersionMonotonicityButRejectsSameVersionEquivocation() async {
    let client = ControllableEndpointConfigClient()
    let state = AppState(endpointConfigClient: client)
    state.document.syncState.serverURL = "https://first.example"

    let first = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://first.example")
    await client.resolve(
      "https://first.example",
      with: NativeEndpointConfig(configVersion: 9, refreshAfterSeconds: 300, message: "first")
    )
    let firstResult = await first.value
    XCTAssertTrue(firstResult)

    state.document.syncState.serverURL = "https://second.example"
    let second = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://second.example")
    let secondAccepted = NativeEndpointConfig(
      configVersion: 6,
      refreshAfterSeconds: 300,
      message: "second"
    )
    await client.resolve("https://second.example", with: secondAccepted)
    let secondResult = await second.value
    XCTAssertTrue(secondResult)
    XCTAssertEqual(state.endpointConfig, secondAccepted)

    let equivocation = Task { await state.refreshEndpointConfig(silent: true) }
    await client.waitUntilRequested("https://second.example")
    await client.resolve(
      "https://second.example",
      with: NativeEndpointConfig(configVersion: 6, refreshAfterSeconds: 300, message: "changed")
    )
    let equivocationResult = await equivocation.value
    XCTAssertFalse(equivocationResult)
    XCTAssertEqual(state.endpointConfig, secondAccepted)
    XCTAssertTrue(state.endpointConfigStatus.contains("conflicting refresh rejected"))
  }

  private func waitUntilRefreshWaiterCount(_ expected: Int, in state: AppState) async {
    for _ in 0..<1_000 {
      if state.endpointConfigRefreshRequest?.waiterIDs.count == expected {
        return
      }
      await Task.yield()
    }
    XCTFail(
      "Expected \(expected) endpoint refresh waiters, got \(state.endpointConfigRefreshRequest?.waiterIDs.count ?? 0)"
    )
  }
}

private actor ControllableEndpointConfigClient: EndpointConfigFetching {
  private var requests: [String: CheckedContinuation<NativeEndpointConfig, Error>] = [:]
  private var requestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

  func fetch(from serverURL: URL) async throws -> NativeEndpointConfig {
    let origin = serverURL.absoluteString
    return try await withCheckedThrowingContinuation { continuation in
      requests[origin] = continuation
      let waiters = requestWaiters.removeValue(forKey: origin) ?? []
      for waiter in waiters {
        waiter.resume()
      }
    }
  }

  func waitUntilRequested(_ origin: String) async {
    guard requests[origin] == nil else { return }
    await withCheckedContinuation { continuation in
      requestWaiters[origin, default: []].append(continuation)
    }
  }

  func resolve(_ origin: String, with config: NativeEndpointConfig) {
    requests.removeValue(forKey: origin)?.resume(returning: config)
  }

  func reject(_ origin: String, with error: Error) {
    requests.removeValue(forKey: origin)?.resume(throwing: error)
  }
}

private actor FirstRecordBlockingEndpointConfigTrustStore: EndpointConfigTrustPersisting {
  private var recordCount = 0
  private var firstRecordContinuation: CheckedContinuation<Void, Never>?
  private var firstRecordStarted = false
  private var firstRecordStartWaiters: [CheckedContinuation<Void, Never>] = []

  func validate(_: NativeEndpointConfig, for _: URL) async throws {}

  func validateAndRecord(_: NativeEndpointConfig, for _: URL) async throws {
    recordCount += 1
    guard recordCount == 1 else { return }
    firstRecordStarted = true
    let waiters = firstRecordStartWaiters
    firstRecordStartWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      firstRecordContinuation = continuation
    }
  }

  func waitUntilFirstRecordStarted() async {
    guard !firstRecordStarted else { return }
    await withCheckedContinuation { continuation in
      firstRecordStartWaiters.append(continuation)
    }
  }

  func resumeFirstRecord() {
    firstRecordContinuation?.resume()
    firstRecordContinuation = nil
  }
}

private actor CancellationObservingEndpointConfigClient: EndpointConfigFetching {
  private var requested = false
  private var requestWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var cancellationObserved = false
  private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

  func fetch(from _: URL) async throws -> NativeEndpointConfig {
    requested = true
    let waiters = requestWaiters
    requestWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    do {
      try await Task.sleep(for: .seconds(60))
      return .bundled
    } catch is CancellationError {
      cancellationObserved = true
      let waiters = cancellationWaiters
      cancellationWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      throw CancellationError()
    }
  }

  func waitUntilRequested() async {
    guard !requested else { return }
    await withCheckedContinuation { continuation in
      requestWaiters.append(continuation)
    }
  }

  func waitUntilCancellationObserved() async {
    guard !cancellationObserved else { return }
    await withCheckedContinuation { continuation in
      cancellationWaiters.append(continuation)
    }
  }
}

private actor SharedEndpointConfigClient: EndpointConfigFetching {
  private let config: NativeEndpointConfig
  private var requests: [UUID: CheckedContinuation<NativeEndpointConfig, Error>] = [:]
  private var requestCountWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
  private var cancellationCountWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
  private(set) var requestCount = 0
  private(set) var cancellationCount = 0

  init(config: NativeEndpointConfig) {
    self.config = config
  }

  func fetch(from _: URL) async throws -> NativeEndpointConfig {
    try Task.checkCancellation()
    let requestID = UUID()
    requestCount += 1
    let readyWaiters =
      requestCountWaiters
      .filter { $0.key <= requestCount }
      .flatMap(\.value)
    requestCountWaiters = requestCountWaiters.filter { $0.key > requestCount }
    for waiter in readyWaiters {
      waiter.resume()
    }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        requests[requestID] = continuation
      }
    } onCancel: {
      Task { await self.cancel(requestID: requestID) }
    }
  }

  func waitUntilRequestCount(_ expected: Int) async {
    guard requestCount < expected else { return }
    await withCheckedContinuation { continuation in
      requestCountWaiters[expected, default: []].append(continuation)
    }
  }

  func waitUntilCancellationCount(_ expected: Int) async {
    guard cancellationCount < expected else { return }
    await withCheckedContinuation { continuation in
      cancellationCountWaiters[expected, default: []].append(continuation)
    }
  }

  func resolveAll() {
    let continuations = requests.values
    requests.removeAll()
    for continuation in continuations {
      continuation.resume(returning: config)
    }
  }

  func counts() -> (requests: Int, cancellations: Int) {
    (requestCount, cancellationCount)
  }

  private func cancel(requestID: UUID) {
    guard let continuation = requests.removeValue(forKey: requestID) else { return }
    cancellationCount += 1
    continuation.resume(throwing: CancellationError())
    let readyWaiters =
      cancellationCountWaiters
      .filter { $0.key <= cancellationCount }
      .flatMap(\.value)
    cancellationCountWaiters = cancellationCountWaiters.filter { $0.key > cancellationCount }
    for waiter in readyWaiters {
      waiter.resume()
    }
  }
}
