import AddressAtlasCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The locked screen: retry unlock, recover a damaged saved portfolio,
/// restore Keychain access from a recovery kit, and share privacy-safe
/// diagnostics. `RootView` already calls `state.unlock()` on appear, so the
/// first attempt shows a calm launch splash; the recovery page only appears
/// when that attempt did not open the portfolio, and its unlock button is the
/// retry path.
///
/// Keeps the macOS `UnlockView` confirmations and safety rules; the copy is
/// shortened for a phone and diagnostics sit behind a disclosure. Nothing here
/// depends on the wording of `state.notice` or `state.error`; a recovery kit
/// restore is judged by the `RecoveryKitRestoreOutcome` AppState returns.
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
      .background(AtlasCanvasBackground().ignoresSafeArea())
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
        "Set aside the damaged data and start fresh?",
        isPresented: $confirmsDamagedVaultQuarantine,
        titleVisibility: .visible
      ) {
        Button("Set aside and start fresh", role: .destructive) {
          Task { await state.quarantineDamagedVaultAndStartClean() }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "The damaged files are copied to a private folder on this device and kept. The copy is checked first. Only then does an empty portfolio open, using the same Keychain key. Nothing is downloaded."
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
      VStack(spacing: 20) {
        IOSPersistentStatus()
        header
        unlockButton

        if let recovery = state.damagedVaultRecoveryAvailability {
          damagedVaultCard(recovery)
            .transition(.opacity)
        }

        recoveryCard

        LearnMoreDisclosure("Diagnostics", systemImage: "stethoscope") {
          diagnosticsControls
        }
      }
      // Wider than the hard card shadows of the Candy and Pixel themes, which
      // fall to the right and below.
      .padding(.horizontal, 20)
      .padding(.vertical, 32)
      .frame(maxWidth: 520)
      .frame(maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively)
  }

  private var headerMessage: String {
    if state.damagedVaultRecoveryAvailability != nil {
      return "The saved portfolio on this \(PlatformCopy.deviceNoun) is damaged."
    }
    if !state.error.isEmpty {
      return "Your portfolio didn't open. Try again, or restore from a recovery kit."
    }
    return "The portfolio is encrypted with a key in this \(PlatformCopy.deviceNoun)'s Keychain."
  }

  private var header: some View {
    VStack(spacing: 14) {
      UnlockBrandTile(size: 72)
      Text("Portfolio locked")
        .font(AtlasTheme.font(.display, size: 32, relativeTo: .largeTitle, weight: .bold))
        .tracking(AtlasTheme.tracking(.display, size: 32))
        .foregroundStyle(AtlasTheme.ink)
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
      Text(headerMessage)
        .font(AtlasTheme.font(.body, .callout))
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
              .tint(AtlasTheme.onAccent)
            Text("Unlocking…")
          }
        } else {
          Label("Unlock", systemImage: "lock.open.fill")
        }
      }
      .modifier(UnlockScreenFullWidthLabel())
    }
    .buttonStyle(AtlasPrimaryButtonStyle())
    .disabled(state.isUnlocking)
    .accessibilityHint("Opens your portfolio with the key in this device's Keychain.")
    .accessibilityIdentifier("unlock-button")
  }

  // MARK: - Damaged vault

  @ViewBuilder
  private func damagedVaultCard(_ recovery: DamagedVaultRecoveryAvailability) -> some View {
    Surface(padding: 16, style: .warning) {
      VStack(alignment: .leading, spacing: 14) {
        UnlockCardHeader(
          title: "Saved portfolio is damaged",
          subtitle: recovery == .validatedRollbackCheckpoint
            ? "An earlier copy passed its checks. Restore it, or set the damaged data aside and start fresh."
            : "No earlier copy is available. Set the damaged data aside and start fresh, then restore a copy you saved elsewhere.",
          systemImage: "exclamationmark.shield.fill",
          tint: AtlasTheme.warning,
          soft: AtlasTheme.warningSoft
        )
        if recovery == .validatedRollbackCheckpoint {
          Button {
            Task { await state.recoverDamagedVaultFromRollbackCheckpoint() }
          } label: {
            Text("Restore earlier copy")
              .modifier(UnlockScreenFullWidthLabel())
          }
          .buttonStyle(AtlasPrimaryButtonStyle())
          .disabled(state.isUnlocking)
          .accessibilityHint(
            "Replaces the damaged data with the earlier copy that passed its checks. Nothing is downloaded."
          )
        }
        Button(role: .destructive) {
          confirmsDamagedVaultQuarantine = true
        } label: {
          Text("Set aside and start fresh")
            .modifier(UnlockScreenFullWidthLabel())
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        .disabled(state.isUnlocking)
        .accessibilityHint("Asks you to confirm before the damaged data is set aside.")
      }
    }
  }

  // MARK: - Recovery kit

  private var recoveryCard: some View {
    IOSCard {
      VStack(alignment: .leading, spacing: 14) {
        UnlockCardHeader(
          title: "Restore from a recovery kit",
          subtitle: "You need the recovery file and its separate code.",
          systemImage: "key.fill",
          tint: AtlasTheme.accent,
          soft: AtlasTheme.accentSoft
        )
        HStack(spacing: 8) {
          Group {
            if revealsRestoreCode {
              TextField("Recovery code", text: $restoreCode)
            } else {
              SecureField("Recovery code", text: $restoreCode)
            }
          }
          .font(AtlasTheme.font(.mono, .callout))
          .textFieldStyle(AtlasTextFieldStyle())
          .atlasIdentifierInput()
          .submitLabel(.done)
          .accessibilityLabel("Recovery code")
          .accessibilityHint("Enter the code you stored separately from the recovery file.")
          Button {
            revealsRestoreCode.toggle()
          } label: {
            Image(systemName: revealsRestoreCode ? "eye.slash" : "eye")
              .font(AtlasTheme.font(.body, .callout))
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
          "Opens the Files picker. The recovery file is checked before anything in Keychain changes."
        )
        Text("Nothing changes unless the kit opens the portfolio on this device.")
          .font(AtlasTheme.font(.label, .caption))
          .foregroundStyle(AtlasTheme.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
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
        let outcome = await state.restoreRecoveryKit(from: url, recoveryCode: recoveryCode)
        guard outcome != .notRestored else { return }
        // The key is back; the code has done its job. The state layer's notice
        // (or error, for a read-only portfolio) says what happens next.
        restoreCode = ""
        revealsRestoreCode = false
      }
    case .failure(let error):
      // Closing the picker without a choice is not a failure.
      if (error as? CocoaError)?.code == .userCancelled { return }
      state.notice = ""
      state.error =
        "Couldn't open that file. Nothing in Keychain changed. Choose the recovery file again."
    }
  }

  // MARK: - Privacy-safe diagnostics

  private var diagnosticsControls: some View {
    let report = state.privacySafeDiagnosticsReport()
    return VStack(alignment: .leading, spacing: 10) {
      Text(
        "App versions, state flags and failure codes only. No addresses, names, amounts, keys, URLs or file paths."
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
          "Copies a short technical report. It has no portfolio content or identifiers."
        )
        ShareLink(
          item: report,
          subject: Text("Address Atlas diagnostics"),
          preview: SharePreview("Diagnostics")
        ) {
          Label("Share", systemImage: "square.and.arrow.up")
            .modifier(UnlockScreenFullWidthLabel())
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        .accessibilityLabel("Share diagnostics")
        .accessibilityHint(
          "Shares the same technical report through the share sheet. It has no portfolio content or identifiers."
        )
      }
    }
  }

  private func copyDiagnostics(_ report: String) {
    let pasteboard = UIPasteboard.general
    pasteboard.string = report
    if pasteboard.hasStrings {
      state.notice = "Diagnostics copied."
      state.error = ""
    } else {
      state.notice = ""
      state.error = "Couldn't copy diagnostics. Nothing was put on the clipboard. Try again."
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
        .font(AtlasTheme.font(.display, .title2, weight: .bold))
        .tracking(AtlasTheme.tracking(.display, size: 22))
        .foregroundStyle(AtlasTheme.ink)
      ProgressView()
        .tint(AtlasTheme.accent)
        .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Address Atlas. Unlocking.")
    .accessibilityIdentifier("unlock-splash")
  }
}

/// The app mark: the atlas glyph on the theme's soft accent fill, outlined and
/// shadowed like any other card of the theme.
private struct UnlockBrandTile: View {
  var size: CGFloat

  var body: some View {
    Image(systemName: "map.fill")
      .font(.system(size: size * 0.42, weight: .semibold))
      .foregroundStyle(AtlasTheme.accent)
      .frame(width: size, height: size)
      .atlasChrome(
        fill: AtlasTheme.accentSoft,
        border: AtlasTheme.outline,
        level: .card,
        radius: min(AtlasRadius.large, size * 0.3)
      )
      .accessibilityHidden(true)
  }
}

private struct UnlockCardHeader: View {
  var title: String
  var subtitle: String
  var systemImage: String
  var tint: Color
  var soft: Color

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(AtlasTheme.font(.body, .body, weight: .semibold))
        // The tile is a fixed size, so the glyph stops growing with it.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .foregroundStyle(tint)
        .frame(width: 36, height: 36)
        .background(soft, in: RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
        .overlay {
          if AtlasTheme.shape.hasBoldBorders {
            RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
              .stroke(AtlasTheme.outline, lineWidth: 1.5)
          }
        }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(AtlasTheme.font(.display, .headline))
          .foregroundStyle(AtlasTheme.ink)
        Text(subtitle)
          .font(AtlasTheme.font(.body, .subheadline))
          .foregroundStyle(AtlasTheme.ink2)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}
