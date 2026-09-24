import AddressAtlasCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The locked-vault screen: retry unlock, recover a damaged local vault,
/// restore Keychain access from a recovery kit, and share privacy-safe
/// diagnostics. `RootView` already calls `state.unlock()` on appear, so the
/// unlock button here is the retry path.
///
/// Ports the macOS `UnlockView` copy, confirmations and safety rules to a
/// single compact column; the desktop trust side panel becomes a compact
/// vertical list at the end of the page.
struct UnlockScreen: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var restoreCode = ""
  @State private var confirmsDamagedVaultQuarantine = false
  @State private var showsRecoveryFileImporter = false
  @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 34

  private var trimmedRestoreCode: String {
    restoreCode.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    NavigationStack {
      IOSPage(title: "Address Atlas") {
        BrandLockup()

        headline

        unlockCard

        if let recovery = state.damagedVaultRecoveryAvailability {
          damagedVaultCard(recovery)
            .transition(.opacity)
        }

        recoveryCard

        Surface(style: .subtle) {
          diagnosticsControls
        }

        trustList
      }
      .animation(
        AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
        value: state.damagedVaultRecoveryAvailability
      )
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
          "Address Atlas will first verify a crash-durable private copy of vault.sqlite and every present SQLite sidecar. Only then will it activate an empty local vault using the same Keychain key. Nothing will be downloaded automatically."
        )
      }
      .fileImporter(
        isPresented: $showsRecoveryFileImporter,
        allowedContentTypes: [AppState.recoveryKitContentType, .json, .data]
      ) { result in
        handleRecoveryFileSelection(result)
      }
    }
  }

  // MARK: - Headline

  private var headline: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Local-first portfolio security", systemImage: "lock.shield.fill")
        .font(.callout.weight(.semibold))
        .foregroundStyle(AtlasTheme.accent)
      Text("Your portfolio,\nprivate by default.")
        .font(.system(size: titleSize, weight: .bold, design: .rounded))
        .tracking(-0.8)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
      Text(
        "Your vault key stays in this device's Keychain. Portfolio data, exchange credentials, scan history, and any iCloud copies are encrypted before storage."
      )
      .font(.body)
      .foregroundStyle(AtlasTheme.ink2)
      .lineSpacing(3)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Unlock

  private var unlockCard: some View {
    Surface(style: .accent) {
      VStack(alignment: .leading, spacing: 16) {
        PanelHeader(
          title: "Encrypted local vault",
          subtitle: "Protected by a random 256-bit key in Keychain",
          systemImage: "lock.fill"
        )
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
          .modifier(UnlockScreenFullWidthLabel())
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        .disabled(state.isUnlocking)
        .accessibilityHint("Opens the encrypted vault with the key stored in this device's Keychain.")
      }
    }
  }

  // MARK: - Damaged vault

  @ViewBuilder
  private func damagedVaultCard(_ recovery: DamagedVaultRecoveryAvailability) -> some View {
    Surface(style: .warning) {
      VStack(alignment: .leading, spacing: 14) {
        PanelHeader(
          title: "Local vault needs attention",
          subtitle: recovery == .validatedRollbackCheckpoint
            ? "A verified encrypted restore point is available"
            : "The damaged database can be preserved before starting clean",
          systemImage: "exclamationmark.shield.fill",
          tint: AtlasTheme.warning
        )
        if recovery == .validatedRollbackCheckpoint {
          Button {
            Task { await state.recoverDamagedVaultFromRollbackCheckpoint() }
          } label: {
            Text("Restore verified rollback point")
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
    }
  }

  // MARK: - Recovery kit

  private var recoveryCard: some View {
    Surface {
      VStack(alignment: .leading, spacing: 16) {
        PanelHeader(
          title: "Restore Keychain access",
          subtitle: "Use your recovery file and separately stored code",
          systemImage: "key.fill"
        )
        VStack(alignment: .leading, spacing: 10) {
          FieldLabel("Recovery code")
          SecureField("Recovery code", text: $restoreCode)
            .textFieldStyle(AtlasTextFieldStyle())
            .atlasIdentifierInput()
            .submitLabel(.done)
            .accessibilityLabel("Recovery code")
            .accessibilityHint("Enter the code you stored separately from the recovery file.")
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
        Text("The recovery file is verified before anything in Keychain is changed.")
          .font(.caption)
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
        await state.restoreRecoveryKit(from: url, recoveryCode: recoveryCode)
      }
    case .failure:
      state.notice = ""
      state.error = "The recovery file could not be opened. Nothing in Keychain was changed."
    }
  }

  // MARK: - Privacy-safe diagnostics

  private var diagnosticsControls: some View {
    let report = state.privacySafeDiagnosticsReport()
    return VStack(alignment: .leading, spacing: 16) {
      PanelHeader(
        title: "Privacy-safe diagnostics",
        subtitle: "Useful support context without portfolio content",
        systemImage: "stethoscope"
      )
      InfoCallout(
        title: "Designed to exclude sensitive data",
        copy:
          "Includes app and schema versions, coarse state flags, count ranges, and stable failure codes. Excludes addresses, labels, amounts, credentials, sessions, URLs, file paths, and raw errors.",
        tone: .success
      )
      Button {
        copyDiagnostics(report)
      } label: {
        Label("Copy diagnostics", systemImage: "doc.on.doc")
          .modifier(UnlockScreenFullWidthLabel())
      }
      .buttonStyle(AtlasSecondaryButtonStyle())
      .accessibilityHint(
        "Copies a bounded technical report that excludes portfolio content and identifiers."
      )
      ShareLink(
        item: report,
        subject: Text("Address Atlas privacy-safe diagnostics"),
        preview: SharePreview("Privacy-safe diagnostics")
      ) {
        Label("Share diagnostics", systemImage: "square.and.arrow.up")
          .modifier(UnlockScreenFullWidthLabel())
      }
      .buttonStyle(AtlasSecondaryButtonStyle())
      .accessibilityHint(
        "Shares the same bounded technical report through the share sheet. It excludes portfolio content and identifiers."
      )
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

  // MARK: - Trust

  private var trustList: some View {
    VStack(alignment: .leading, spacing: 18) {
      Badge("Zero custody", color: AtlasTheme.gain)
      VStack(alignment: .leading, spacing: 8) {
        Text("Everything you track.\nNothing to hand over.")
          .font(.title2.weight(.bold))
          .tracking(-0.4)
          .fixedSize(horizontal: false, vertical: true)
        Text("Address Atlas is a read-only portfolio map built around local ownership.")
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink2)
          .lineSpacing(3)
          .fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 14) {
        UnlockScreenFeature(
          title: "No signing",
          copy: "Only public wallet addresses are scanned",
          systemImage: "signature"
        )
        UnlockScreenFeature(
          title: "No custody",
          copy: "Private keys and seed phrases never enter the app",
          systemImage: "hand.raised.fill"
        )
        UnlockScreenFeature(
          title: "Private iCloud copy",
          copy:
            "Optional encrypted copies go only to your own iCloud account, and only when you save one",
          systemImage: "icloud.and.arrow.up.fill"
        )
      }
      Label("Designed for iPhone and iPad", systemImage: "apple.logo")
        .font(.caption.weight(.medium))
        .foregroundStyle(AtlasTheme.ink3)
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      LinearGradient(
        colors: [AtlasTheme.accent.opacity(0.11), AtlasTheme.gain.opacity(0.055)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
    .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous)
        .stroke(AtlasTheme.ruleSoft, lineWidth: 1)
    }
  }
}

/// Stretches a button label to the page width and guarantees a 44pt touch
/// target; the shared button styles only reserve 40-42pt.
private struct UnlockScreenFullWidthLabel: ViewModifier {
  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, minHeight: 44)
      .contentShape(Rectangle())
  }
}

private struct UnlockScreenFeature: View {
  var title: String
  var copy: String
  var systemImage: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.body.weight(.semibold))
        .foregroundStyle(AtlasTheme.accent)
        .frame(width: 36, height: 36)
        .background(AtlasTheme.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.callout.weight(.semibold))
        Text(copy)
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
          .lineSpacing(2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
