import AddressAtlasCore
import SwiftUI

struct SyncView: View {
  @EnvironmentObject private var state: AppState
  @State private var restoreConfirmation = false
  @State private var deleteConfirmation = false
  @State private var migrationConfirmation = false
  @State private var resetConfirmation = false
  @State private var rollbackConfirmation = false

  init(initialServerURL: String = "") {}

  var body: some View {
    Page(eyebrow: "Your Apple Account", title: "iCloud",
      subtitle: "Keep an encrypted copy of your portfolio in your own iCloud account.",
      statTitle: "Connection", statValue: state.syncing ? "Working…" : state.iCloudStatus) {
      Surface {
        VStack(alignment: .leading, spacing: 18) {
          PanelHeader(title: "Your vault in iCloud",
            subtitle: "No separate account or Address Atlas backup server",
            systemImage: "icloud.fill")
          Text("Save from this Mac, then restore on another Mac using the same Apple Account. Enable iCloud Passwords & Keychain on both Macs so the encryption key can arrive.")
          if let cloud = state.document.iCloudState {
            Text("Last completed transfer: \(cloud.savedAt.formatted(date: .abbreviated, time: .shortened))")
              .foregroundStyle(.secondary)
          }
          AdaptiveStack(horizontalSpacing: 12) {
            Button("Save to iCloud") { Task { await state.saveToICloud() } }
              .buttonStyle(AtlasPrimaryButtonStyle())
            Button("Restore from iCloud") { restoreConfirmation = true }
          }
          .disabled(state.vaultEditsDisabled || !state.isUnlocked)
          if state.syncing {
            ProgressView("Transferring encrypted data…")
              .accessibilityLabel("iCloud transfer in progress")
          }
          Text("Transfers happen only when you choose. Restoring replaces this Mac’s portfolio after keeping a local rollback copy. Newer changes from another Mac are never overwritten silently.")
            .font(.callout).foregroundStyle(.secondary)
          Text("Exchange credentials travel encrypted. Kraken connections still require a separate API key on each Mac. iCloud storage counts toward your Apple Account quota.")
            .font(.callout).foregroundStyle(.secondary)
          Button("Delete iCloud copy…", role: .destructive) { deleteConfirmation = true }
            .disabled(state.vaultEditsDisabled || !state.isUnlocked)
          if state.document.iCloudState != nil {
            Button("Reset iCloud connection…") { resetConfirmation = true }
              .disabled(state.vaultEditsDisabled)
          }
          if state.hasVaultRollbackCheckpoint {
            Button("Restore previous local copy") {
              rollbackConfirmation = true
            }.disabled(state.vaultEditsDisabled)
          }
          if state.pendingVaultUpload != nil || state.quarantinedPendingVaultUpload != nil {
            Text("An interrupted transfer from the retired server version is saved locally. Finish migration to keep this vault and stop that transfer. Existing server data is not deleted by this action.")
            Button("Finish local migration…") { migrationConfirmation = true }
              .disabled(state.syncing || state.scanning || state.isPersisting)
          }
        }
      }
    }
    .confirmationDialog("Replace this Mac’s portfolio with the iCloud copy?",
      isPresented: $restoreConfirmation) {
      Button("Restore iCloud copy", role: .destructive) {
        Task { await state.restoreFromICloud() }
      }
    } message: { Text("A local rollback copy will be saved first. Export changes separately if you want to keep both portfolios.") }
    .confirmationDialog("Delete the Address Atlas copy in your current iCloud account?",
      isPresented: $deleteConfirmation) {
      Button("Delete iCloud copy", role: .destructive) { Task { await state.deleteICloudCopy() } }
    } message: { Text("Your local portfolio stays on this Mac. Other Macs keep their local copies too.") }
    .confirmationDialog("Stop the old server transfer and keep the local vault?",
      isPresented: $migrationConfirmation) {
      Button("Keep local vault and migrate") { Task { await state.finishLegacySyncMigration() } }
    }
    .confirmationDialog("Reset this Mac’s iCloud connection?", isPresented: $resetConfirmation) {
      Button("Reset connection") { Task { await state.resetICloudConnection() } }
    } message: { Text("Existing local and cloud copies remain. The next transfer uses the Apple Account currently signed in on this Mac.") }
    .confirmationDialog("Restore the previous local portfolio?", isPresented: $rollbackConfirmation) {
      Button("Restore previous local copy", role: .destructive) {
        Task { await state.restoreVaultRollbackCheckpoint() }
      }
    } message: { Text("This replaces the current local portfolio. The iCloud copy is not changed.") }
  }
}
