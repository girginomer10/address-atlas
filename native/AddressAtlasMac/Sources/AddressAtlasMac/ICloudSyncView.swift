import AddressAtlasCore
import SwiftUI

/// The iCloud section of Settings: save an encrypted copy, restore it, and the
/// recovery actions around it. Nothing moves until the user chooses.
struct SyncView: View {
  @EnvironmentObject private var state: AppState
  @State private var restoreConfirmation = false
  @State private var deleteConfirmation = false
  @State private var migrationConfirmation = false
  @State private var resetConfirmation = false
  @State private var rollbackConfirmation = false

  init(initialServerURL: String = "") {}

  var body: some View {
    Surface {
      VStack(alignment: .leading, spacing: 16) {
        MacHeading("iCloud") {
          MacBadge(state.syncing ? "Working\u{2026}" : state.iCloudStatus)
        }
        Text(
          "Save an encrypted copy of your portfolio to your iCloud account, then restore it on another Mac, iPhone or iPad signed in to the same Apple Account. Turn on iCloud Passwords & Keychain on both so the key can arrive."
        )
        .font(AtlasTheme.font(.body, .callout))
        .foregroundStyle(AtlasTheme.ink2)
        .fixedSize(horizontal: false, vertical: true)
        if let cloud = state.document.iCloudState {
          Text("Last saved \(AtlasFormatting.dateTime(cloud.savedAt))")
            .font(AtlasTheme.font(.label, .caption))
            .foregroundStyle(AtlasTheme.ink3)
        }
        AdaptiveStack(horizontalSpacing: 12) {
          Button {
            Task { await state.saveToICloud() }
          } label: {
            Label("Save to iCloud", systemImage: "icloud.and.arrow.up")
          }
          .buttonStyle(MacPrimaryButtonStyle())
          Button {
            restoreConfirmation = true
          } label: {
            Label("Restore from iCloud", systemImage: "icloud.and.arrow.down")
          }
          .buttonStyle(MacSecondaryButtonStyle())
        }
        .disabled(state.vaultEditsDisabled || !state.isUnlocked)
        if state.syncing {
          ProgressView("Transferring encrypted data\u{2026}")
            .accessibilityLabel("iCloud transfer in progress")
        }
        VStack(alignment: .leading, spacing: 8) {
          Text(
            "Nothing transfers until you choose. Restoring replaces this Mac\u{2019}s portfolio after saving a backup copy on this Mac, and newer changes from another device are never overwritten silently."
          )
          Text(
            "Exchange keys travel encrypted, but Kraken needs its own API key on each Mac. The copy counts toward your iCloud storage."
          )
        }
        .font(AtlasTheme.font(.label, .caption))
        .foregroundStyle(AtlasTheme.ink3)
        .fixedSize(horizontal: false, vertical: true)

        if state.pendingVaultUpload != nil || state.quarantinedPendingVaultUpload != nil {
          InfoCallout(
            title: "An upload to the old sync server didn\u{2019}t finish",
            copy:
              "Stop it to keep your portfolio as it is on this Mac. Data already on the old server isn\u{2019}t deleted.",
            tone: .warning
          )
          Button("Stop the upload\u{2026}") { migrationConfirmation = true }
            .buttonStyle(MacSecondaryButtonStyle())
            .disabled(state.syncing || state.scanning || state.isPersisting)
        }

        Divider().overlay(AtlasTheme.ruleSoft)

        AdaptiveStack(horizontalSpacing: 12) {
          if state.hasVaultRollbackCheckpoint {
            Button("Restore earlier copy") {
              rollbackConfirmation = true
            }
            .buttonStyle(MacSecondaryButtonStyle())
            .disabled(state.vaultEditsDisabled)
          }
          if state.document.iCloudState != nil {
            Button("Reset iCloud connection\u{2026}") { resetConfirmation = true }
              .buttonStyle(MacSecondaryButtonStyle())
              .disabled(state.vaultEditsDisabled)
          }
          Button("Delete iCloud copy\u{2026}", role: .destructive) { deleteConfirmation = true }
            .buttonStyle(MacSecondaryButtonStyle())
            .disabled(state.vaultEditsDisabled || !state.isUnlocked)
        }
      }
    }
    .confirmationDialog(
      "Replace this Mac\u{2019}s portfolio with the iCloud copy?",
      isPresented: $restoreConfirmation
    ) {
      Button("Restore iCloud copy", role: .destructive) {
        Task { await state.restoreFromICloud() }
      }
    } message: {
      Text(
        "A backup copy is saved on this Mac first. Export your data separately if you want to keep both portfolios."
      )
    }
    .confirmationDialog(
      "Delete the Address Atlas copy in your iCloud account?",
      isPresented: $deleteConfirmation
    ) {
      Button("Delete iCloud copy", role: .destructive) { Task { await state.deleteICloudCopy() } }
    } message: {
      Text("Your portfolio stays on this Mac, and other devices keep their local copies.")
    }
    .confirmationDialog(
      "Stop the old server upload and keep your portfolio on this Mac?",
      isPresented: $migrationConfirmation
    ) {
      Button("Stop upload") { Task { await state.finishLegacySyncMigration() } }
    } message: {
      Text("Data already on the old server isn\u{2019}t deleted.")
    }
    .confirmationDialog(
      "Reset this Mac\u{2019}s iCloud connection?", isPresented: $resetConfirmation
    ) {
      Button("Reset connection") { Task { await state.resetICloudConnection() } }
    } message: {
      Text(
        "Existing local and cloud copies stay. The next transfer uses the Apple Account signed in on this Mac now."
      )
    }
    .confirmationDialog(
      "Replace this Mac\u{2019}s portfolio with the earlier copy?", isPresented: $rollbackConfirmation
    ) {
      Button("Restore earlier copy", role: .destructive) {
        Task { await state.restoreVaultRollbackCheckpoint() }
      }
    } message: {
      Text("This replaces the current portfolio on this Mac. The iCloud copy isn\u{2019}t changed.")
    }
  }
}
