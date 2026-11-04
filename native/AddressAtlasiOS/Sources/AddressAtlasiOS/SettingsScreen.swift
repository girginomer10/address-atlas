import AddressAtlasCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Theme and preferences, the iCloud and Export entries, the privacy facts,
/// recovery kit export and restore, policy links, privacy-safe diagnostics and
/// the About block, laid out as themed cards. iOS port of the macOS
/// `SettingsView`: folder and file panels become the Files picker, the
/// clipboard is `UIPasteboard`, and the recovery code is revealed only after
/// the recovery file has actually been saved outside the app's scratch space.
struct SettingsScreen: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @FocusState private var focusedField: SettingsField?

  @State private var dustThresholdText = ""
  @State private var dustThresholdError: String?
  @State private var restoreCode = ""
  @State private var revealedRecoveryCode = ""
  @State private var pendingRecoveryExport: SettingsRecoveryExport?
  @State private var isRecoveryExportRunning = false
  @State private var isRecoveryMoverPresented = false
  @State private var isRestoreFormExpanded = false
  @State private var isRestoreConfirmationPresented = false
  @State private var isRecoveryImporterPresented = false
  @State private var isRecoveryRestoreRunning = false
  /// File name of the kit just saved, shown with the code instead of a toast
  /// that would cover the code's buttons.
  @State private var savedRecoveryFileName = ""
  @State private var recoveryCodeCopied = false
  @State private var revealsRestoreCode = false
  @State private var restoreSucceeded = false

  private enum SettingsField: Hashable {
    case dustThreshold
    case restoreCode
  }

  private static let dustThresholdFormat = FloatingPointFormatStyle<Double>.number
    .locale(AtlasFormatting.locale)
    .precision(.fractionLength(0...2))

  private static let dustThresholdErrorMessage = "That is not a dollar amount. Enter 0 or more."

  /// What the privacy group says, once. Each line is backed by PRIVACY.md and
  /// the code: read-only scanning, the encrypted vault, exchange credentials,
  /// the two outside services that see anything, and optional iCloud copies.
  private static let privacyFacts: [SettingsFact] = [
    SettingsFact(
      systemImage: "eye",
      text:
        "Address Atlas is read-only. It never asks for a seed phrase or private key and cannot move funds."
    ),
    SettingsFact(
      systemImage: "lock",
      text: "Your portfolio is encrypted on this device."
    ),
    SettingsFact(
      systemImage: "key",
      text: "Exchange keys are stored encrypted. Use read-only keys."
    ),
    SettingsFact(
      systemImage: "globe",
      text:
        "Blockchain providers see the public addresses you add. Prices come from CoinGecko, which receives only coin identifiers."
    ),
    SettingsFact(
      systemImage: "icloud",
      text: "iCloud copies are optional and encrypted before they leave this device."
    ),
  ]

  private var trimmedRestoreCode: String {
    restoreCode.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var animation: Animation? {
    AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion)
  }

  var body: some View {
    IOSPage(title: "Settings") {
      themeSection
      preferencesSection
      dataSection
      privacySection
      recoverySection
      supportSection
      diagnosticsSection
      aboutSection
    }
    .onAppear(perform: syncDustThresholdText)
    .onDisappear {
      // The code is shown once; leaving the screen must not leave it behind.
      revealedRecoveryCode = ""
      revealsRestoreCode = false
    }
    .onChange(of: scenePhase) { _, phase in
      // Backgrounding or the app switcher hides the code for good.
      if phase != .active {
        revealedRecoveryCode = ""
        revealsRestoreCode = false
      }
    }
    .onChange(of: state.document.preferences.dustThreshold) { _, _ in
      if focusedField != .dustThreshold {
        syncDustThresholdText()
      }
    }
    .onChange(of: state.document.preferences.hideDust) { _, _ in
      dustThresholdError = nil
    }
    .onChange(of: focusedField) { previous, _ in
      if previous == .dustThreshold {
        commitDustThreshold()
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
    .fileImporter(
      isPresented: $isRecoveryImporterPresented,
      // Only recovery kits (.atlas-recovery), as on macOS; JSON exports and
      // other files can't be picked by mistake.
      allowedContentTypes: [AppState.recoveryKitContentType]
    ) { result in
      switch result {
      case .success(let url):
        restoreRecoveryKit(from: url)
      case .failure(let error):
        state.presentUserFacingError(error)
      }
    }
  }

  // MARK: - Theme

  /// Theme grid and light/dark control. The choice is stored on this device
  /// only (not in the vault) and restyles the app immediately.
  private var themeSection: some View {
    SettingsGroup(title: "Theme", framed: false) {
      AtlasThemePicker()
    }
  }

  // MARK: - Preferences

  private var preferencesSection: some View {
    SettingsGroup(
      title: "Preferences",
      footer: "Refreshes every 15 minutes while the app is open. Values are in US dollars."
    ) {
      SettingsToggleRow(
        title: "Automatic refresh",
        systemImage: "arrow.clockwise",
        hint: "Refreshes saved sources every 15 minutes while the app is in the foreground and unlocked.",
        isOn: Binding(
          get: { state.document.preferences.autoRefresh },
          set: { value in
            Task { await state.setAutoRefresh(value) }
          })
      )
      SettingsRule()
      SettingsToggleRow(
        title: "Hide small balances",
        systemImage: "eye.slash",
        hint: "Keeps low-value holdings out of the asset list without deleting them.",
        isOn: Binding(
          get: { state.document.preferences.hideDust },
          set: { value in
            Task { await state.setHideDust(value) }
          })
      )
      if state.document.preferences.hideDust {
        SettingsRule()
        dustThresholdRow
          .transition(.opacity)
      }
    }
    .disabled(state.vaultEditsDisabled)
    .animation(animation, value: state.document.preferences.hideDust)
  }

  private var dustThresholdField: some View {
    HStack(spacing: 8) {
      Text("$")
        .font(AtlasTheme.font(.number, .body))
        .foregroundStyle(AtlasTheme.ink3)
        .accessibilityHidden(true)
      TextField("0.00", text: $dustThresholdText)
        .font(AtlasTheme.font(.number, .body))
        .textFieldStyle(AtlasTextFieldStyle())
        .atlasDecimalInput()
        .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
        .focused($focusedField, equals: .dustThreshold)
        .overlay {
          if dustThresholdError != nil {
            RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
              .stroke(AtlasTheme.loss, lineWidth: 2)
              .accessibilityHidden(true)
          }
        }
        .accessibilityLabel("Hide balances below, in US dollars")
        .accessibilityHint("Applied when you leave the field.")
        .accessibilityIdentifier("settings.dustThreshold")
        .onChange(of: dustThresholdText) { _, _ in
          if focusedField == .dustThreshold {
            dustThresholdError = nil
          }
        }
    }
  }

  private var dustThresholdRow: some View {
    VStack(alignment: .leading, spacing: 8) {
      if dynamicTypeSize.isAccessibilitySize {
        SettingsRowLabel(title: "Hide below", systemImage: "line.3.horizontal.decrease") {
          EmptyView()
        }
        dustThresholdField
          .padding(.horizontal, 14)
      } else {
        SettingsRowLabel(title: "Hide below", systemImage: "line.3.horizontal.decrease") {
          dustThresholdField.frame(maxWidth: 170)
        }
      }

      if let dustThresholdError {
        Label(dustThresholdError, systemImage: "exclamationmark.circle.fill")
          .font(AtlasTheme.font(.body, .footnote))
          .foregroundStyle(AtlasTheme.loss)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 14)
          .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 0 : 42)
          .accessibilityLabel("Error: \(dustThresholdError)")
          .accessibilityIdentifier("settings.dustThreshold.error")
      }
    }
    .padding(.bottom, dustThresholdError == nil && !dynamicTypeSize.isAccessibilitySize ? 0 : 12)
  }

  // MARK: - iCloud and Export

  /// The iCloud row's second line, in plain words: a failed transfer
  /// (`AppState.iCloudStatusKind`), otherwise the saved link.
  private var iCloudNeedsAttention: Bool { state.iCloudStatusKind == .needsAttention }

  private var iCloudRowStatus: String {
    if iCloudNeedsAttention { return "Needs attention" }
    if let cloud = state.document.iCloudState {
      return "Last saved \(AtlasFormatting.dateTime(cloud.savedAt))"
    }
    return "Not connected"
  }

  private var dataSection: some View {
    SettingsGroup {
      NavigationLink(value: IOSRoute.iCloud) {
        SettingsRowLabel(
          title: "iCloud",
          subtitle: iCloudRowStatus,
          subtitleColor: iCloudNeedsAttention ? AtlasTheme.warning : AtlasTheme.ink3,
          systemImage: "icloud",
          tone: iCloudNeedsAttention ? .warning : .accent
        ) {
          SettingsChevron()
        }
      }
      .buttonStyle(SettingsRowButtonStyle())
      .accessibilityIdentifier("settings.iCloud")
      SettingsRule()
      NavigationLink(value: IOSRoute.export) {
        SettingsRowLabel(
          title: "Export",
          subtitle: "CSV or JSON",
          systemImage: "square.and.arrow.up"
        ) {
          SettingsChevron()
        }
      }
      .buttonStyle(SettingsRowButtonStyle())
      .accessibilityIdentifier("settings.export")
    }
  }

  // MARK: - Privacy

  private var privacySection: some View {
    SettingsGroup(title: "Privacy") {
      ForEach(Array(Self.privacyFacts.enumerated()), id: \.offset) { index, fact in
        if index > 0 { SettingsRule() }
        SettingsFactRow(fact: fact)
      }
    }
  }

  // MARK: - Recovery kit

  private var recoverySection: some View {
    SettingsGroup(
      title: "Recovery kit",
      footer: "Keep the file and its code in different places. Anyone with both can recover your encryption key."
    ) {
      Button {
        exportRecoveryKit()
      } label: {
        SettingsRowLabel(
          title: "Export recovery kit",
          systemImage: "key.fill",
          tone: .warning
        ) {
          if isRecoveryExportRunning {
            ProgressView().controlSize(.small)
          } else {
            SettingsChevron()
          }
        }
      }
      .buttonStyle(SettingsRowButtonStyle())
      .disabled(state.isExportOperationInProgress || state.isTerminationInProgress)
      .accessibilityHint(
        "Writes an encrypted recovery file, then lets you save it in Files. The code is shown after the file is saved."
      )
      .accessibilityIdentifier("settings.exportRecoveryKit")

      if !revealedRecoveryCode.isEmpty {
        revealedCodePanel
          .padding(.horizontal, 14)
          .padding(.bottom, 14)
      }

      SettingsRule()

      Button {
        isRestoreFormExpanded.toggle()
        if !isRestoreFormExpanded {
          focusedField = nil
        }
      } label: {
        SettingsRowLabel(
          title: "Restore recovery kit",
          systemImage: "arrow.counterclockwise"
        ) {
          Image(systemName: "chevron.down")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AtlasTheme.ink3)
            .rotationEffect(.degrees(isRestoreFormExpanded ? 180 : 0))
            .accessibilityHidden(true)
        }
      }
      .buttonStyle(SettingsRowButtonStyle())
      .accessibilityValue(isRestoreFormExpanded ? "Expanded" : "Collapsed")
      .accessibilityIdentifier("settings.restoreRecoveryKit")

      if isRestoreFormExpanded {
        restoreForm
          .padding(.horizontal, 14)
          .padding(.bottom, 14)
          .transition(.opacity)
      }
    }
    .animation(animation, value: revealedRecoveryCode.isEmpty)
    .animation(animation, value: isRestoreFormExpanded)
  }

  private var restoreForm: some View {
    VStack(alignment: .leading, spacing: 10) {
      if restoreSucceeded {
        restoreSuccessPanel
      }
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
        .focused($focusedField, equals: .restoreCode)
        .submitLabel(.done)
        .accessibilityLabel("Recovery code for restore")
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
      .onChange(of: restoreCode) { _, code in
        if !code.isEmpty { restoreSucceeded = false }
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
      // Anchored to the button that asked for it.
      .confirmationDialog(
        "Use this recovery kit on this device?",
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
          "The kit's key replaces the one saved on this device, but only if it opens the portfolio stored here. Otherwise nothing changes."
        )
      }
    }
  }

  /// What a successful restore did, in place of a generic toast: the kit
  /// holds the encryption key, not the portfolio itself.
  private var restoreSuccessPanel: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label {
        VStack(alignment: .leading, spacing: 4) {
          Text("Encryption key restored")
            .font(AtlasTheme.font(.body, .callout, weight: .semibold))
            .foregroundStyle(AtlasTheme.ink)
          Text(
            "This device can open its saved portfolio again. To bring in a portfolio saved on another device, restore its iCloud copy."
          )
          .font(AtlasTheme.font(.body, .footnote))
          .foregroundStyle(AtlasTheme.ink2)
          .fixedSize(horizontal: false, vertical: true)
        }
      } icon: {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(AtlasTheme.gain)
      }
      .accessibilityElement(children: .combine)
      Button {
        restoreSucceeded = false
        navigation.openICloud()
      } label: {
        Label("Open iCloud", systemImage: "icloud")
          .settingsControlLabel()
      }
      .buttonStyle(AtlasSecondaryButtonStyle())
      .accessibilityHint("Opens the iCloud page, where you can restore a saved copy.")
    }
    .settingsPanel(.gain)
    .accessibilityIdentifier("settings.restoreSucceeded")
  }

  /// The code has no system text selection: the only copy path is the Copy
  /// button, which keeps the clipboard entry local and expiring (F08).
  private var revealedCodePanel: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !savedRecoveryFileName.isEmpty {
        Label {
          Text("Saved \(savedRecoveryFileName)")
            .lineLimit(2)
            .truncationMode(.middle)
        } icon: {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(AtlasTheme.gain)
        }
        .font(AtlasTheme.font(.body, .footnote, weight: .medium))
        .foregroundStyle(AtlasTheme.ink2)
      }
      Label {
        Text("Store this code apart from the file. It won't be shown again.")
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(AtlasTheme.warning)
      }
      .font(AtlasTheme.font(.body, .footnote, weight: .medium))
      .foregroundStyle(AtlasTheme.ink2)
      .fixedSize(horizontal: false, vertical: true)

      Text(revealedRecoveryCode)
        .font(AtlasTheme.font(.mono, .callout))
        .foregroundStyle(AtlasTheme.ink)
        .privacySensitive()
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .atlasChrome(
          fill: AtlasTheme.surface,
          border: AtlasTheme.shape.hasBoldBorders
            ? AtlasTheme.outline : AtlasTheme.warning.opacity(0.45),
          level: .control,
          radius: AtlasRadius.control,
          borderWidth: AtlasTheme.shape.hasBoldBorders ? AtlasTheme.shape.controlBorderWidth : 1,
          showsShadow: false
        )
        .accessibilityLabel("Recovery code")
        .accessibilityValue(revealedRecoveryCode)
        .accessibilityIdentifier("settings.recoveryCode")

      AdaptiveStack {
        Button {
          copyRecoveryCode()
        } label: {
          Label(
            recoveryCodeCopied ? "Copied" : "Copy code",
            systemImage: recoveryCodeCopied ? "checkmark" : "doc.on.doc"
          )
          .settingsControlLabel()
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        .accessibilityHint(
          "Copies the code to this device's clipboard for one minute without sharing it with other devices."
        )
        .task(id: recoveryCodeCopied) {
          guard recoveryCodeCopied else { return }
          try? await Task.sleep(for: .seconds(3))
          recoveryCodeCopied = false
        }
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
    .settingsPanel(.warning)
    .transition(.opacity)
  }

  // MARK: - Support and legal

  private var supportSection: some View {
    SettingsGroup(title: "Support & legal") {
      SettingsLinkRow(
        title: "Privacy policy", systemImage: "hand.raised.fill",
        destination: AppState.privacyPolicyURL)
      SettingsRule()
      SettingsLinkRow(
        title: "Support", systemImage: "questionmark.circle.fill",
        destination: AppState.supportURL)
      SettingsRule()
      SettingsLinkRow(
        title: "Terms of use", systemImage: "doc.text.fill",
        destination: AppState.termsOfUseURL)
      SettingsRule()
      SettingsLinkRow(
        title: "Data provided by CoinGecko", systemImage: "chart.line.uptrend.xyaxis",
        destination: AppState.coinGeckoAttributionURL)
    }
  }

  // MARK: - Diagnostics

  private var diagnosticsSection: some View {
    let report = state.privacySafeDiagnosticsReport()
    return SettingsGroup(title: "Diagnostics") {
      VStack(alignment: .leading, spacing: 12) {
        SettingsRowLabel(
          title: "Privacy-safe report",
          subtitle:
            "App version, state flags, count ranges and error codes. No addresses, names, amounts or keys.",
          systemImage: "stethoscope"
        ) {
          EmptyView()
        }
        .accessibilityElement(children: .combine)
        AdaptiveStack {
          Button {
            copyDiagnostics(report)
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
              .settingsControlLabel()
          }
          .buttonStyle(AtlasSecondaryButtonStyle())
          .accessibilityLabel("Copy diagnostics")
          .accessibilityHint(
            "Copies a short technical report that leaves out portfolio content and identifiers."
          )
          .accessibilityIdentifier("settings.copyDiagnostics")
          ShareLink(
            item: report,
            subject: Text("Address Atlas privacy-safe diagnostics")
          ) {
            Label("Share", systemImage: "square.and.arrow.up")
              .settingsControlLabel()
          }
          .buttonStyle(AtlasSecondaryButtonStyle())
          .accessibilityLabel("Share diagnostics")
          .accessibilityHint(
            "Opens the share sheet with the same short report, for example to attach it to a support message."
          )
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
      }
    }
  }

  // MARK: - About

  private var aboutSection: some View {
    SettingsGroup(
      title: "About",
      footer: "Address Atlas does not give investment advice."
    ) {
      SettingsValueRow(label: "Version", value: state.appVersion) {
        if !state.isAppVersionSupported {
          Badge("Update required", color: AtlasTheme.warning)
        }
      }
      SettingsRule(inset: 14)
      SettingsValueRow(label: "Build", value: SettingsBuildInfo.buildNumber, isMono: true)
      SettingsRule(inset: 14)
      SettingsValueRow(
        label: "Source commit",
        value: SettingsBuildInfo.shortSourceCommit ?? "Unavailable",
        isMono: SettingsBuildInfo.shortSourceCommit != nil
      )
      if showsUpdateLink {
        SettingsRule(inset: 14)
        updateLink
      }
    }
  }

  /// The store link only appears once the build carries a real product page;
  /// the generic apps.apple.com fallback opens a blank page.
  private var showsUpdateLink: Bool {
    let url = state.safeUpdateDownloadURL
    guard state.usesMacAppStoreUpdates else { return true }
    return url != AppState.macAppStoreFallbackURL && url.path.contains("/app/")
  }

  private var updateLink: some View {
    Link(destination: state.safeUpdateDownloadURL) {
      HStack(spacing: 12) {
        Text(
          state.usesMacAppStoreUpdates
            ? "View in \(PlatformCopy.appStoreName)" : "Download latest release"
        )
        .foregroundStyle(AtlasTheme.accent)
        Spacer(minLength: 8)
        Image(systemName: "arrow.up.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(AtlasTheme.ink3)
          .accessibilityHidden(true)
      }
      .font(AtlasTheme.font(.body, .body))
      .padding(.horizontal, 14)
      .frame(minHeight: 48)
      .contentShape(Rectangle())
    }
    .buttonStyle(SettingsRowButtonStyle())
    .accessibilityLabel(state.updateActionTitle)
    .accessibilityHint(state.updateActionHint)
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
  /// keyboard toolbar's Done button, which also clears focus. An invalid
  /// value is reverted and explained right under the field.
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
      dustThresholdError = Self.dustThresholdErrorMessage
      AtlasAccessibilityAnnouncer.shared.announceEvent(Self.dustThresholdErrorMessage, kind: .error)
      return
    }
    dustThresholdError = nil
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
    savedRecoveryFileName = ""
    recoveryCodeCopied = false
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
        // exists in scratch space until the picker moves it somewhere durable,
        // and the picker itself asks where to save it.
        state.notice = ""
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
      // Confirmed inside the code panel; a toast would cover its buttons.
      revealedRecoveryCode = export.code
      savedRecoveryFileName = url.lastPathComponent
      state.notice = ""
      state.error = ""
      AtlasAccessibilityAnnouncer.shared.announceEvent(
        "Recovery kit saved. Store the code separately.", kind: .notice)
    case .failure(let error):
      revealedRecoveryCode = ""
      state.presentUserFacingError(error)
    case nil:
      revealedRecoveryCode = ""
      state.postNotice(
        "Export cancelled. The temporary file was deleted and no code was shown.", tone: .neutral)
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
    // Confirmed on the button itself; a toast would cover the code panel.
    recoveryCodeCopied = true
    state.error = ""
    AtlasAccessibilityAnnouncer.shared.announceEvent(
      "Code copied to this device only. It expires in one minute.", kind: .notice)
  }

  private func restoreRecoveryKit(from url: URL) {
    guard !isRecoveryRestoreRunning else { return }
    let code = restoreCode
    let isAccessing = url.startAccessingSecurityScopedResource()
    isRecoveryRestoreRunning = true
    restoreSucceeded = false
    // A notice left over from earlier must not be read as this restore's result.
    state.notice = ""
    Task {
      defer {
        if isAccessing {
          url.stopAccessingSecurityScopedResource()
        }
        isRecoveryRestoreRunning = false
      }
      let outcome = await state.restoreRecoveryKit(from: url, recoveryCode: code)
      guard outcome != .notRestored else { return }
      // The code has done its job; it doesn't stay on screen.
      restoreCode = ""
      revealsRestoreCode = false
      switch outcome {
      case .restored:
        // A plain confirmation is explained inline, not in the toast.
        restoreSucceeded = true
        state.notice = ""
      case .restoredWithFollowUp:
        // What comes next (a finishing upload, a read-only portfolio) stays in
        // the toast; the inline panel only says the key is back.
        restoreSucceeded = state.error.isEmpty
      case .notRestored:
        break
      }
      AtlasAccessibilityAnnouncer.shared.announceEvent(
        "Encryption key restored on this device.", kind: .notice)
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
    state.notice = "Diagnostics copied."
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

/// One line of the Privacy group.
private struct SettingsFact {
  var systemImage: String
  var text: String
}

/// Which theme colours a row's icon tile or a panel takes.
private enum SettingsTone {
  case accent
  case neutral
  case gain
  case warning
  case loss

  var ink: Color {
    switch self {
    case .accent: AtlasTheme.accent
    case .neutral: AtlasTheme.ink2
    case .gain: AtlasTheme.gain
    case .warning: AtlasTheme.warning
    case .loss: AtlasTheme.loss
    }
  }

  var softFill: Color {
    switch self {
    case .accent: AtlasTheme.accentSoft
    case .neutral: AtlasTheme.surfaceMuted
    case .gain: AtlasTheme.gainSoft
    case .warning: AtlasTheme.warningSoft
    case .loss: AtlasTheme.lossSoft
    }
  }
}

/// A titled themed card of rows, with an optional footnote. The theme grid
/// passes `framed: false` because it draws its own cards.
private struct SettingsGroup<Content: View>: View {
  var title: String?
  var footer: String?
  /// False for content that draws its own cards (the theme grid).
  var framed = true
  var content: Content

  init(
    title: String? = nil,
    footer: String? = nil,
    framed: Bool = true,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.footer = footer
    self.framed = framed
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let title {
        IOSSectionTitle(title)
      }
      if framed {
        IOSCard(padding: 0) {
          VStack(alignment: .leading, spacing: 0) {
            content
          }
        }
      } else {
        content
      }
      if let footer {
        Text(footer)
          .font(AtlasTheme.font(.body, .footnote))
          .foregroundStyle(AtlasTheme.ink3)
          .padding(.horizontal, 4)
          // The hard-edged themes draw an offset shadow under the card.
          .padding(.top, framed ? (AtlasTheme.shape.cardShadowOffset?.height ?? 0) : 0)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// The rule between rows: the theme's ink in the hard-edged themes, a soft
/// hairline in the others.
private struct SettingsRule: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var inset: CGFloat = 56

  var body: some View {
    let bold = AtlasTheme.shape.hasBoldBorders
    Rectangle()
      .fill(bold ? AtlasTheme.outline : AtlasTheme.ruleSoft)
      .frame(height: bold ? 1.5 : 1)
      .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 14 : inset)
      .accessibilityHidden(true)
  }
}

/// Row icon tile in the theme's own shape and soft colour. Dropped at
/// accessibility text sizes so the title keeps the full row width.
private struct SettingsIcon: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.isEnabled) private var isEnabled
  var systemImage: String
  var tone: SettingsTone

  var body: some View {
    if !dynamicTypeSize.isAccessibilitySize {
      tile
    }
  }

  private var tile: some View {
    let shape = AtlasTheme.shape
    let outline: AnyShape =
      shape.pillControls
      ? AnyShape(Circle())
      : AnyShape(RoundedRectangle(cornerRadius: min(shape.radiusSmall, 10), style: .continuous))
    return Image(systemName: systemImage)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(isEnabled ? tone.ink : AtlasTheme.ink3)
      .frame(width: 32, height: 32)
      .background(outline.fill(isEnabled ? tone.softFill : AtlasTheme.surfaceMuted))
      .overlay {
        if shape.hasBoldBorders {
          outline.stroke(AtlasTheme.outline, lineWidth: 1.5)
        }
      }
      .accessibilityHidden(true)
  }
}

private struct SettingsChevron: View {
  var systemImage = "chevron.right"

  var body: some View {
    Image(systemName: systemImage)
      .font(.footnote.weight(.semibold))
      .foregroundStyle(AtlasTheme.ink3)
      .accessibilityHidden(true)
  }
}

/// Icon tile, title, optional one-line subtitle, and trailing accessory.
private struct SettingsRowLabel<Trailing: View>: View {
  @Environment(\.isEnabled) private var isEnabled
  var title: String
  var subtitle: String?
  var subtitleColor: Color
  var systemImage: String
  var tone: SettingsTone
  var trailing: Trailing

  init(
    title: String,
    subtitle: String? = nil,
    subtitleColor: Color = AtlasTheme.ink3,
    systemImage: String,
    tone: SettingsTone = .accent,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self.subtitle = subtitle
    self.subtitleColor = subtitleColor
    self.systemImage = systemImage
    self.tone = tone
    self.trailing = trailing()
  }

  var body: some View {
    HStack(spacing: 12) {
      SettingsIcon(systemImage: systemImage, tone: tone)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(AtlasTheme.font(.body, .body))
          .foregroundStyle(isEnabled ? AtlasTheme.ink : AtlasTheme.ink3)
        if let subtitle {
          Text(subtitle)
            .font(AtlasTheme.font(.body, .footnote))
            .foregroundStyle(subtitleColor)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .multilineTextAlignment(.leading)
      Spacer(minLength: 8)
      trailing
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .frame(minHeight: 52)
    .contentShape(Rectangle())
  }
}

/// One line of the Privacy group: icon tile and a short sentence.
private struct SettingsFactRow: View {
  var fact: SettingsFact

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      SettingsIcon(systemImage: fact.systemImage, tone: .accent)
      Text(fact.text)
        .font(AtlasTheme.font(.body, .callout))
        .foregroundStyle(AtlasTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 5)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

private struct SettingsToggleRow: View {
  var title: String
  var systemImage: String
  var hint: String
  @Binding var isOn: Bool

  var body: some View {
    Toggle(isOn: $isOn) {
      HStack(spacing: 12) {
        SettingsIcon(systemImage: systemImage, tone: .accent)
        Text(title)
          .font(AtlasTheme.font(.body, .body))
          .foregroundStyle(AtlasTheme.ink)
      }
    }
    .tint(AtlasTheme.accent)
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .frame(minHeight: 52)
    .accessibilityHint(hint)
  }
}

private struct SettingsLinkRow: View {
  var title: String
  var systemImage: String
  var destination: URL

  var body: some View {
    Link(destination: destination) {
      SettingsRowLabel(title: title, systemImage: systemImage) {
        SettingsChevron(systemImage: "arrow.up.right")
      }
    }
    .buttonStyle(SettingsRowButtonStyle())
    .accessibilityHint("Opens in your browser.")
  }
}

private struct SettingsValueRow<Accessory: View>: View {
  var label: String
  var value: String
  var isMono: Bool
  var accessory: Accessory

  init(
    label: String, value: String, isMono: Bool = false, @ViewBuilder accessory: () -> Accessory
  ) {
    self.label = label
    self.value = value
    self.isMono = isMono
    self.accessory = accessory()
  }

  private var valueFont: Font {
    isMono ? AtlasTheme.font(.mono, .callout) : AtlasTheme.font(.body, .body)
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        Text(label).foregroundStyle(AtlasTheme.ink)
        accessory
        Spacer(minLength: 12)
        Text(value).font(valueFont).foregroundStyle(AtlasTheme.ink3)
      }
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(label).foregroundStyle(AtlasTheme.ink)
          accessory
        }
        Text(value).font(valueFont).foregroundStyle(AtlasTheme.ink3)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(AtlasTheme.font(.body, .body))
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .frame(minHeight: 48)
    .accessibilityElement(children: .combine)
  }
}

extension SettingsValueRow where Accessory == EmptyView {
  fileprivate init(label: String, value: String, isMono: Bool = false) {
    self.init(label: label, value: value, isMono: isMono) { EmptyView() }
  }
}

private struct SettingsRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(configuration.isPressed ? AtlasTheme.accentSoft : Color.clear)
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
}

extension View {
  /// Full-width, 44pt-tall control label so every button in Settings meets
  /// the touch-target minimum inside the shared button styles.
  fileprivate func settingsControlLabel() -> some View {
    frame(maxWidth: .infinity, minHeight: 44)
  }

  /// A tinted panel inside a card (the restore result, the revealed code):
  /// the tone's soft fill, ink-outlined in the hard-edged themes.
  fileprivate func settingsPanel(_ tone: SettingsTone) -> some View {
    padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .atlasChrome(
        fill: tone.softFill,
        border: AtlasTheme.shape.hasBoldBorders ? AtlasTheme.outline : tone.ink.opacity(0.32),
        level: .control,
        radius: AtlasRadius.control,
        borderWidth: AtlasTheme.shape.hasBoldBorders ? AtlasTheme.shape.controlBorderWidth : 1,
        showsShadow: false
      )
  }
}
