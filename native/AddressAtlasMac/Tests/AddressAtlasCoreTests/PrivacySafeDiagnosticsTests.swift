import XCTest

@testable import AddressAtlasCore

final class PrivacySafeDiagnosticsTests: XCTestCase {
  func testClosedEventVocabularyHasStableUniqueCodesAndOperations() {
    let codes = PrivacySafeDiagnosticCode.allCases.map(\.rawValue)
    XCTAssertEqual(Set(codes).count, codes.count)
    XCTAssertTrue(
      codes.allSatisfy { code in
        !code.isEmpty
          && code.utf8.allSatisfy { byte in
            (97...122).contains(byte) || byte == 46 || byte == 95
          }
      }
    )
    XCTAssertEqual(
      PrivacySafeDiagnosticCode.passkeyAuthenticationFailed.operation,
      .passkey
    )
    XCTAssertEqual(PrivacySafeDiagnosticCode.syncDownloadFailed.operation, .sync)
    XCTAssertEqual(PrivacySafeDiagnosticCode.scanFailed.operation, .scan)
    XCTAssertEqual(PrivacySafeDiagnosticCode.storageSaveFailed.operation, .storage)
    XCTAssertEqual(PrivacySafeDiagnosticCode.recoveryKitRestoreFailed.operation, .recovery)
  }

  func testReportBoundsVersionComponentsAndContainsOnlyClosedFields() {
    let canaries = [
      "https://sync.secret.example/private?token=diagnostic-secret",
      "0xA11ce0000000000000000000000000000000BEEF",
      "My private treasury wallet",
      "v1.session.super-secret-token",
      "/Users/example/Library/Application Support/AddressAtlas/vault.sqlite",
    ]
    var log = PrivacySafeDiagnosticLog()
    log.record(.storageUnlockFailed)
    log.record(.passkeyAuthenticationFailed)
    let report = log.report(
      snapshot: snapshot(
        appMajorVersion: Int.max,
        appMinorVersion: -1,
        appPatchVersion: 2
      )
    )

    XCTAssertTrue(report.contains("app_version=999999.0.2"))
    XCTAssertTrue(report.contains("event.1=storage:storage.unlock_failed"))
    XCTAssertTrue(report.contains("event.2=passkey:passkey.authentication_failed"))
    XCTAssertLessThanOrEqual(
      report.utf8.count,
      PrivacySafeDiagnosticLog.maximumReportUTF8ByteCount
    )
    for canary in canaries {
      XCTAssertFalse(report.contains(canary), "Leaked canary: \(canary)")
    }
  }

  func testRingBufferRetainsOnlyNewestBoundedEventsAndSignalsTruncation() {
    var log = PrivacySafeDiagnosticLog()
    for index in 0..<(PrivacySafeDiagnosticLog.maximumEventCount + 7) {
      log.record(index.isMultiple(of: 2) ? .scanFailed : .syncUploadFailed)
    }

    XCTAssertEqual(log.events.count, PrivacySafeDiagnosticLog.maximumEventCount)
    XCTAssertTrue(log.didDropEvents)
    let report = log.report(snapshot: snapshot())
    XCTAssertTrue(report.contains("event_history_truncated=true"))
    XCTAssertTrue(
      report.contains("event_count=\(PrivacySafeDiagnosticLog.maximumEventCount)")
    )
    XCTAssertLessThanOrEqual(
      report.utf8.count,
      PrivacySafeDiagnosticLog.maximumReportUTF8ByteCount
    )
  }

  func testCountBucketsNeverRevealExactLargerCounts() {
    XCTAssertEqual(PrivacySafeCountBucket(count: 0), .none)
    XCTAssertEqual(PrivacySafeCountBucket(count: 1), .one)
    XCTAssertEqual(PrivacySafeCountBucket(count: 5), .few)
    XCTAssertEqual(PrivacySafeCountBucket(count: 20), .several)
    XCTAssertEqual(PrivacySafeCountBucket(count: 21), .many)
    XCTAssertEqual(PrivacySafeCountBucket(count: Int.max), .many)
  }

  private func snapshot(
    appMajorVersion: Int = 0,
    appMinorVersion: Int = 2,
    appPatchVersion: Int = 0
  ) -> PrivacySafeDiagnosticSnapshot {
    PrivacySafeDiagnosticSnapshot(
      appMajorVersion: appMajorVersion,
      appMinorVersion: appMinorVersion,
      appPatchVersion: appPatchVersion,
      osMajorVersion: 15,
      osMinorVersion: 5,
      osPatchVersion: 1,
      vaultSchemaVersion: 2,
      endpointConfigVersion: 4,
      vaultState: .unlocked,
      syncAccountBound: true,
      sessionState: .usable,
      syncPersistencePending: false,
      uploadRecoveryPending: false,
      uploadRecoveryQuarantined: false,
      rollbackCheckpointAvailable: true,
      remoteOutcomeUncertain: false,
      unsyncedLocalChanges: true,
      scanInProgress: false,
      syncInProgress: false,
      walletCount: .few,
      exchangeCount: .one,
      latestHoldingCount: .several
    )
  }
}
