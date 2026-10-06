import AddressAtlasCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The locked-vault screen: retry unlock, recover a damaged local vault,
/// restore Keychain access from a recovery kit, and share privacy-safe
/// diagnostics. `RootView` already calls `state.unlock()` on appear, so the
/// first attempt shows a calm launch splash; the recovery page only appears
/// when that attempt did not open the vault, and its unlock button is the
/// retry path.
///
/// Keeps the macOS `UnlockView` confirmations and safety rules; the copy is
/// shortened for a phone and diagnostics sit behind a disclosure.
struct UnlockScreen: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @State private var restoreCode = ""
  @State private var revealsRestoreCode = false
  @State private var confirmsDamagedVaultQuarantine = false
  @State private var showsRecoveryFileImporter = false
  @State private var firstAttemptFinished = false

  private var trimmedRestoreCode: String {
    restoreCode.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The splash covers the automatic unlock at launch. Any error, a damaged
  /// vault, or a finished attempt switches to the recovery page.
  private var showsSplash: Bool {
    !firstAttemptFinished && state.error.isEmpty
      && state.damagedVaultRecoveryAvailability == nil
  }

  var body: some View {
    NavigationStack {
      Group {
        if showsSplash {
          UnlockSplash()
            .transition(.opacity)
        } else {
          lockedPage
            .transition(.opacity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(AtlasTheme.canvas.ignoresSafeArea())
      .toolbar(.hidden, for: .navigationBar)
      .atlasKeyboardDoneButton()
      .animation(
        AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
        value: showsSplash
      )
      .animation(
        AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
        value: state.damagedVaultRecoveryAvailability
      )
      .onChange(of: state.isUnlocking) { wasUnlocking, isUnlocking in
        if wasUnlocking && !isUnlocking { firstAttemptFinished = true }
      }
      .task {
        // If the automatic attempt never started (for example, it was not
        // admitted), stop waiting and show the actions.
        try? await Task.sleep(for: .seconds(2))
        if !state.isUnlocking { firstAttemptFinished = true }
      }
      .confirmationDialog(
        "Preserve damaged vault and start clean?",
        isPresented: $confirmsDamagedVaultQuarantine,
        titleVisibility: .visible
      ) {
        Button("Preserve in quarantine and start clean", role: .destructive) {
          Task { await state.quarantineDamagedVaultAndStartClean() }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "A crash-durable private copy of vault.sqlite and every SQLite sidecar is verified first. Only then does an empty local vault open with the same Keychain key. Nothing is downloaded."
        )
      }
      .fileImporter(
        isPresented: $showsRecoveryFileImporter,
        // Only recovery kits (.atlas-recovery), as on macOS.
        allowedContentTypes: [AppState.recoveryKitContentType]
      ) { result in
        handleRecoveryFileSelection(result)
      }
      .onChange(of: scenePhase) { _, phase in
        if phase != .active { revealsRestoreCode = false }
      }
    }
  }

  // MARK: - Locked page

  private var lockedPage: some View {
    ScrollView {
      VStack(spacing: 24) {
        IOSPersistentStatus()
        header
        unlockButton

        if let recovery = state.damagedVaultRecoveryAvailability {
          damagedVaultCard(recovery)
            .transition(.opacity)
        }

        recoveryCard

        LearnMoreDisclosure("Privacy-safe diagnostics", systemImage: "stethoscope") {
          diagnosticsControls
        }

        UnlockTrustFooter()
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 32)
      .frame(maxWidth: 520)
      .frame(maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively)
  }

  private var header: some View {
    VStack(spacing: 14) {
      UnlockBrandTile(size: 72)
      Text("Vault locked")
        .font(.system(.largeTitle, design: .rounded).weight(.bold))
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
      Text(
        state.error.isEmpty
          ? "Your portfolio is encrypted with a key kept in this \(PlatformCopy.deviceNoun)'s Keychain."
          : "The vault didn't open. Try again, or restore with your recovery kit."
      )
      .font(.callout)
      .foregroundStyle(AtlasTheme.ink2)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var unlockButton: some View {
    Button {
      Task { await state.unlock() }
    } label: {
      Group {
        if state.isUnlocking {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
              .tint(AtlasTheme.paper)
            Text("Unlocking…")
          }
        } else {
          Label("Unlock vault", systemImage: "lock.open.fill")
        }
      }
      .font(.body.weight(.semibold))
      .frame(maxWidth: .infinity, minHeight: 50)
      .contentShape(Rectangle())
    }
    .buttonStyle(AtlasPrimaryButtonStyle())
    .disabled(state.isUnlocking)
    .accessibilityHint("Opens the encrypted vault with the key stored in this device's Keychain.")
    .accessibilityIdentifier("unlock-button")
  }

  // MARK: - Damaged vault

  @ViewBuilder
  private func damagedVaultCard(_ recovery: DamagedVaultRecoveryAvailability) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      UnlockCardHeader(
        title: "Local vault needs attention",
        subtitle: recovery == .validatedRollbackCheckpoint
          ? "A verified encrypted restore point is available."
          : "Preserve the damaged vault, then start clean.",
        systemImage: "exclamationmark.shield.fill",
        tint: AtlasTheme.warning
      )
      if recovery == .validatedRollbackCheckpoint {
        Button {
          Task { await state.recoverDamagedVaultFromRollbackCheckpoint() }
        } label: {
          Text("Restore the earlier copy")
            .modifier(UnlockScreenFullWidthLabel())
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        .disabled(state.isUnlocking)
        .accessibilityHint(
          "Replaces the damaged vault with the verified encrypted restore point. Nothing is downloaded."
        )
      }
      Button(role: .destructive) {
        confirmsDamagedVaultQuarantine = true
      } label: {
        Text("Preserve damaged vault and start clean")
          .modifier(UnlockScreenFullWidthLabel())
      }
      .buttonStyle(AtlasSecondaryButtonStyle())
      .disabled(state.isUnlocking)
      .accessibilityHint("Asks for confirmation before quarantining the damaged vault.")
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AtlasTheme.warning.opacity(0.09))
    .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.large, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AtlasRadius.large, style: .continuous)
        .stroke(AtlasTheme.warning.opacity(0.3), lineWidth: 1)
    }
  }

  // MARK: - Recovery kit

  private var recoveryCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      UnlockCardHeader(
        title: "Restore with a recovery kit",
        subtitle: "Your recovery file plus its separate code.",
        systemImage: "key.fill",
        tint: AtlasTheme.accent
      )
      HStack(spacing: 8) {
        Group {
          if revealsRestoreCode {
            TextField("Recovery code", text: $restoreCode)
          } else {
            SecureField("Recovery code", text: $restoreCode)
          }
        }
        .textFieldStyle(AtlasTextFieldStyle())
        .atlasIdentifierInput()
        .submitLabel(.done)
        .accessibilityLabel("Recovery code")
        .accessibilityHint("Enter the code you stored separately from the recovery file.")
        Button {
          revealsRestoreCode.toggle()
        } label: {
          Image(systemName: revealsRestoreCode ? "eye.slash" : "eye")
            .font(.callout)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(AtlasTheme.ink3)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(revealsRestoreCode ? "Hide recovery code" : "Show recovery code")
      }
      Button {
        showsRecoveryFileImporter = true
      } label: {
        Label("Choose recovery file", systemImage: "doc.badge.arrow.up")
          .modifier(UnlockScreenFullWidthLabel())
      }
      .buttonStyle(AtlasSecondaryButtonStyle())
      .disabled(state.isUnlocking || trimmedRestoreCode.isEmpty)
      .accessibilityHint(
        "Opens the Files picker. The recovery file is verified before anything in Keychain is changed."
      )
      Text("Nothing changes unless the kit opens the portfolio on this device.")
        .font(.caption)
        .foregroundStyle(AtlasTheme.ink3)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AtlasTheme.surface)
    .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.large, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AtlasRadius.large, style: .continuous)
        .stroke(AtlasTheme.ruleSoft, lineWidth: 1)
    }
  }

  private func handleRecoveryFileSelection(_ result: Result<URL, any Error>) {
    switch result {
    case .success(let url):
      let recoveryCode = restoreCode
      let isAccessing = url.startAccessingSecurityScopedResource()
      Task {
        defer {
          if isAccessing {
            url.stopAccessingSecurityScopedResource()
          }
        }
        await state.restoreRecoveryKit(from: url, recoveryCode: recoveryCode)
        guard state.error.isEmpty, state.notice.hasPrefix("Recovery kit restored") else {
          return
        }
        restoreCode = ""
        revealsRestoreCode = false
        // Say what came back: the key, which opens the portfolio stored on
        // this device. Follow-up notices (upload recovery) are kept.
        if state.notice == "Recovery kit restored." {
          state.notice = "Encryption key restored. Your portfolio on this device is open again."
        }
      }
    case .failure:
      state.notice = ""
      state.error = "The recovery file could not be opened. Nothing in Keychain was changed."
    }
  }

  // MARK: - Privacy-safe diagnostics

  private var diagnosticsControls: some View {
    let report = state.privacySafeDiagnosticsReport()
    return VStack(alignment: .leading, spacing: 10) {
      Text(
        "App versions, state flags, and failure codes only. No addresses, labels, amounts, credentials, URLs, or file paths."
      )
      .fixedSize(horizontal: false, vertical: true)
      AdaptiveStack(horizontalSpacing: 10, verticalSpacing: 10) {
        Button {
          copyDiagnostics(report)
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
            .modifier(UnlockScreenFullWidthLabel())
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        .accessibilityLabel("Copy diagnostics")
        .accessibilityHint(
          "Copies a bounded technical report that excludes portfolio content and identifiers."
        )
        ShareLink(
          item: report,
          subject: Text("Address Atlas privacy-safe diagnostics"),
          preview: SharePreview("Privacy-safe diagnostics")
        ) {
          Label("Share", systemImage: "square.and.arrow.up")
            .modifier(UnlockScreenFullWidthLabel())
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        .accessibilityLabel("Share diagnostics")
        .accessibilityHint(
          "Shares the same bounded technical report through the share sheet. It excludes portfolio content and identifiers."
        )
      }
    }
  }

  private func copyDiagnostics(_ report: String) {
    let pasteboard = UIPasteboard.general
    pasteboard.string = report
    if pasteboard.hasStrings {
      state.notice = "Privacy-safe diagnostics copied."
      state.error = ""
    } else {
      state.notice = ""
      state.error = "Diagnostics could not be copied. No vault data was placed on the clipboard."
    }
  }
}

/// Stretches a button label to the available width and guarantees a 44pt
/// touch target; the shared button styles only reserve 40-42pt.
private struct UnlockScreenFullWidthLabel: ViewModifier {
  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, minHeight: 44)
      .contentShape(Rectangle())
  }
}

/// Launch splash shown while the automatic unlock runs.
private struct UnlockSplash: View {
  var body: some View {
    VStack(spacing: 18) {
      UnlockBrandTile(size: 84)
      Text("Address Atlas")
        .font(.title2.weight(.semibold))
        .foregroundStyle(AtlasTheme.ink)
      ProgressView()
        .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Address Atlas. Opening your encrypted vault.")
    .accessibilityIdentifier("unlock-splash")
  }
}

private struct UnlockBrandTile: View {
  var size: CGFloat

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
      .fill(
        LinearGradient(
          colors: [AtlasTheme.accent, AtlasTheme.accent.opacity(0.72)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .frame(width: size, height: size)
      .overlay {
        Image(systemName: "map.fill")
          .font(.system(size: size * 0.42, weight: .semibold))
          .foregroundStyle(AtlasTheme.paper)
      }
      .shadow(color: AtlasTheme.accent.opacity(0.28), radius: 14, y: 6)
      .accessibilityHidden(true)
  }
}

private struct UnlockCardHeader: View {
  var title: String
  var subtitle: String
  var systemImage: String
  var tint: Color

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.body.weight(.semibold))
        .foregroundStyle(tint)
        .frame(width: 34, height: 34)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
          .foregroundStyle(AtlasTheme.ink)
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(AtlasTheme.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct UnlockTrustFooter: View {
  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 16) { items }
      VStack(spacing: 8) { items }
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(AtlasTheme.ink3)
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var items: some View {
    Label("Read-only", systemImage: "eye")
    Label("No private keys", systemImage: "hand.raised")
    Label("Encrypted", systemImage: "lock.fill")
  }
}
