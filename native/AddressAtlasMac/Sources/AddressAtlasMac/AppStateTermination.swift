import AddressAtlasCore
import Foundation

@MainActor
extension AppState {
  /// Freezes new UI-backed vault mutations synchronously, before AppKit yields
  /// termination to the asynchronous durability check.
  @discardableResult
  func beginTerminationRequest() -> Bool {
    guard !isTerminationInProgress else { return false }
    setTerminationInProgress(true)
    return true
  }

  /// Waits for an existing save, makes any in-memory post-sync candidate
  /// durable, then applies every lifecycle-owned wallet-label draft to one
  /// document candidate before allowing AppKit to terminate. A failed
  /// validation or save re-enables the app and retains every unresolved state
  /// object for correction or retry.
  func prepareForTermination() async -> Bool {
    if !isTerminationInProgress {
      _ = beginTerminationRequest()
    }

    if let blocker = terminationBlockingOperationMessage {
      return cancelTermination(with: blocker)
    }

    let inFlightPersistenceSucceeded = await waitForPersistenceCompletion()
    guard inFlightPersistenceSucceeded else {
      let detail =
        error.isEmpty
        ? "The save wasn't confirmed."
        : error
      return cancelTermination(
        with: "Address Atlas couldn't finish saving before quitting. \(detail)"
      )
    }

    if let blocker = terminationBlockingOperationMessage {
      return cancelTermination(with: blocker)
    }

    if pendingVaultUpload != nil, pendingSyncPersistence != nil {
      return cancelTermination(
        with:
          "Address Atlas found two unfinished sync steps that conflict. Reopen the app before quitting."
      )
    }

    if let pendingSyncPersistence {
      guard
        await save(
          pendingSyncPersistence.document,
          projectedSyncVersion: pendingSyncPersistence.projectedSyncVersion,
          saveExactly: pendingSyncPersistence.saveExactly,
          resolvesPendingSyncPersistence: true,
          allowDuringTermination: true
        )
      else {
        let detail =
          error.isEmpty
          ? "The save wasn't confirmed."
          : error
        return cancelTermination(
          with:
            "Address Atlas couldn't save the last sync result before quitting. \(detail)"
        )
      }

      if let blocker = terminationBlockingOperationMessage {
        return cancelTermination(with: blocker)
      }
    } else if syncPersistencePending, pendingVaultUpload == nil,
      quarantinedPendingVaultUpload == nil
    {
      return cancelTermination(
        with:
          "Address Atlas can't save the unfinished sync step safely. Reopen it before quitting."
      )
    }

    let candidate: VaultDocument
    do {
      candidate = try Self.documentByApplyingWalletLabelDrafts(
        walletLabelDrafts,
        to: document
      )
    } catch WalletLabelDraftError.invalidLabel {
      return cancelTermination(
        with:
          "Wallet names must be 1 to 80 characters. Fix the name before quitting."
      )
    } catch {
      return cancelTermination(
        with: "Address Atlas couldn't check the wallet name changes before quitting."
      )
    }

    guard candidate != document else {
      clearWalletLabelDrafts()
      return true
    }

    guard pendingVaultUpload == nil else {
      return cancelTermination(
        with:
          "Finish the interrupted upload before saving the wallet name and quitting."
      )
    }

    guard !syncPersistencePending, pendingSyncPersistence == nil else {
      return cancelTermination(
        with:
          "The unfinished sync step wasn't resolved. Reopen Address Atlas before quitting."
      )
    }

    guard
      await save(
        candidate,
        projectedSyncVersion: nil,
        allowDuringTermination: true
      )
    else {
      let detail =
        error.isEmpty
        ? "The save wasn't confirmed."
        : error
      return cancelTermination(
        with: "Address Atlas couldn't save the wallet name before quitting. \(detail)"
      )
    }

    if let blocker = terminationBlockingOperationMessage {
      return cancelTermination(with: blocker)
    }

    clearWalletLabelDrafts()
    return true
  }

  private func waitForPersistenceCompletion() async -> Bool {
    guard isPersisting else { return true }
    return await withCheckedContinuation { continuation in
      if isPersisting {
        persistenceCompletionWaiters.append(continuation)
      } else {
        continuation.resume(returning: true)
      }
    }
  }

  private var terminationBlockingOperationMessage: String? {
    if isUnlocking {
      return "Wait for recovery to finish before quitting."
    }
    if scanning {
      return "Wait for the scan to finish, or cancel it, before quitting."
    }
    if syncing {
      return "Wait for the sync to finish before quitting."
    }
    if isValidatingExchangeCredentials {
      return "Wait for the exchange key check to finish before quitting."
    }
    if isExportOperationInProgress {
      return "Wait for the active export to finish before quitting."
    }
    return nil
  }

  @discardableResult
  private func cancelTermination(with message: String) -> Bool {
    setTerminationInProgress(false)
    notice = ""
    error = message
    return false
  }
}
