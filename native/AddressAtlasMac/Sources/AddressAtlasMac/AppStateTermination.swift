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
        ? "The encrypted local vault did not confirm the save."
        : error
      return cancelTermination(
        with: "Address Atlas could not finish the active local save before quitting. \(detail)"
      )
    }

    if let blocker = terminationBlockingOperationMessage {
      return cancelTermination(with: blocker)
    }

    if pendingVaultUpload != nil, pendingSyncPersistence != nil {
      return cancelTermination(
        with:
          "Address Atlas found conflicting pending sync operations. Reopen the app before quitting."
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
          ? "The encrypted local vault did not confirm the save."
          : error
        return cancelTermination(
          with:
            "Address Atlas could not save the pending sync state before quitting. \(detail)"
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
          "The pending sync state cannot be saved safely. Reopen Address Atlas before quitting."
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
          "Wallet labels must be between 1 and 80 characters. Fix the draft before quitting."
      )
    } catch {
      return cancelTermination(
        with: "Address Atlas could not validate wallet-label changes before quitting."
      )
    }

    guard candidate != document else {
      clearWalletLabelDrafts()
      return true
    }

    guard pendingVaultUpload == nil else {
      return cancelTermination(
        with:
          "Finish the pending encrypted upload recovery before saving the wallet-label draft and quitting."
      )
    }

    guard !syncPersistencePending, pendingSyncPersistence == nil else {
      return cancelTermination(
        with:
          "The pending sync state was not fully resolved. Reopen Address Atlas before quitting."
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
        ? "The encrypted local vault did not confirm the save."
        : error
      return cancelTermination(
        with: "Address Atlas could not save the wallet label before quitting. \(detail)"
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
      return "Wait for vault recovery to finish before quitting."
    }
    if scanning {
      return "Cancel or finish the active scan before quitting."
    }
    if syncing {
      return "Wait for the active sync operation before quitting."
    }
    if isValidatingExchangeCredentials {
      return "Wait for the exchange credential check before quitting."
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
