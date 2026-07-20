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
