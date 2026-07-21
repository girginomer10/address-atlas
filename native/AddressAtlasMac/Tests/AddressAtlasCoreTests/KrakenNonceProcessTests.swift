import Darwin
import Foundation
import XCTest

@testable import AddressAtlasCore

final class KrakenNonceProcessTests: XCTestCase {
  private static let helperFlag = "ADDRESS_ATLAS_KRAKEN_NONCE_PROCESS_HELPER"
  private static let statePathKey = "ADDRESS_ATLAS_KRAKEN_NONCE_STATE_PATH"
  private static let keychainServiceKey = "ADDRESS_ATLAS_KRAKEN_NONCE_KEYCHAIN_SERVICE"
  private static let keychainAccountKey = "ADDRESS_ATLAS_KRAKEN_NONCE_KEYCHAIN_ACCOUNT"
  private static let apiKeyKey = "ADDRESS_ATLAS_KRAKEN_NONCE_API_KEY"
  private static let dateKey = "ADDRESS_ATLAS_KRAKEN_NONCE_DATE"
  private static let readyPathKey = "ADDRESS_ATLAS_KRAKEN_NONCE_READY_PATH"
  private static let goPathKey = "ADDRESS_ATLAS_KRAKEN_NONCE_GO_PATH"
  private static let resultPathKey = "ADDRESS_ATLAS_KRAKEN_NONCE_RESULT_PATH"
  private static let behaviorKey = "ADDRESS_ATLAS_KRAKEN_NONCE_HELPER_BEHAVIOR"
  private static let crashAfterPersistExitStatus: Int32 = 86
  private static let helperTestIdentifier =
    "AddressAtlasCoreTests.KrakenNonceProcessTests/testTwoProcessesSerializeAndPersistStrictlyIncreasingNonces"

  func testTwoProcessesSerializeAndPersistStrictlyIncreasingNonces() async throws {
    #if hasFeature(ThreadSanitizer)
      throw XCTSkip(
        "Nested xctest processes cannot install TSan interceptors early enough; the normal test suite exercises the real multi-process harness."
      )
    #endif
    if Self.isThreadSanitizerActive {
      throw XCTSkip(
        "Nested xctest processes cannot install TSan interceptors early enough; the normal test suite exercises the real multi-process harness."
      )
    }

    if ProcessInfo.processInfo.environment[Self.helperFlag] == "1" {
      try await runSubprocessHelper()
      return
    }

    let directory = FileManager.default.temporaryDirectory.appending(
      path: "address-atlas-kraken-process-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let identifier = UUID().uuidString.lowercased()
    let keychainService = "com.addressatlas.tests.kraken-nonce.\(identifier)"
    let keychainAccount = "installation-secret-\(identifier)"
    let keychainStore = KeychainVaultKeyStore(
      service: keychainService,
      account: keychainAccount
    )
    let stateURL = directory.appending(path: "state.json")
    let goURL = directory.appending(path: "go")
    let apiKey = "subprocess-api-key-\(identifier)"
    let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    var workers: [Worker] = []
    defer {
      for worker in workers {
        if worker.process.isRunning {
          worker.process.terminate()
          worker.process.waitUntilExit()
        }
      }
      try? keychainStore.deleteVaultKey()
      try? FileManager.default.removeItem(at: directory)
    }

    for index in 0..<2 {
      let worker = try launchWorker(
        stateURL: stateURL,
        keychainService: keychainService,
        keychainAccount: keychainAccount,
        apiKey: apiKey,
        date: baseDate,
        readyURL: directory.appending(path: "ready-\(index)"),
        goURL: goURL,
        resultURL: directory.appending(path: "result-\(index)")
      )
      workers.append(worker)
    }

    guard Self.waitForFiles(workers.map(\.readyURL), timeout: 10) else {
      XCTFail(
        "Both OS processes must reach the barrier before nonce generation begins.\n"
          + processDiagnostics(workers)
      )
      return
    }
    guard FileManager.default.createFile(atPath: goURL.path, contents: Data()) else {
      XCTFail("Failed to release the subprocess barrier.")
      return
    }
    guard waitForExit(workers, timeout: 15) else {
      XCTFail(processDiagnostics(workers))
      return
    }
    guard workers.allSatisfy({ $0.process.terminationStatus == 0 }) else {
      XCTFail(processDiagnostics(workers))
      return
    }

    let firstWave = try workers.map { worker in
      try XCTUnwrap(Int64(String(contentsOf: worker.resultURL, encoding: .utf8)))
    }.sorted()
    let baseNonce = Int64(1_700_000_000_000)
    XCTAssertEqual(firstWave, [baseNonce, baseNonce + 1])
    XCTAssertEqual(try keychainStore.loadVaultKey()?.count, VaultCrypto.vaultKeyByteCount)

    // Simulate the exact failure boundary that matters for Kraken: the child
    // persists a nonce, then exits immediately without writing its result or
    // allowing XCTest to complete normally.
    let crashingResultURL = directory.appending(path: "result-crash")
    let crashingWorker = try launchWorker(
      stateURL: stateURL,
      keychainService: keychainService,
      keychainAccount: keychainAccount,
      apiKey: apiKey,
      date: baseDate.addingTimeInterval(-60),
      readyURL: directory.appending(path: "ready-crash"),
      goURL: goURL,
      resultURL: crashingResultURL,
      behavior: .crashAfterPersist
    )
    workers.append(crashingWorker)
    guard waitForExit([crashingWorker], timeout: 15) else {
      XCTFail(processDiagnostics([crashingWorker]))
      return
    }
    XCTAssertEqual(
      crashingWorker.process.terminationStatus,
      Self.crashAfterPersistExitStatus,
      processDiagnostics([crashingWorker])
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: crashingResultURL.path))
    let persistedAfterCrash = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
    )
    let persistedNonces = try XCTUnwrap(
      persistedAfterCrash["lastNonceByCredential"] as? [String: String]
    )
    XCTAssertEqual(Array(persistedNonces.values), [String(baseNonce + 2)])

    // A fresh process with the same regressed clock must observe the fsync'd
    // nonce consumed by the crashed process and advance beyond it.
    let durableWorker = try launchWorker(
      stateURL: stateURL,
      keychainService: keychainService,
      keychainAccount: keychainAccount,
      apiKey: apiKey,
      date: baseDate.addingTimeInterval(-60),
      readyURL: directory.appending(path: "ready-durable"),
      goURL: goURL,
      resultURL: directory.appending(path: "result-durable")
    )
    workers.append(durableWorker)
    guard waitForExit([durableWorker], timeout: 15) else {
      XCTFail(processDiagnostics([durableWorker]))
      return
    }
    guard durableWorker.process.terminationStatus == 0 else {
      XCTFail(processDiagnostics([durableWorker]))
      return
    }
    let durableNonce = try XCTUnwrap(
      Int64(String(contentsOf: durableWorker.resultURL, encoding: .utf8))
    )
    XCTAssertEqual(durableNonce, baseNonce + 3)
    XCTAssertFalse(try String(contentsOf: stateURL, encoding: .utf8).contains(apiKey))
  }

  private func runSubprocessHelper() async throws {
    let environment = ProcessInfo.processInfo.environment
    let statePath = try XCTUnwrap(environment[Self.statePathKey])
    let keychainService = try XCTUnwrap(environment[Self.keychainServiceKey])
    let keychainAccount = try XCTUnwrap(environment[Self.keychainAccountKey])
    let apiKey = try XCTUnwrap(environment[Self.apiKeyKey])
    let rawDate = try XCTUnwrap(environment[Self.dateKey])
    let readyPath = try XCTUnwrap(environment[Self.readyPathKey])
    let goPath = try XCTUnwrap(environment[Self.goPathKey])
    let resultPath = try XCTUnwrap(environment[Self.resultPathKey])
    let behavior = try XCTUnwrap(HelperBehavior(rawValue: environment[Self.behaviorKey] ?? ""))
    let dateSeconds = try XCTUnwrap(TimeInterval(rawDate))

    try Data("ready".utf8).write(to: URL(fileURLWithPath: readyPath), options: .atomic)
    guard Self.waitForFiles([URL(fileURLWithPath: goPath)], timeout: 10) else {
      XCTFail("Timed out waiting for the parent process barrier.")
      return
    }

    let generator = KrakenNonceGenerator(
      isolatedTestStorageURL: URL(fileURLWithPath: statePath),
      keychainService: keychainService,
      keychainAccount: keychainAccount
    )
    let nonce = try await generator.next(
      apiKey: apiKey,
      at: Date(timeIntervalSince1970: dateSeconds)
    )
    if behavior == .crashAfterPersist {
      Darwin._exit(Self.crashAfterPersistExitStatus)
    }
    try Data(nonce.utf8).write(to: URL(fileURLWithPath: resultPath), options: .atomic)
  }

  private func launchWorker(
    stateURL: URL,
    keychainService: String,
    keychainAccount: String,
    apiKey: String,
    date: Date,
    readyURL: URL,
    goURL: URL,
    resultURL: URL,
    behavior: HelperBehavior = .returnResult
  ) throws -> Worker {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
      "xctest",
      "-XCTest",
      Self.helperTestIdentifier,
      Bundle(for: Self.self).bundleURL.path,
    ]
    var environment = ProcessInfo.processInfo.environment
    environment[Self.helperFlag] = "1"
    environment[Self.statePathKey] = stateURL.path
    environment[Self.keychainServiceKey] = keychainService
    environment[Self.keychainAccountKey] = keychainAccount
    environment[Self.apiKeyKey] = apiKey
    environment[Self.dateKey] = String(date.timeIntervalSince1970)
    environment[Self.readyPathKey] = readyURL.path
    environment[Self.goPathKey] = goURL.path
    environment[Self.resultPathKey] = resultURL.path
    environment[Self.behaviorKey] = behavior.rawValue
    process.environment = environment
    process.standardOutput = output
    process.standardError = output
    try process.run()
    return Worker(process: process, output: output, readyURL: readyURL, resultURL: resultURL)
  }

  private func waitForExit(_ workers: [Worker], timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while workers.contains(where: { $0.process.isRunning }), Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    return workers.allSatisfy { !$0.process.isRunning }
  }

  private func processDiagnostics(_ workers: [Worker]) -> String {
    workers.map { worker in
      if worker.process.isRunning { return "status=running" }
      let status = String(worker.process.terminationStatus)
      let output =
        String(
          data: worker.output.fileHandleForReading.availableData,
          encoding: .utf8
        ) ?? "<non-UTF8 output>"
      return "status=\(status) output=\(output)"
    }.joined(separator: "\n")
  }

  private static func waitForFiles(_ urls: [URL], timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
        return true
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
  }

  private static var isThreadSanitizerActive: Bool {
    guard let processHandle = Darwin.dlopen(nil, RTLD_NOW) else { return false }
    defer { Darwin.dlclose(processHandle) }
    return Darwin.dlsym(processHandle, "__tsan_init") != nil
  }

  private struct Worker {
    let process: Process
    let output: Pipe
    let readyURL: URL
    let resultURL: URL
  }

  private enum HelperBehavior: String {
    case returnResult
    case crashAfterPersist
  }
}
