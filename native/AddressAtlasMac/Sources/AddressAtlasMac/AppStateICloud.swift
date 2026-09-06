import AddressAtlasCore
import Foundation

@MainActor
extension AppState {
  private func cloudService() throws -> any ICloudVaultSyncing {
    if let iCloudService { return iCloudService }
    guard ICloudVaultService.isConfigured else { throw ICloudVaultError.unavailable }
    let service = ICloudVaultService()
    iCloudService = service
    return service
  }

  func saveToICloud() async {
    guard !vaultEditsDisabled, isUnlocked, let vaultKey else { return }
    guard await flushWalletLabelDraftsBeforeRemoteOperation() else { return }
    guard !vaultEditsDisabled, beginSyncActivity(.uploadingVault) else { return }
    defer { finishSyncActivity(.uploadingVault) }
    let revision = documentRevision
    do {
      let receipt = try await cloudService().save(document, localKey: vaultKey)
      guard revision == documentRevision else { throw ICloudVaultError.conflict }
      var candidate = document
      candidate.iCloudState = receipt
      candidate.syncState = SyncState()
      guard await save(candidate, projectedSyncVersion: nil) else {
        iCloudStatus = "Saved remotely; local receipt failed"
        // A retry is conflict-protected even after a crash before saving this receipt.
        return
      }
      iCloudStatus = "Saved"
      notice = "Encrypted copy saved to your iCloud account."
    } catch { presentICloudError(error) }
  }

  func restoreFromICloud() async {
    guard !vaultEditsDisabled, isUnlocked, let vaultKey, let persistence else { return }
    guard await flushWalletLabelDraftsBeforeRemoteOperation() else { return }
    guard !vaultEditsDisabled, beginSyncActivity(.downloadingVault) else { return }
    defer { finishSyncActivity(.downloadingVault) }
    let revision = documentRevision
    do {
      let incoming = try await cloudService().restore(localKey: vaultKey,
        expectedAccount: document.iCloudState?.account)
      guard revision == documentRevision else { throw ICloudVaultError.conflict }
      _ = try await persistence.saveRollbackCheckpoint(document)
      hasVaultRollbackCheckpoint = true
      guard revision == documentRevision else { throw ICloudVaultError.conflict }
      guard await save(normalizedLoadedDocument(incoming), projectedSyncVersion: nil) else { return }
      iCloudStatus = "Restored"
      notice = "Restored from iCloud. Your previous local copy is available on this screen."
    } catch { presentICloudError(error) }
  }

  func deleteICloudCopy() async {
    guard !vaultEditsDisabled, isUnlocked else { return }
    guard beginSyncActivity(.deletingAccount) else { return }
    defer { finishSyncActivity(.deletingAccount) }
    do {
      try await cloudService().delete(expectedAccount: document.iCloudState?.account)
      var candidate = document
      candidate.iCloudState = nil
      guard await save(candidate, projectedSyncVersion: nil) else { return }
      iCloudStatus = "Deleted"
      notice = "The iCloud copy was deleted. Your local portfolio was kept."
    } catch { presentICloudError(error) }
  }

  func resetICloudConnection() async {
    guard !vaultEditsDisabled, isUnlocked else { return }
    var candidate = document
    candidate.iCloudState = nil
    guard await save(candidate, projectedSyncVersion: nil) else { return }
    iCloudStatus = "Not connected"
    notice = "Local iCloud connection reset. Existing cloud copies were kept. The next transfer uses the current Apple Account."
  }

  func finishLegacySyncMigration() async {
    if quarantinedPendingVaultUpload != nil {
      await discardQuarantinedPendingVaultUpload()
    } else if let server = AppState.validatedSyncURL(document.syncState.serverURL) {
      await abandonPendingVaultUpload(expectedServerURL: server)
    }
    guard pendingVaultUpload == nil, quarantinedPendingVaultUpload == nil else { return }
    var candidate = document
    candidate.syncState = SyncState()
    _ = await save(candidate, projectedSyncVersion: nil)
  }

  private func presentICloudError(_ failure: Error) {
    iCloudStatus = "Needs attention"
    notice = ""
    // CloudKit diagnostics can contain record/account details; do not echo them.
    error = (failure as? ICloudVaultError)?.errorDescription
      ?? "iCloud could not complete the transfer. Check your connection and iCloud storage, then try again. Your local vault is still available."
  }
}
