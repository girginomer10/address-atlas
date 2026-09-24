import AddressAtlasCore
import SwiftUI

/// iOS port of the macOS `SyncView`: the same iCloud actions, confirmations,
/// and safety wording, laid out for a phone. Transfers happen only on request,
/// the encryption key never leaves iCloud Keychain, and nothing on this screen
/// deletes the local portfolio.
struct ICloudScreen: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var restoreConfirmation = false
  @State private var deleteConfirmation = false
  @State private var migrationConfirmation = false
  @State private var resetConfirmation = false
  @State private var rollbackConfirmation = false
  @State private var isResettingConnection = false
  @State private var isFinishingMigration = false

  /// Mirrors the macOS rule for Save, Restore, and Delete.
  private var transferControlsDisabled: Bool {
    state.vaultEditsDisabled || !state.isUnlocked
  }

  private var showsLegacyMigration: Bool {
    state.pendingVaultUpload != nil || state.quarantinedPendingVaultUpload != nil
  }

  private var connectionValue: String {
    state.syncing ? "Working…" : state.iCloudStatus
  }

  var body: some View {
    IOSPage(
      title: "iCloud",
      subtitle:
        "Keep an encrypted copy of your portfolio in your own iCloud account. Transfers happen only when you choose."
    ) {
      statusSurface
      transferSurface
      guidanceCallouts
      maintenanceSurface
      if showsLegacyMigration {
        migrationSurface
      }
    }
    .confirmationDialog(
      "Replace this device’s portfolio with the iCloud copy?",
      isPresented: $restoreConfirmation,
      titleVisibility: .visible
    ) {
      Button("Restore iCloud copy", role: .destructive) {
        Task { await state.restoreFromICloud() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "A local rollback copy will be saved first. Export changes separately if you want to keep both portfolios."
      )
    }
    .confirmationDialog(
      "Delete the Address Atlas copy in your current iCloud account?",
      isPresented: $deleteConfirmation,
      titleVisibility: .visible
    ) {
      Button("Delete iCloud copy", role: .destructive) {
        Task { await state.deleteICloudCopy() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Your local portfolio stays on this device. Other devices keep their local copies too.")
    }
    .confirmationDialog(
      "Stop the old server transfer and keep the local vault?",
      isPresented: $migrationConfirmation,
      titleVisibility: .visible
    ) {
      Button("Keep local vault and migrate") { finishLegacyMigration() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Existing server data is not deleted by this action.")
    }
    .confirmationDialog(
      "Reset this device’s iCloud connection?",
      isPresented: $resetConfirmation,
      titleVisibility: .visible
    ) {
      Button("Reset connection") { resetConnection() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Existing local and cloud copies remain. The next transfer uses the Apple Account currently signed in on this device."
      )
    }
    .confirmationDialog(
      "Restore the previous local portfolio?",
      isPresented: $rollbackConfirmation,
      titleVisibility: .visible
    ) {
      Button("Restore previous local copy", role: .destructive) {
        Task { await state.restoreVaultRollbackCheckpoint() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This replaces the current local portfolio. The iCloud copy is not changed.")
    }
  }

  // MARK: - Sections

  private var statusSurface: some View {
    Surface {
      VStack(alignment: .leading, spacing: 14) {
        PanelHeader(
          title: "Your vault in iCloud",
          subtitle: "No separate account or Address Atlas backup server",
          systemImage: "icloud.fill"
        )
        ICloudScreenStatusRow(label: "Connection", value: connectionValue, emphasized: true)
        if let cloud = state.document.iCloudState {
          Divider().overlay(AtlasTheme.ruleSoft)
          ICloudScreenStatusRow(
            label: "Last completed transfer",
            value: AtlasFormatting.dateTime(cloud.savedAt)
          )
          Divider().overlay(AtlasTheme.ruleSoft)
          ICloudScreenStatusRow(label: "Cloud revision", value: cloud.revision, monospaced: true)
          Divider().overlay(AtlasTheme.ruleSoft)
          ICloudScreenStatusRow(label: "Account ID", value: cloud.account, monospaced: true)
        } else {
          Text(
            "No iCloud copy is linked on this device yet. Save to create one, or restore if another device already saved a copy."
          )
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink2)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var transferSurface: some View {
    Surface {
      VStack(alignment: .leading, spacing: 16) {
        PanelHeader(
          title: "Transfer",
          subtitle: "Save from this device, restore on another",
          systemImage: "arrow.triangle.2.circlepath"
        )
        Text(
          "Save from this device, then restore on another device signed in to the same Apple Account. Turn on iCloud Passwords & Keychain in Settings on both devices so the encryption key can arrive."
        )
        .font(.callout)
        .foregroundStyle(AtlasTheme.ink2)
        .fixedSize(horizontal: false, vertical: true)

        AdaptiveStack(horizontalSpacing: 12, verticalSpacing: 10) {
          Button {
            Task { await state.saveToICloud() }
          } label: {
            ICloudScreenActionLabel(
              idleTitle: "Save to iCloud",
              systemImage: "icloud.and.arrow.up",
              progressTitle: SyncActivity.uploadingVault.progressTitle,
              isActive: state.syncActivity == .uploadingVault
            )
          }
          .buttonStyle(AtlasPrimaryButtonStyle())
          .accessibilityHint(
            "Uploads an encrypted copy of this device’s portfolio to your iCloud account."
          )

          Button {
            restoreConfirmation = true
          } label: {
            ICloudScreenActionLabel(
              idleTitle: "Restore from iCloud",
              systemImage: "icloud.and.arrow.down",
              progressTitle: SyncActivity.downloadingVault.progressTitle,
              isActive: state.syncActivity == .downloadingVault
            )
          }
          .buttonStyle(AtlasSecondaryButtonStyle())
          .accessibilityHint(
            "Asks for confirmation, then replaces this device’s portfolio with the iCloud copy after saving a local rollback copy."
          )
        }
        .disabled(transferControlsDisabled)
        .animation(
          AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
          value: state.syncActivity
        )

        Text(
          "Restoring replaces this device’s portfolio after keeping a local rollback copy. Newer changes from another device are never overwritten silently."
        )
        .font(.footnote)
        .foregroundStyle(AtlasTheme.ink3)
        .fixedSize(horizontal: false, vertical: true)
        Text(
          "Exchange credentials travel encrypted. Kraken connections stay bound to the device that created them, so each device needs its own read-only Kraken API key. iCloud storage counts toward your Apple Account quota."
        )
        .font(.footnote)
        .foregroundStyle(AtlasTheme.ink3)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var guidanceCallouts: some View {
    VStack(alignment: .leading, spacing: 12) {
      InfoCallout(
        title: "Setting up another device? Restore first",
        copy:
          "When an iCloud copy already exists, a device that has not restored it yet cannot save over it: Save stops with a message and nothing is uploaded. Tap Restore from iCloud first. Afterwards the device that saved last holds the newest copy, and the other device restores before it can save again.",
        tone: .info
      )
      InfoCallout(
        title: "The encryption key travels through iCloud Keychain",
        copy:
          "The iCloud copy is encrypted with a key that lives only in iCloud Keychain, never inside the cloud record. Passwords & Keychain must be turned on in Settings on every device that saves or restores. Until the key arrives, Restore stops with a message and this device’s portfolio is left untouched.",
        tone: .info
      )
      InfoCallout(
        title: "Kraken connections stay on the device that created them",
        copy:
          "A Kraken API key is bound to the device that added it. After restoring on another device, remove the Kraken connection there and add a separate read-only key created only for that device. Never reuse one Kraken API key across devices.",
        tone: .warning
      )
    }
  }

  private var maintenanceSurface: some View {
    Surface(style: .subtle) {
      VStack(alignment: .leading, spacing: 14) {
        PanelHeader(
          title: "Remove or reset",
          subtitle: "Your local portfolio is never deleted from here",
          systemImage: "icloud.slash",
          tint: AtlasTheme.loss
        )
        VStack(spacing: 10) {
          Button(role: .destructive) {
            deleteConfirmation = true
          } label: {
            ICloudScreenActionLabel(
              idleTitle: "Delete iCloud copy…",
              systemImage: "trash",
              progressTitle: "Deleting iCloud copy",
              isActive: state.syncActivity == .deletingAccount,
              tint: AtlasTheme.loss
            )
          }
          .buttonStyle(AtlasSecondaryButtonStyle())
          .disabled(transferControlsDisabled)
          .accessibilityHint(
            "Asks for confirmation, then removes the copy from your current iCloud account. The local portfolio stays."
          )

          if state.document.iCloudState != nil {
            Button {
              resetConfirmation = true
            } label: {
              ICloudScreenActionLabel(
                idleTitle: "Reset iCloud connection…",
                systemImage: "arrow.counterclockwise",
                progressTitle: "Resetting iCloud connection",
                isActive: isResettingConnection
              )
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            .disabled(state.vaultEditsDisabled)
            .accessibilityHint(
              "Asks for confirmation, then forgets this device’s link to the iCloud copy. Local and cloud copies stay."
            )
          }

          if state.hasVaultRollbackCheckpoint {
            Button {
              rollbackConfirmation = true
            } label: {
              ICloudScreenActionLabel(
                idleTitle: "Restore previous local copy",
                systemImage: "clock.arrow.circlepath",
                progressTitle: SyncActivity.restoringRollbackCheckpoint.progressTitle,
                isActive: state.syncActivity == .restoringRollbackCheckpoint
              )
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            .disabled(state.vaultEditsDisabled)
            .accessibilityHint(
              "Asks for confirmation, then replaces the current local portfolio with the rollback copy saved before the last restore."
            )
          }
        }
        .animation(
          AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
          value: state.syncActivity
        )
      }
    }
  }

  private var migrationSurface: some View {
    Surface(style: .warning) {
      VStack(alignment: .leading, spacing: 14) {
        InfoCallout(
          title: "Interrupted transfer from the retired server version",
          copy:
            "An interrupted transfer from the retired server version is saved locally. Finish migration to keep this vault and stop that transfer. Existing server data is not deleted by this action.",
          tone: .warning
        )
        Button {
          migrationConfirmation = true
        } label: {
          ICloudScreenActionLabel(
            idleTitle: "Finish local migration…",
            systemImage: "checkmark.seal",
            progressTitle: "Finishing local migration",
            isActive: isFinishingMigration
          )
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        .disabled(state.syncing || state.scanning || state.isPersisting)
        .accessibilityHint("Asks for confirmation, then keeps the local vault and stops the old transfer.")
      }
    }
  }

  // MARK: - Actions without a shared activity flag

  private func resetConnection() {
    Task { @MainActor in
      isResettingConnection = true
      defer { isResettingConnection = false }
      await state.resetICloudConnection()
    }
  }

  private func finishLegacyMigration() {
    Task { @MainActor in
      isFinishingMigration = true
      defer { isFinishingMigration = false }
      await state.finishLegacySyncMigration()
    }
  }
}

// MARK: - Components

/// Two-column status row that keeps opaque identifiers on one line.
private struct ICloudScreenStatusRow: View {
  var label: String
  var value: String
  var emphasized = false
  var monospaced = false

  private var valueFont: Font {
    if monospaced { return .caption.monospaced() }
    return emphasized ? .callout.weight(.semibold) : .callout
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .font(.callout.weight(.medium))
        .foregroundStyle(AtlasTheme.ink3)
      Spacer(minLength: 8)
      Text(value)
        .font(valueFont)
        .foregroundStyle(emphasized ? AtlasTheme.ink : AtlasTheme.ink2)
        .multilineTextAlignment(.trailing)
        .lineLimit(monospaced ? 1 : nil)
        .truncationMode(.middle)
    }
    .frame(minHeight: 28)
    .accessibilityElement(children: .combine)
  }
}

/// Button label that swaps to a progress indicator while the matching
/// activity runs, so the progress sits on the control that started the work.
private struct ICloudScreenActionLabel: View {
  var idleTitle: String
  var systemImage: String
  var progressTitle: String
  var isActive: Bool
  var tint: Color? = nil

  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    if let tint, isEnabled, !isActive {
      content.foregroundStyle(tint)
    } else {
      content
    }
  }

  @ViewBuilder
  private var content: some View {
    Group {
      if isActive {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(progressTitle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(progressTitle), in progress")
      } else {
        Label(idleTitle, systemImage: systemImage)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 44)
  }
}
