import AddressAtlasCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Preferences, recovery kit export and restore, the update route, policy
/// links, privacy-safe diagnostics, and the version line. iOS port of the
/// macOS `SettingsView`: folder and file panels become the Files picker, the
/// clipboard is `UIPasteboard`, and the recovery code is revealed only after
/// the recovery file has actually been saved outside the app's scratch space.
struct SettingsScreen: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var focusedField: SettingsField?

  @State private var dustThresholdText = ""
  @State private var restoreCode = ""
  @State private var revealedRecoveryCode = ""
  @State private var pendingRecoveryExport: SettingsRecoveryExport?
  @State private var isRecoveryExportRunning = false
  @State private var isRecoveryMoverPresented = false
  @State private var isRestoreConfirmationPresented = false
  @State private var isRecoveryImporterPresented = false
  @State private var isRecoveryRestoreRunning = false

  private enum SettingsField: Hashable {
    case dustThreshold
    case restoreCode
  }

  private static let dustThresholdFormat = FloatingPointFormatStyle<Double>.number
    .locale(AtlasFormatting.locale)
    .precision(.fractionLength(0...2))

  private var trimmedRestoreCode: String {
    restoreCode.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    IOSPage(
      title: "Settings",
      subtitle:
        "Control refresh behavior, portfolio display, recovery, and privacy-safe support tools."
    ) {
      preferencesSection
      recoverySection
      updatesSection
      privacySection
      diagnosticsSection
      versionLine
    }
    .onAppear(perform: syncDustThresholdText)
    .onDisappear {
      // The code is shown once; leaving the screen must not leave it behind.
      revealedRecoveryCode = ""
    }
    .onChange(of: state.document.preferences.dustThreshold) { _, _ in
      if focusedField != .dustThreshold {
        syncDustThresholdText()
      }
    }
    .onChange(of: focusedField) { previous, _ in
      if previous == .dustThreshold {
        commitDustThreshold()
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") {
          focusedField = nil
        }
      }
    }
    .fileMover(
      isPresented: $isRecoveryMoverPresented,
      file: pendingRecoveryExport?.file
    ) { result in
      finishRecoveryExport(result)
    } onCancellation: {
      finishRecoveryExport(nil)
    }
    .confirmationDialog(
      "Replace the vault key in this device's Keychain?",
      isPresented: $isRestoreConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Choose recovery file", role: .destructive) {
        // Presented on the next main-actor turn so the dialog has finished
        // dismissing before the document picker is asked to appear.
        Task { isRecoveryImporterPresented = true }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "The recovery file is opened with your code and checked against the vault on this device before anything in Keychain is changed. If the recovered key does not open this vault, nothing changes."
      )
    }
    .fileImporter(
      isPresented: $isRecoveryImporterPresented,
      allowedContentTypes: [AppState.recoveryKitContentType, .json, .data]
    ) { result in
      switch result {
      case .success(let url):
        restoreRecoveryKit(from: url)
      case .failure(let error):
        state.presentUserFacingError(error)
      }
    }
  }

  // MARK: - Preferences

  private var preferencesSection: some View {
    Surface {
      VStack(alignment: .leading, spacing: 18) {
        PanelHeader(
          title: "Portfolio preferences",
          subtitle: "Stored inside your encrypted local vault",
          systemImage: "slider.horizontal.3"
        )
        SettingsPreferenceToggleRow(
          title: "Automatic refresh",
          copy:
            "Refresh saved sources every 15 minutes while the app is in the foreground and unlocked.",
          systemImage: "arrow.clockwise",
          isOn: Binding(
            get: { state.document.preferences.autoRefresh },
            set: { value in
              Task { await state.setAutoRefresh(value) }
            })
        )
        Divider().overlay(AtlasTheme.ruleSoft)
        SettingsPreferenceToggleRow(
          title: "Hide small balances",
          copy: "Keep low-value holdings out of the main asset list without deleting them.",
          systemImage: "line.3.horizontal.decrease.circle",
          isOn: Binding(
            get: { state.document.preferences.hideDust },
            set: { value in
              Task { await state.setHideDust(value) }
            })
        )
        Divider().overlay(AtlasTheme.ruleSoft)
        VStack(alignment: .leading, spacing: 7) {
          FieldLabel("Small-balance threshold", detail: "USD")
          TextField("0.00", text: $dustThresholdText)
            .textFieldStyle(AtlasTextFieldStyle())
            .atlasDecimalInput()
            .focused($focusedField, equals: .dustThreshold)
            .accessibilityLabel("Dust threshold in US dollars")
            .accessibilityHint("Applied when you leave the field.")
        }
        VStack(alignment: .leading, spacing: 7) {
          FieldLabel("Display currency")
          HStack {
            Text("USD")
              .font(.callout.weight(.semibold))
            Spacer()
            Badge("Current")
          }
          .padding(.horizontal, 13)
          .frame(minHeight: 44)
          .background(AtlasTheme.surfaceMuted.opacity(0.44))
          .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
              .stroke(AtlasTheme.ruleSoft, lineWidth: 1)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Display currency, USD, current")
        }
      }
    }
    .disabled(state.vaultEditsDisabled)
  }

  // MARK: - Recovery kit

  private var recoverySection: some View {
    Surface(style: .warning) {
      VStack(alignment: .leading, spacing: 16) {
        PanelHeader(
          title: "Recovery kit",
          subtitle:
            "A recovery file and separately stored code restore this device's vault key",
          systemImage: "key.fill",
          tint: AtlasTheme.warning
        )
        Text(
          "The recovery file holds your vault key, encrypted with a code that is shown once. Keep the file in Files or iCloud Drive and the code somewhere else; anyone holding both can recover the key."
        )
        .font(.caption)
        .foregroundStyle(AtlasTheme.ink2)
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)

        Button {
          exportRecoveryKit()
        } label: {
          HStack(spacing: 8) {
            if isRecoveryExportRunning {
              ProgressView()
                .controlSize(.small)
                .tint(AtlasTheme.paper)
            }
            Label("Export recovery kit", systemImage: "arrow.down.doc")
          }
          .settingsControlLabel()
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        .disabled(state.isExportOperationInProgress || state.isTerminationInProgress)
        .accessibilityHint(
          "Writes an encrypted recovery file, then lets you save it in Files. The code is shown after the file is saved."
        )

        if !revealedRecoveryCode.isEmpty {
          revealedCodePanel
        }

        Divider().overlay(AtlasTheme.warning.opacity(0.24))

        VStack(alignment: .leading, spacing: 8) {
          FieldLabel("Recovery code")
          SecureField("Enter recovery code", text: $restoreCode)
            .textFieldStyle(AtlasTextFieldStyle())
            .atlasIdentifierInput()
            .focused($focusedField, equals: .restoreCode)
            .submitLabel(.done)
            .accessibilityLabel("Recovery code for restore")
        }
        Button {
          focusedField = nil
          isRestoreConfirmationPresented = true
        } label: {
          HStack(spacing: 8) {
            if isRecoveryRestoreRunning {
              ProgressView()
                .controlSize(.small)
            }
            Label("Choose recovery file", systemImage: "folder")
          }
          .settingsControlLabel()
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        .disabled(
          state.vaultEditsDisabled || isRecoveryRestoreRunning || trimmedRestoreCode.isEmpty
        )
        .accessibilityHint(
          "Asks for confirmation, then opens the Files picker to choose the recovery file."
        )
        Text(
          "The recovery file is verified against the vault on this device before anything in Keychain is changed."
        )
        .font(.caption)
        .foregroundStyle(AtlasTheme.ink3)
        .fixedSize(horizontal: false, vertical: true)
      }
      .animation(
        AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
        value: revealedRecoveryCode.isEmpty
      )
    }
  }

  private var revealedCodePanel: some View {
    VStack(alignment: .leading, spacing: 10) {
      InfoCallout(
        title: "Store this code separately from the recovery file",
        copy:
          "You need both the file and this code to restore. Address Atlas keeps no copy of the code; it disappears when you hide it or leave this screen.",
        tone: .warning
      )
      VStack(alignment: .leading, spacing: 6) {
        FieldLabel("Recovery code", detail: "Selectable")
        Text(revealedRecoveryCode)
          .font(.callout.monospaced())
          .textSelection(.enabled)
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(AtlasTheme.surface)
          .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
              .stroke(AtlasTheme.ruleSoft, lineWidth: 1)
          }
          .accessibilityLabel("Recovery code")
          .accessibilityValue(revealedRecoveryCode)
      }
      AdaptiveStack {
        Button {
          copyRecoveryCode()
        } label: {
          Label("Copy code", systemImage: "doc.on.doc")
            .settingsControlLabel()
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        .accessibilityHint(
          "Copies the code to this device's clipboard for one minute without sharing it with other devices."
        )
        Button {
          revealedRecoveryCode = ""
        } label: {
          Label("Hide code", systemImage: "eye.slash")
            .settingsControlLabel()
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        .accessibilityHint("Removes the code from the screen. It cannot be shown again.")
      }
    }
    .transition(.opacity)
  }

  // MARK: - Updates

  private var updatesSection: some View {
    Surface {
      VStack(alignment: .leading, spacing: 14) {
        PanelHeader(
          title: "Updates",
          subtitle: "Delivered through the \(PlatformCopy.appStoreName)",
          systemImage: "arrow.down.circle"
        )
        if !state.isAppVersionSupported {
          InfoCallout(
            title: "Update required",
            copy:
              "This version is below the minimum supported version. Update Address Atlas before continuing.",
            tone: .warning
          )
        }
        VStack(spacing: 0) {
          SettingsKeyValueRow(label: "Version", value: state.appVersion)
          Divider().overlay(AtlasTheme.ruleSoft)
          SettingsKeyValueRow(label: "Build", value: SettingsBuildInfo.buildNumber)
          Divider().overlay(AtlasTheme.ruleSoft)
          SettingsKeyValueRow(
            label: "Source commit",
            value: SettingsBuildInfo.shortSourceCommit ?? "Unavailable"
          )
        }
        Link(destination: state.safeUpdateDownloadURL) {
          Label(state.updateActionTitle, systemImage: "arrow.up.forward.app")
            .settingsControlLabel()
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        .accessibilityHint(state.updateActionHint)
      }
    }
  }

  // MARK: - Privacy and support

  private var privacySection: some View {
    Surface {
      VStack(alignment: .leading, spacing: 14) {
        PanelHeader(
          title: "Privacy and support",
          subtitle: "Review data boundaries, get help, or inspect the price-data source",
          systemImage: "hand.raised.fill"
        )
        VStack(spacing: 10) {
          Link(destination: AppState.privacyPolicyURL) {
            Label("Privacy policy", systemImage: "lock.doc")
              .settingsControlLabel()
          }
          .buttonStyle(AtlasSecondaryButtonStyle())
          Link(destination: AppState.supportURL) {
            Label("Support", systemImage: "questionmark.circle")
              .settingsControlLabel()
          }
          .buttonStyle(AtlasSecondaryButtonStyle())
          Link(destination: AppState.termsOfUseURL) {
            Label("Terms of use", systemImage: "doc.text")
              .settingsControlLabel()
          }
          .buttonStyle(AtlasSecondaryButtonStyle())
          Link(destination: AppState.coinGeckoAttributionURL) {
            Label("Data provided by CoinGecko", systemImage: "chart.line.uptrend.xyaxis")
              .settingsControlLabel()
          }
          .buttonStyle(AtlasSecondaryButtonStyle())
        }
        Text(
          "Address Atlas is read-only analytics software. It never creates wallets, stores private keys, signs transactions, executes trades, or provides personalized investment advice."
        )
        .font(.caption)
        .foregroundStyle(AtlasTheme.ink2)
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: - Diagnostics

  private var diagnosticsSection: some View {
    let report = state.privacySafeDiagnosticsReport()
    return Surface(style: .subtle) {
      VStack(alignment: .leading, spacing: 16) {
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
        AdaptiveStack {
          Button {
            copyDiagnostics(report)
          } label: {
            Label("Copy diagnostics", systemImage: "doc.on.doc")
              .settingsControlLabel()
          }
          .buttonStyle(AtlasSecondaryButtonStyle())
          .accessibilityHint(
            "Copies a bounded technical report that excludes portfolio content and identifiers."
          )
          ShareLink(
            item: report,
            subject: Text("Address Atlas privacy-safe diagnostics")
          ) {
            Label("Share diagnostics", systemImage: "square.and.arrow.up")
              .settingsControlLabel()
          }
          .buttonStyle(AtlasSecondaryButtonStyle())
          .accessibilityHint(
            "Opens the share sheet with the same bounded report, for example to attach it to a support message."
          )
        }
      }
    }
  }

  // MARK: - Version line

  private var versionLine: some View {
    Text(SettingsBuildInfo.versionLine(appVersion: state.appVersion))
      .font(.caption)
      .foregroundStyle(AtlasTheme.ink3)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity)
      .multilineTextAlignment(.center)
      .padding(.top, 4)
  }

  // MARK: - Preference actions

  private func syncDustThresholdText() {
    dustThresholdText = Self.formattedDustThreshold(state.document.preferences.dustThreshold)
  }

  private static func formattedDustThreshold(_ value: Double) -> String {
    value.formatted(dustThresholdFormat)
  }

  /// Commits the typed threshold when focus leaves the field. The decimal
  /// keyboard has no return key, so this is the only commit path besides the
  /// keyboard toolbar's Done button, which also clears focus.
  private func commitDustThreshold() {
    let current = state.document.preferences.dustThreshold
    let trimmed = dustThresholdText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != Self.formattedDustThreshold(current) else {
      syncDustThresholdText()
      return
    }
    guard let value = try? Double(trimmed, format: Self.dustThresholdFormat),
      value.isFinite, value >= 0
    else {
      syncDustThresholdText()
      state.notice = ""
      state.error = "Dust threshold must be a finite, non-negative USD value."
      return
    }
    guard value != current else {
      syncDustThresholdText()
      return
    }
    Task { await state.setDustThreshold(value) }
  }

  // MARK: - Recovery kit actions

  /// Writes the kit into an app-owned scratch directory off the main actor,
  /// then hands the file to the Files picker. The code stays hidden until the
  /// move succeeds, so a cancelled export never shows a code for a file that
  /// was deleted.
  private func exportRecoveryKit() {
    guard !isRecoveryExportRunning, pendingRecoveryExport == nil else { return }
    guard state.beginExportOperation() else { return }
    isRecoveryExportRunning = true
    revealedRecoveryCode = ""
    Task {
      var directory: URL?
      do {
        let exportDirectory = try TemporaryExportFiles.makeRecoveryKitDirectory()
        directory = exportDirectory
        let filename =
          "address-atlas-recovery-\(Self.settingsRecoveryExportTimestamp()).atlas-recovery"
        let destination = exportDirectory.appending(path: filename)
        let code = try await state.exportRecoveryKitOffMain(to: destination)
        pendingRecoveryExport = SettingsRecoveryExport(
          directory: exportDirectory,
          file: destination,
          code: code
        )
        // The shared helper reports the write as saved; on iOS the file only
        // exists in scratch space until the picker moves it somewhere durable.
        state.notice = "Choose where to save the recovery file."
        state.error = ""
        isRecoveryMoverPresented = true
      } catch {
        if let directory {
          TemporaryExportFiles.remove(directory)
        }
        isRecoveryExportRunning = false
        state.presentUserFacingError(error)
        state.finishExportOperation()
      }
    }
  }

  /// Every completion path deletes the scratch directory and releases the
  /// export lane. `nil` means the picker was cancelled.
  private func finishRecoveryExport(_ result: Result<URL, any Error>?) {
    defer {
      isRecoveryExportRunning = false
      state.finishExportOperation()
    }
    guard let export = pendingRecoveryExport else { return }
    pendingRecoveryExport = nil
    TemporaryExportFiles.remove(export.directory)
    switch result {
    case .success(let url):
      revealedRecoveryCode = export.code
      state.notice = "Recovery kit saved as \(url.lastPathComponent). Store the code separately."
      state.error = ""
    case .failure(let error):
      revealedRecoveryCode = ""
      state.presentUserFacingError(error)
    case nil:
      revealedRecoveryCode = ""
      state.notice =
        "Recovery kit export cancelled. The temporary file was deleted and no code was shown."
      state.error = ""
    }
  }

  private func copyRecoveryCode() {
    guard !revealedRecoveryCode.isEmpty else { return }
    UIPasteboard.general.setItems(
      [[UTType.utf8PlainText.identifier: revealedRecoveryCode]],
      options: [
        .localOnly: true,
        .expirationDate: Date().addingTimeInterval(60),
      ]
    )
    state.notice =
      "Recovery code copied. The clipboard entry stays on this device and expires in one minute."
    state.error = ""
  }

  private func restoreRecoveryKit(from url: URL) {
    guard !isRecoveryRestoreRunning else { return }
    let code = restoreCode
    let isAccessing = url.startAccessingSecurityScopedResource()
    isRecoveryRestoreRunning = true
    Task {
      defer {
        if isAccessing {
          url.stopAccessingSecurityScopedResource()
        }
        isRecoveryRestoreRunning = false
      }
      await state.restoreRecoveryKit(from: url, recoveryCode: code)
    }
  }

  private static func settingsRecoveryExportTimestamp(now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter.string(from: now)
  }

  // MARK: - Diagnostics actions

  private func copyDiagnostics(_ report: String) {
    UIPasteboard.general.string = report
    state.notice = "Privacy-safe diagnostics copied."
    state.error = ""
  }
}

// MARK: - Private helpers

/// A recovery file that exists only in scratch space until the Files picker
/// moves it; the code is revealed once that move succeeds.
private struct SettingsRecoveryExport {
  var directory: URL
  var file: URL
  var code: String
}

private struct SettingsPreferenceToggleRow: View {
  var title: String
  var copy: String
  var systemImage: String
  @Binding var isOn: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      Image(systemName: systemImage)
        .font(.body.weight(.semibold))
        .foregroundStyle(AtlasTheme.accent)
        .frame(width: 38, height: 38)
        .background(AtlasTheme.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.callout.weight(.semibold))
        Text(copy)
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityHidden(true)
      Spacer(minLength: 12)
      Toggle(title, isOn: $isOn)
        .labelsHidden()
        .tint(AtlasTheme.accent)
        .accessibilityLabel(title)
        .accessibilityHint(copy)
    }
    .frame(minHeight: 44)
  }
}

private struct SettingsKeyValueRow: View {
  var label: String
  var value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .font(.callout.weight(.medium))
        .foregroundStyle(AtlasTheme.ink3)
      Spacer(minLength: 12)
      Text(value)
        .font(.callout.monospacedDigit())
        .foregroundStyle(AtlasTheme.ink2)
        .textSelection(.enabled)
        .multilineTextAlignment(.trailing)
    }
    .padding(.vertical, 11)
    .accessibilityElement(children: .combine)
  }
}

private enum SettingsBuildInfo {
  static var buildNumber: String {
    let raw = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return raw.isEmpty ? "unknown" : raw
  }

  /// The first seven characters of the commit the build script recorded, or
  /// `nil` when the Info.plist still carries the unexpanded placeholder.
  static var shortSourceCommit: String? {
    guard
      let raw = (Bundle.main.infoDictionary?["AddressAtlasSourceCommit"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      raw.count >= 7,
      raw.allSatisfy(\.isHexDigit)
    else { return nil }
    return String(raw.prefix(7))
  }

  static func versionLine(appVersion: String) -> String {
    var line = "Address Atlas \(appVersion) (\(buildNumber))"
    if let commit = shortSourceCommit {
      line += " · \(commit)"
    }
    return line
  }
}

extension View {
  /// Full-width, 44pt-tall control label so every button and link in Settings
  /// meets the touch-target minimum inside the shared button styles.
  fileprivate func settingsControlLabel() -> some View {
    frame(maxWidth: .infinity, minHeight: 44)
  }
}
