import AddressAtlasCore
import Foundation
import XCTest

@testable import AddressAtlasMac

@MainActor
extension AppStateNetworkBoundaryTests {
  func testDiagnosticsReportCannotIncludeVaultOrTransientErrorCanaries() {
    let addressCanary = "0xA11ce0000000000000000000000000000000BEEF"
    let urlCanary = "https://sync.secret.example/private?token=url-secret"
    let labelCanary = "My private treasury wallet"
    let noteCanary = "tax note only my accountant should see"
    let balanceCanary = "987654.321987"
    let credentialCanary = "sk_live_diagnostic_secret_123456"
    let sessionCanary = "v1.session.diagnostic-session-id.diagnostic-token"
    let accountCanary = "18181818-1818-4818-8818-181818181818"
    let pathCanary = "/Users/example/Library/Application Support/AddressAtlas/vault.sqlite"
    let asset = TrackedAsset(
      id: "private-asset-id",
      address: addressCanary,
      chainId: "private-chain-id",
      chainName: "Private Chain",
      family: .evm,
      symbol: "PRIV",
      name: "Private Asset",
      amount: 987_654.321_987,
      priceUsd: 1,
      valueUsd: 987_654.321_987,
      explorerUrl: "https://explorer.secret.example/\(addressCanary)",
      source: .native,
      walletLabel: labelCanary
    )
    let state = AppState()
    state.document = VaultDocument(
      wallets: [
        WalletRecord(label: labelCanary, address: addressCanary, chainKind: .evm)
      ],
      manualHoldings: [
        ManualHoldingRecord(
          label: labelCanary,
          provider: "private-provider",
          symbol: "PRIV",
          name: "Private Asset",
          amount: 987_654.321_987,
          priceUsd: 1,
          valueUsd: 987_654.321_987,
          notes: noteCanary
        )
      ],
      scanRuns: [
        ScanRunRecord(
          totalUsd: 987_654.321_987,
          inputCount: 1,
          holdings: [asset],
          warnings: ["provider response contained \(credentialCanary)"]
        )
      ],
      syncState: SyncState(
        accountId: accountCanary,
        serverURL: urlCanary,
        sessionToken: sessionCanary,
        remoteOutcomeUncertain: true
      )
    )
    state.notice = "session \(sessionCanary)"
    state.error =
      "raw failure \(credentialCanary) at \(pathCanary) for \(labelCanary) balance \(balanceCanary)"
    state.recordDiagnosticFailure(.scanFailed)
    state.recordDiagnosticFailure(.syncDownloadFailed)

    let report = state.privacySafeDiagnosticsReport()

    XCTAssertTrue(report.contains("event.1=scan:scan.failed"))
    XCTAssertTrue(report.contains("event.2=sync:sync.download_failed"))
    XCTAssertTrue(report.contains("wallet_count_bucket=one"))
    XCTAssertTrue(report.contains("latest_holding_count_bucket=one"))
    for canary in [
      addressCanary, urlCanary, labelCanary, noteCanary, balanceCanary,
      credentialCanary, sessionCanary, accountCanary, pathCanary,
    ] {
      XCTAssertFalse(report.contains(canary), "Leaked canary: \(canary)")
    }
    XCTAssertLessThanOrEqual(
      report.utf8.count,
      PrivacySafeDiagnosticLog.maximumReportUTF8ByteCount
    )
  }

  func testPasskeyFailureIsRecordedButIntentionalCancellationIsNot() async throws {
    let failedFixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: failedFixture.directory) }
    let failedState = AppState(
      testStore: failedFixture.store,
      document: VaultDocument(),
      testVaultKey: failedFixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 1, refreshAfterSeconds: 300)
      ),
      passkeyAuthenticator: RecordingPasskeyAuthenticator()
    )

    await failedState.signInWithPasskey(serverURL: "https://sync.example")

    XCTAssertTrue(
      failedState.privacySafeDiagnosticsReport().contains(
        "passkey:passkey.authentication_failed"
      )
    )

    let cancelledFixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: cancelledFixture.directory) }
    let cancelledState = AppState(
      testStore: cancelledFixture.store,
      document: VaultDocument(),
      testVaultKey: cancelledFixture.vaultKey,
      endpointConfigClient: FixedEndpointConfigClient(
        config: NativeEndpointConfig(configVersion: 1, refreshAfterSeconds: 300)
      ),
      passkeyAuthenticator: CancelledPasskeyAuthenticator()
    )

    await cancelledState.signInWithPasskey(serverURL: "https://sync.example")

    XCTAssertTrue(cancelledState.privacySafeDiagnosticLog.events.isEmpty)
    XCTAssertTrue(cancelledState.privacySafeDiagnosticsReport().contains("event_count=0"))
  }

  func testStorageAndRecoveryKitFailuresUseStableCodesWithoutErrorDetails() async throws {
    let fixture = try makeTemporaryStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let staleDocument = try fixture.store.load()
    let competingStore = try EncryptedSQLiteVaultStore(
      path: fixture.database,
      vaultKey: fixture.vaultKey
    )
    let competingDocument = try competingStore.load()
    try competingStore.save(competingDocument)
    let state = AppState(testStore: fixture.store, document: staleDocument)

    let didSave = await state.save()
    XCTAssertFalse(didSave)
    XCTAssertTrue(
      state.privacySafeDiagnosticsReport().contains("storage:storage.save_failed")
    )

    let lockedState = AppState()
    let destination = fixture.directory.appending(path: "diagnostic-recovery.atlas-recovery")
    XCTAssertThrowsError(try lockedState.exportRecoveryKit(to: destination))
    let report = lockedState.privacySafeDiagnosticsReport()
    XCTAssertTrue(report.contains("recovery:recovery.kit_export_failed"))
    XCTAssertFalse(report.contains(destination.path))
  }
}
