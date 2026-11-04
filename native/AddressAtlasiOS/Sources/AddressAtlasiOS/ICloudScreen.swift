import AddressAtlasCore
import CloudKit
import SwiftUI
import UIKit

/// iOS port of the macOS `SyncView`, pushed from Settings: a status card, two
/// transfer actions, a collapsed explanation and a quiet management section.
/// Transfers happen only on request, the encryption key never leaves iCloud
/// Keychain, and nothing on this screen deletes the local portfolio.
struct ICloudScreen: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var restoreConfirmation = false
  @State private var deleteConfirmation = false
  @State private var migrationConfirmation = false
  @State private var resetConfirmation = false
  @State private var rollbackConfirmation = false
  @State private var isResettingConnection = false
  @State private var isFinishingMigration = false
  @State private var availability: ICloudAvailability = .checking
  /// The iCloud failure behind a "Needs attention" status, captured from the
  /// shared error so the status card can say what to do next after the toast
  /// is dismissed.
  @State private var attentionIssue: ICloudAttentionIssue?

  /// The last transfer failed (`AppState.iCloudStatusKind`).
  private var needsAttention: Bool { state.iCloudStatusKind == .needsAttention }

  /// Mirrors the macOS rule for Save, Restore, and Delete, and also stays off
  /// while iCloud is known to be unusable (the service would refuse anyway).
  private var transferControlsDisabled: Bool {
    state.vaultEditsDisabled || !state.isUnlocked || availability.blocksTransfers
  }

  private var showsLegacyMigration: Bool {
    state.pendingVaultUpload != nil || state.quarantinedPendingVaultUpload != nil
  }

  private var hasKrakenConnection: Bool {
    state.document.exchangeConnections.contains { $0.provider == .kraken }
  }

  /// A save that reached iCloud but could not be recorded on this device.
  private var savedButNotRecorded: Bool { state.iCloudStatusKind == .savedNotRecorded }

  var body: some View {
    IOSPage(title: "iCloud") {
      statusCard
      actionsCard
      if hasKrakenConnection {
        IOSNotice(
          systemImage: "exclamationmark.triangle.fill",
          text:
            "Kraken keys stay on this device. After restoring elsewhere, add a separate read-only Kraken key there."
        )
      }
      if showsLegacyMigration {
        migrationSurface
      }
      learnMore
      manageSection
    }
    .animation(
      AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
      value: state.syncActivity
    )
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
      await refreshAvailability()
    }
    .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
      Task { await refreshAvailability() }
    }
    .onChange(of: state.error) { _, error in
      captureAttentionIssue(error)
    }
    .onChange(of: state.iCloudStatusKind) { _, status in
      if status == .needsAttention {
        captureAttentionIssue(state.error)
      } else {
        attentionIssue = nil
      }
    }
    .confirmationDialog(
      "Stop the old server transfer and keep the local vault?",
      isPresented: $migrationConfirmation,
      titleVisibility: .visible
    ) {
      Button("Finish migration") { finishLegacyMigration() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Server data is not deleted.")
    }
  }

  // MARK: - Status

  private var status: ICloudStatusPresentation {
    if let activity = state.syncActivity {
      return ICloudStatusPresentation(
        systemImage: "icloud",
        tone: .accent,
        title: ICloudStatusPresentation.progressTitle(for: activity),
        detail: "Keep the app open until this finishes.",
        isWorking: true
      )
    }
    if isFinishingMigration || isResettingConnection {
      return ICloudStatusPresentation(
        systemImage: "icloud",
        tone: .accent,
        title: "Working…",
        detail: "Keep the app open until this finishes.",
        isWorking: true
      )
    }
    if let unavailable = availability.presentation {
      return unavailable
    }
    if needsAttention {
      return (attentionIssue ?? .generic).presentation
    }
    if savedButNotRecorded {
      return ICloudStatusPresentation(
        systemImage: "exclamationmark.icloud.fill",
        tone: .warning,
        title: "Saved, but not recorded here",
        detail: "This device couldn’t record the save. Save again to confirm it."
      )
    }
    if let cloud = state.document.iCloudState {
      return ICloudStatusPresentation(
        systemImage: "checkmark.icloud.fill",
        tone: .success,
        title: "Linked to iCloud",
        detail: "Last saved \(AtlasFormatting.dateTime(cloud.savedAt))"
      )
    }
    return ICloudStatusPresentation(
      systemImage: "icloud",
      tone: .neutral,
      title: "Not connected",
      detail: "Save a copy, or restore one saved on another device."
    )
  }

  private var statusCard: some View {
    let status = status
    return IOSCard(fill: status.tone == .warning ? AtlasTheme.warningSoft : nil) {
      VStack(alignment: .leading, spacing: 14) {
        iCloudAdaptiveLayout(dynamicTypeSize, spacing: 14).callAsFunction {
          ZStack {
            if status.isWorking {
              ProgressView()
                .controlSize(.regular)
            } else {
              Image(systemName: status.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(status.tone.ink)
            }
          }
          .iCloudTile(fill: status.tone == .warning ? AtlasTheme.surface : status.tone.softFill, size: 48)
          .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
          .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            Text(status.title)
              .font(AtlasTheme.font(.display, .headline))
              .foregroundStyle(AtlasTheme.ink)
            Text(status.detail)
              .font(AtlasTheme.font(.body, .callout))
              .foregroundStyle(AtlasTheme.ink2)
          }
          .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("iCloud status: \(status.title). \(status.detail)")
        .accessibilityIdentifier("icloud.status")

        if status.opensSettings {
          Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
              UIApplication.shared.open(url)
            }
          } label: {
            Label("Open Settings", systemImage: "gear")
              .frame(maxWidth: .infinity, minHeight: 44)
          }
          .buttonStyle(AtlasSecondaryButtonStyle())
          .accessibilityHint("Opens the Settings app.")
          .accessibilityIdentifier("icloud.openSettings")
        }

        if let cloud = state.document.iCloudState, !status.isWorking {
          ICloudRule()
          VStack(spacing: 6) {
            ICloudScreenStatusRow(label: "Cloud revision", value: cloud.revision)
            ICloudScreenStatusRow(label: "Account ID", value: cloud.account)
          }
        }
      }
    }
  }

  // MARK: - Actions

  private var actionsCard: some View {
    IOSCard(padding: 0) {
      VStack(spacing: 0) {
        Button {
          Task { await state.saveToICloud() }
        } label: {
          ICloudActionRow(
            title: "Save to iCloud",
            detail: "Uploads an encrypted copy of this portfolio.",
            systemImage: "icloud.and.arrow.up",
            isProminent: true,
            isActive: state.syncActivity == .uploadingVault
          )
        }
        .accessibilityHint(
          "Uploads an encrypted copy of this device’s portfolio to your iCloud account."
        )
        .accessibilityIdentifier("icloud.save")

        ICloudRule(inset: 66)

        Button {
          restoreConfirmation = true
        } label: {
          ICloudActionRow(
            title: "Restore from iCloud",
            detail: "Replaces this portfolio. A rollback copy is kept.",
            systemImage: "icloud.and.arrow.down",
            isActive: state.syncActivity == .downloadingVault
          )
        }
        .accessibilityHint(
          "Asks for confirmation, then replaces this device’s portfolio with the iCloud copy after saving a local rollback copy."
        )
        .accessibilityIdentifier("icloud.restore")
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
            "A local rollback copy is saved first. Export this portfolio first if you want to keep both."
          )
        }
      }
      .buttonStyle(ICloudRowButtonStyle())
      .disabled(transferControlsDisabled)
    }
  }

  private var learnMore: some View {
    LearnMoreDisclosure("How iCloud copies work", systemImage: "questionmark.circle") {
      IOSFactRow(
        systemImage: "lock.icloud",
        title: "Key in iCloud Keychain",
        copy:
          "The key lives in iCloud Keychain, never in the cloud record. No Address Atlas server is involved."
      )
      IOSFactRow(
        systemImage: "key",
        title: "Turn on Passwords & Keychain",
        copy:
          "Needed in Settings on every device that saves or restores. Until the key arrives, Restore stops and changes nothing."
      )
      IOSFactRow(
        systemImage: "iphone.and.arrow.forward",
        title: "New device? Restore first",
        copy:
          "A device that hasn’t restored the existing copy can’t save over it. The device that saved last holds the newest copy."
      )
      IOSFactRow(
        systemImage: "checkmark.shield",
        title: "Never overwritten silently",
        copy:
          "Restore keeps a local rollback copy. Newer changes from another device stop a save until you restore them."
      )
      if !hasKrakenConnection {
        IOSFactRow(
          systemImage: "building.columns",
          title: "Kraken keys stay on one device",
          copy:
            "Exchange keys travel encrypted, but each device needs its own read-only Kraken key. Never reuse one key across devices."
        )
      }
      IOSFactRow(
        systemImage: "internaldrive",
        title: "Uses your iCloud storage",
        copy: "The copy counts toward your Apple Account quota. Transfers happen only when you tap."
      )
    }
  }

  // MARK: - Manage

  private var manageSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      IOSSectionTitle("Manage")
      IOSCard(padding: 0) {
        VStack(spacing: 0) {
          if state.hasVaultRollbackCheckpoint {
            Button {
              rollbackConfirmation = true
            } label: {
              ICloudManageRow(
                title: "Restore previous copy",
                systemImage: "clock.arrow.circlepath",
                tint: AtlasTheme.accent,
                progressTitle: "Restoring previous copy",
                isActive: state.syncActivity == .restoringRollbackCheckpoint
              )
            }
            .disabled(state.vaultEditsDisabled)
            .accessibilityHint(
              "Asks for confirmation, then replaces the current local portfolio with the rollback copy saved before the last restore."
            )
            .confirmationDialog(
              "Restore the previous local portfolio?",
              isPresented: $rollbackConfirmation,
              titleVisibility: .visible
            ) {
              Button("Restore previous copy", role: .destructive) {
                Task { await state.restoreVaultRollbackCheckpoint() }
              }
              Button("Cancel", role: .cancel) {}
            } message: {
              Text("This replaces the current local portfolio. The iCloud copy is not changed.")
            }
            ICloudRule(inset: 52)
          }

          if state.document.iCloudState != nil {
            Button {
              resetConfirmation = true
            } label: {
              ICloudManageRow(
                title: "Reset connection…",
                systemImage: "arrow.counterclockwise",
                tint: AtlasTheme.accent,
                progressTitle: "Resetting connection",
                isActive: isResettingConnection
              )
            }
            .disabled(state.vaultEditsDisabled)
            .accessibilityHint(
              "Asks for confirmation, then forgets this device’s link to the iCloud copy. Local and cloud copies stay."
            )
            .confirmationDialog(
              "Reset this device’s iCloud connection?",
              isPresented: $resetConfirmation,
              titleVisibility: .visible
            ) {
              Button("Reset connection") { resetConnection() }
              Button("Cancel", role: .cancel) {}
            } message: {
              Text(
                "Local and cloud copies stay. The next transfer uses the Apple Account signed in on this device."
              )
            }
            ICloudRule(inset: 52)
          }

          Button(role: .destructive) {
            deleteConfirmation = true
          } label: {
            ICloudManageRow(
              title: "Delete iCloud copy…",
              systemImage: "trash",
              tint: AtlasTheme.loss,
              progressTitle: "Deleting iCloud copy",
              isActive: state.syncActivity == .deletingAccount
            )
          }
          .disabled(transferControlsDisabled)
          .accessibilityHint(
            "Asks for confirmation, then removes the copy from your current iCloud account. The local portfolio stays."
          )
          .accessibilityIdentifier("icloud.delete")
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
            Text(
              "Your local portfolio stays on this device. Other devices keep their local copies too.")
          }
        }
        .buttonStyle(ICloudRowButtonStyle())
      }
      Text("Nothing here deletes the portfolio on this device.")
        .font(AtlasTheme.font(.body, .footnote))
        .foregroundStyle(AtlasTheme.ink3)
        .padding(.horizontal, 4)
        // The hard-edged themes draw an offset shadow under the card.
        .padding(.top, AtlasTheme.shape.cardShadowOffset?.height ?? 0)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var migrationSurface: some View {
    Surface(padding: 16, style: .warning) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(AtlasTheme.warning)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text("A transfer from the old server did not finish")
              .font(AtlasTheme.font(.body, .callout, weight: .semibold))
              .foregroundStyle(AtlasTheme.ink)
            Text("Finish migration to keep this vault and stop the transfer. Server data is not deleted.")
              .font(AtlasTheme.font(.body, .footnote))
              .foregroundStyle(AtlasTheme.ink2)
          }
          .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        Button {
          migrationConfirmation = true
        } label: {
          Group {
            if isFinishingMigration {
              HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finishing migration")
              }
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("Finishing migration, in progress")
            } else {
              Label("Finish migration…", systemImage: "checkmark.seal")
            }
          }
          .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        .disabled(state.syncing || state.scanning || state.isPersisting)
        .accessibilityHint(
          "Asks for confirmation, then keeps the local vault and stops the old transfer.")
      }
    }
  }

  // MARK: - Availability and issues

  /// Reads the iCloud account status without transferring anything. CloudKit
  /// is only touched when this build carries the iCloud container entitlement,
  /// the same guard the transfer service uses.
  private func refreshAvailability() async {
    guard ICloudVaultService.isConfigured else {
      availability = .notConfigured
      return
    }
    do {
      let status = try await CKContainer(identifier: ICloudVaultService.containerIdentifier)
        .accountStatus()
      availability = ICloudAvailability(status)
    } catch {
      availability = .unknown
    }
  }

  private func captureAttentionIssue(_ error: String) {
    guard needsAttention, !error.isEmpty else { return }
    attentionIssue = ICloudAttentionIssue(message: error)
    if attentionIssue == .unavailable {
      Task { await refreshAvailability() }
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

// MARK: - Status model

/// Which theme colours a status or an icon tile takes.
private enum ICloudTone: Equatable {
  case accent
  case neutral
  case success
  case warning

  var ink: Color {
    switch self {
    case .accent: AtlasTheme.accent
    case .neutral: AtlasTheme.ink2
    case .success: AtlasTheme.gain
    case .warning: AtlasTheme.warning
    }
  }

  var softFill: Color {
    switch self {
    case .accent: AtlasTheme.accentSoft
    case .neutral: AtlasTheme.surfaceMuted
    case .success: AtlasTheme.gainSoft
    case .warning: AtlasTheme.warningSoft
    }
  }
}

private struct ICloudStatusPresentation {
  var systemImage: String
  var tone: ICloudTone
  var title: String
  var detail: String
  var isWorking = false
  /// Shows an "Open Settings" button when the fix is in the Settings app.
  var opensSettings = false

  static func progressTitle(for activity: SyncActivity) -> String {
    switch activity {
    case .uploadingVault: "Saving to iCloud…"
    case .downloadingVault: "Restoring from iCloud…"
    case .deletingAccount: "Deleting iCloud copy…"
    case .restoringRollbackCheckpoint: "Restoring previous copy…"
    default: activity.progressTitle
    }
  }
}

/// What the account check found. Only states that make every transfer fail
/// disable the controls; transient or unknown states leave them enabled so
/// the service can report the real outcome.
private enum ICloudAvailability: Equatable {
  case checking
  case available
  case notConfigured
  case noAccount
  case restricted
  case temporarilyUnavailable
  case unknown

  init(_ status: CKAccountStatus) {
    switch status {
    case .available: self = .available
    case .noAccount: self = .noAccount
    case .restricted: self = .restricted
    case .temporarilyUnavailable: self = .temporarilyUnavailable
    default: self = .unknown
    }
  }

  var blocksTransfers: Bool {
    switch self {
    case .notConfigured, .noAccount, .restricted: true
    case .checking, .available, .temporarilyUnavailable, .unknown: false
    }
  }

  var presentation: ICloudStatusPresentation? {
    switch self {
    case .notConfigured:
      ICloudStatusPresentation(
        systemImage: "icloud.slash",
        tone: .neutral,
        title: "iCloud isn’t available in this build",
        detail: "Use the App Store or TestFlight version of Address Atlas."
      )
    case .noAccount:
      ICloudStatusPresentation(
        systemImage: "person.crop.circle.badge.exclamationmark",
        tone: .warning,
        title: "Sign in to iCloud",
        detail: "Sign in with your Apple Account in Settings, then come back.",
        opensSettings: true
      )
    case .restricted:
      ICloudStatusPresentation(
        systemImage: "icloud.slash",
        tone: .warning,
        title: "iCloud is restricted",
        detail: "Screen Time or a device profile blocks iCloud on this device."
      )
    case .temporarilyUnavailable:
      ICloudStatusPresentation(
        systemImage: "exclamationmark.icloud",
        tone: .warning,
        title: "iCloud is temporarily unavailable",
        detail: "Check Apple Account › iCloud in Settings, then try again.",
        opensSettings: true
      )
    case .checking, .available, .unknown:
      nil
    }
  }
}

/// Short, actionable card copy for the iCloud failure behind "Needs
/// attention". The full message from the shared state still appears in the
/// status toast.
private enum ICloudAttentionIssue: Equatable {
  case unavailable, accountChanged, conflict, missing, missingKey, malformed, keychain, generic

  /// Matches the message AppState put in `error` against
  /// `ICloudVaultError.errorDescription`. Both sides come from the same enum,
  /// so rewording a message there keeps this working; it only relies on
  /// `presentICloudError` still passing that description through unchanged.
  init(message: String) {
    let known: [(ICloudVaultError, ICloudAttentionIssue)] = [
      (.unavailable, .unavailable), (.accountChanged, .accountChanged),
      (.conflict, .conflict), (.missing, .missing), (.missingKey, .missingKey),
      (.malformed, .malformed), (.keychain, .keychain),
    ]
    self = known.first { $0.0.errorDescription == message }?.1 ?? .generic
  }

  var presentation: ICloudStatusPresentation {
    let icon = "exclamationmark.icloud.fill"
    return switch self {
    case .unavailable:
      ICloudStatusPresentation(
        systemImage: "person.crop.circle.badge.exclamationmark", tone: .warning,
        title: "Sign in to iCloud",
        detail: "Sign in with your Apple Account in Settings, then try again.",
        opensSettings: true)
    case .accountChanged:
      ICloudStatusPresentation(
        systemImage: icon, tone: .warning, title: "Different Apple Account",
        detail: "Nothing was replaced. Switch back, or reset the connection below.")
    case .conflict:
      ICloudStatusPresentation(
        systemImage: icon, tone: .warning, title: "Newer copy in iCloud",
        detail: "Another device saved since. Restore first, then save again.")
    case .missing:
      ICloudStatusPresentation(
        systemImage: "icloud.slash", tone: .warning, title: "No iCloud copy yet",
        detail: "Save from the device that has your portfolio first.")
    case .missingKey:
      ICloudStatusPresentation(
        systemImage: "key.icloud", tone: .warning, title: "Waiting for the encryption key",
        detail: "Turn on Passwords & Keychain on both devices, then try again.",
        opensSettings: true)
    case .malformed:
      ICloudStatusPresentation(
        systemImage: icon, tone: .warning, title: "iCloud copy couldn’t be verified",
        detail: "Your local portfolio wasn’t replaced.")
    case .keychain:
      ICloudStatusPresentation(
        systemImage: "key.icloud", tone: .warning, title: "Keychain couldn’t be read",
        detail: "Unlock this device and try again.")
    case .generic:
      ICloudStatusPresentation(
        systemImage: icon, tone: .warning, title: "Last transfer didn’t finish",
        detail: "Check your connection and iCloud storage, then try again.")
    }
  }
}

// MARK: - Components

/// Opaque identifiers on one line, truncated in the middle.
private struct ICloudScreenStatusRow: View {
  var label: String
  var value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .font(AtlasTheme.font(.body, .footnote))
        .foregroundStyle(AtlasTheme.ink3)
      Spacer(minLength: 8)
      Text(value)
        .font(AtlasTheme.font(.mono, .caption))
        .foregroundStyle(AtlasTheme.ink2)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .accessibilityElement(children: .combine)
  }
}

/// Primary transfer action: icon tile, title, one line of what happens, and
/// a progress indicator in place of the icon while the matching transfer runs.
private struct ICloudActionRow: View {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var title: String
  var detail: String
  var systemImage: String
  var isProminent = false
  var isActive: Bool

  private var tileFill: Color {
    guard isEnabled else { return AtlasTheme.surfaceMuted }
    return isProminent ? AtlasTheme.accent : AtlasTheme.accentSoft
  }

  private var glyphInk: Color {
    guard isEnabled else { return AtlasTheme.ink3 }
    return isProminent ? AtlasTheme.onAccent : AtlasTheme.accent
  }

  var body: some View {
    iCloudAdaptiveLayout(dynamicTypeSize, spacing: 14).callAsFunction {
      ZStack {
        if isActive {
          ProgressView()
            .controlSize(.small)
            .tint(glyphInk)
        } else {
          Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(glyphInk)
        }
      }
      .iCloudTile(fill: tileFill, size: 38)
      .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(AtlasTheme.font(.body, .body, weight: .semibold))
          .foregroundStyle(isEnabled ? AtlasTheme.ink : AtlasTheme.ink3)
        Text(detail)
          .font(AtlasTheme.font(.body, .footnote))
          .foregroundStyle(AtlasTheme.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(minHeight: 64)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(isActive ? "\(title), in progress" : title)
    .accessibilityValue(detail)
  }
}

/// Quiet management row; destructive rows are tinted red.
private struct ICloudManageRow: View {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var title: String
  var systemImage: String
  var tint: Color
  var progressTitle: String
  var isActive: Bool

  var body: some View {
    HStack(spacing: 12) {
      if isActive {
        ProgressView()
          .controlSize(.small)
          .frame(width: 26)
          .accessibilityHidden(true)
      } else if !dynamicTypeSize.isAccessibilitySize {
        Image(systemName: systemImage)
          .font(.body.weight(.medium))
          .frame(width: 26)
          .accessibilityHidden(true)
      }
      Text(isActive ? progressTitle : title)
        .font(AtlasTheme.font(.body, .body))
      Spacer(minLength: 0)
    }
    .foregroundStyle(isEnabled ? tint : AtlasTheme.ink3)
    .padding(.horizontal, 14)
    .frame(minHeight: 50)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(isActive ? "\(progressTitle), in progress" : title)
  }
}

/// The rule between rows: the theme's ink in the hard-edged themes, a soft
/// hairline in the others. `inset` is where the row's text starts.
private struct ICloudRule: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var inset: CGFloat?

  var body: some View {
    let bold = AtlasTheme.shape.hasBoldBorders
    Rectangle()
      .fill(bold ? AtlasTheme.outline : AtlasTheme.ruleSoft)
      .frame(height: bold ? 1.5 : 1)
      .padding(.leading, inset.map { dynamicTypeSize.isAccessibilitySize ? 14 : $0 } ?? 0)
      .accessibilityHidden(true)
  }
}

/// Icon beside text normally; icon above text at accessibility sizes so the
/// text gets the full row width.
private func iCloudAdaptiveLayout(_ size: DynamicTypeSize, spacing: CGFloat) -> AnyLayout {
  size.isAccessibilitySize
    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
    : AnyLayout(HStackLayout(alignment: .center, spacing: spacing))
}

private struct ICloudRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(configuration.isPressed ? AtlasTheme.accentSoft : Color.clear)
  }
}

extension View {
  /// A square icon tile in the theme's own shape (a circle in the pill
  /// themes, a rounded or sharp square in the others), outlined where the
  /// theme outlines its controls.
  fileprivate func iCloudTile(fill: Color, size: CGFloat) -> some View {
    modifier(ICloudTileStyle(fill: fill, size: size))
  }
}

private struct ICloudTileStyle: ViewModifier {
  var fill: Color
  var size: CGFloat

  func body(content: Content) -> some View {
    let shape = AtlasTheme.shape
    let outline: AnyShape =
      shape.pillControls
      ? AnyShape(Circle())
      : AnyShape(
        RoundedRectangle(cornerRadius: min(shape.radiusSmall, size * 0.3), style: .continuous))
    content
      .frame(width: size, height: size)
      .background(outline.fill(fill))
      .overlay {
        if shape.hasBoldBorders {
          outline.stroke(AtlasTheme.outline, lineWidth: 1.5)
        }
      }
  }
}
