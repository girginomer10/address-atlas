import AddressAtlasCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Exchanges

struct ExchangesView: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var provider: ExchangeProvider = .binance
  @State private var label = ""
  @State private var apiKey = ""
  @State private var secret = ""
  @State private var revealsAPIKey = false
  @State private var revealsSecret = false

  private var hasRequiredCredentialInput: Bool {
    !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    MacPage("Exchanges") {
      if state.document.exchangeConnections.isEmpty {
        MacEmptyState(
          "No exchanges yet",
          copy: "Connect a read-only API key to include exchange balances in your scans.",
          systemImage: "building.columns")
      } else {
        MacRowList(state.document.exchangeConnections) { connection in
          ExchangeRow(connection: connection)
        }
      }
      credentialCard
    }
  }

  private var credentialCard: some View {
    Surface {
      VStack(alignment: .leading, spacing: 20) {
        MacHeading("Connect an exchange")

        VStack(alignment: .leading, spacing: 8) {
          FieldLabel("Exchange")
          MacChipPicker(
            label: "Exchange", options: ExchangeProvider.allCases, selection: $provider,
            title: { $0.label })
        }

        VStack(alignment: .leading, spacing: 8) {
          FieldLabel("Name", detail: "Optional")
          TextField(provider.connectionPlaceholder, text: $label)
            .textFieldStyle(AtlasTextFieldStyle())
            .accessibilityLabel("Connection name")
        }

        AdaptiveStack(horizontalSpacing: 12, verticalSpacing: 14) {
          ExchangeCredentialField(
            title: provider.apiKeyTitle,
            placeholder: provider.apiKeyPlaceholder,
            text: $apiKey,
            isRevealed: $revealsAPIKey
          )
          ExchangeCredentialField(
            title: provider.secretTitle,
            placeholder: provider.secretPlaceholder,
            text: $secret,
            isRevealed: $revealsSecret
          )
        }

        ExchangePermissionGuide(provider: provider)
          .id(provider)
          .transition(.opacity.combined(with: .move(edge: .top)))
          .animation(
            AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
            value: provider
          )

        AdaptiveStack(horizontalSpacing: 12) {
          Button {
            saveConnection()
          } label: {
            Label("Add connection", systemImage: "lock.fill")
          }
          .buttonStyle(MacPrimaryButtonStyle())
          .disabled(!hasRequiredCredentialInput)

          Text("Keys are encrypted on this Mac before they\u{2019}re saved.")
            .font(AtlasTheme.font(.label, .caption))
            .foregroundStyle(AtlasTheme.ink3)
        }
      }
    }
    .disabled(state.vaultEditsDisabled)
  }

  private func saveConnection() {
    Task {
      if await state.saveExchangeConnection(
        provider: provider,
        label: label,
        credentials: ExchangeCredentials(
          apiKey: apiKey,
          secret: secret,
          passphrase: nil
        )
      ) {
        label = ""
        apiKey = ""
        secret = ""
        revealsAPIKey = false
        revealsSecret = false
      }
    }
  }
}

extension ExchangeProvider {
  fileprivate var systemImage: String {
    switch self {
    case .binance: "diamond.fill"
    case .coinbase: "c.circle.fill"
    case .kraken: "wave.3.right.circle.fill"
    }
  }

  fileprivate var connectionPlaceholder: String {
    switch self {
    case .binance: "Binance main account"
    case .coinbase: "Coinbase portfolio"
    case .kraken: "Kraken read-only"
    }
  }

  fileprivate var apiKeyTitle: String {
    switch self {
    case .coinbase: "CDP API key name"
    case .binance, .kraken: "API key"
    }
  }

  fileprivate var apiKeyPlaceholder: String {
    switch self {
    case .coinbase: "organizations/\u{2026}/apiKeys/\u{2026}"
    case .binance, .kraken: "Paste API key"
    }
  }

  fileprivate var secretTitle: String {
    switch self {
    case .coinbase: "ES256 private key"
    case .binance: "Secret key"
    case .kraken: "Private key"
    }
  }

  fileprivate var secretPlaceholder: String {
    switch self {
    case .coinbase: "Paste private key"
    case .binance: "Paste secret key"
    case .kraken: "Paste private key"
    }
  }
}

private struct ExchangeCredentialField: View {
  var title: String
  var placeholder: String
  @Binding var text: String
  @Binding var isRevealed: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      FieldLabel(title)
      HStack(spacing: 8) {
        Group {
          if isRevealed {
            TextField(placeholder, text: $text)
          } else {
            SecureField(placeholder, text: $text)
          }
        }
        .textFieldStyle(AtlasTextFieldStyle())
        .accessibilityLabel(title)

        Button {
          isRevealed.toggle()
        } label: {
          Image(systemName: isRevealed ? "eye.slash" : "eye")
        }
        .buttonStyle(IconButtonStyle())
        .accessibilityLabel(isRevealed ? "Hide \(title)" : "Show \(title)")
      }
    }
    .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
  }
}

private struct ExchangePermissionGuide: View {
  var provider: ExchangeProvider

  var body: some View {
    InfoCallout(
      title: title,
      copy: copy,
      tone: provider == .binance ? .success : .warning
    )
  }

  private var title: String {
    switch provider {
    case .binance: "Permissions are checked before saving"
    case .coinbase: "Create a view-only key in Coinbase"
    case .kraken: "Enable Query Funds only"
    }
  }

  private var copy: String {
    switch provider {
    case .coinbase:
      "Use a CDP key name and its ES256 private key. Address Atlas can\u{2019}t check the key\u{2019}s scope, so keep trading and transfer permissions off. Escaped \\n line breaks are accepted."
    case .kraken:
      "Use a different key on each Mac, with trading, deposits, withdrawals and account changes off. Address Atlas can\u{2019}t check Kraken scope."
    case .binance:
      "Keys with trading, transfer, margin, futures, options or withdrawal permissions are refused. Only balance and read access is accepted."
    }
  }
}

struct ExchangeRow: View {
  @EnvironmentObject private var state: AppState
  @State private var confirmingRemoval = false
  var connection: ExchangeConnectionRecord

  private var hasInvalidKrakenBinding: Bool {
    connection.provider == .kraken
      && connection.krakenDeviceIdentifier.flatMap(KrakenDeviceIdentity.normalizedIdentifier) == nil
  }

  private var statusLabel: String {
    switch connection.status {
    case .ok: "Ready"
    case .empty: "Not scanned"
    case .failed: "Needs attention"
    }
  }

  private var statusColor: Color {
    switch connection.status {
    case .ok: AtlasTheme.gain
    case .empty: AtlasTheme.ink3
    case .failed: AtlasTheme.loss
    }
  }

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: connection.provider.systemImage)
        .font(.body.weight(.semibold))
        .foregroundStyle(AtlasTheme.accent)
        .frame(width: 38, height: 38)
        .background(AtlasTheme.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(connection.label)
            .font(AtlasTheme.font(.body, .body, weight: .semibold))
          Text(connection.provider.label)
            .font(AtlasTheme.font(.label, .caption))
            .foregroundStyle(AtlasTheme.ink3)
        }
        if connection.lastError?.isEmpty == false || hasInvalidKrakenBinding {
          Text(
            connection.lastError?.isEmpty == false
              ? connection.lastError ?? ""
              : "Legacy Kraken key: add a new read-only key for this Mac before scanning."
          )
          .font(AtlasTheme.font(.body, .callout))
          .foregroundStyle(AtlasTheme.loss)
          .lineLimit(2)
        } else if let lastSync = connection.lastSyncAt {
          Text("Last read \(AtlasFormatting.dateTime(lastSync))")
            .font(AtlasTheme.font(.label, .caption))
            .foregroundStyle(AtlasTheme.ink3)
        } else {
          Text("Not scanned yet")
            .font(AtlasTheme.font(.label, .caption))
            .foregroundStyle(AtlasTheme.ink3)
        }
      }
      Spacer()
      MacBadge(
        connection.credentialScopeAssurance == .verifiedReadOnly
          ? "Read-only verified"
          : "Confirm scope",
        color: connection.credentialScopeAssurance == .verifiedReadOnly
          ? AtlasTheme.gain
          : AtlasTheme.warning
      )
      MacBadge(statusLabel, color: statusColor)
      Button(role: .destructive) {
        confirmingRemoval = true
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(IconButtonStyle())
      .accessibilityLabel(
        "Remove exchange connection \(AtlasAccessibility.exchangeIdentity(connection))"
      )
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 68)
    .confirmationDialog(
      "Remove \(AtlasAccessibility.exchangeIdentity(connection))?",
      isPresented: $confirmingRemoval,
      titleVisibility: .visible
    ) {
      Button("Remove connection", role: .destructive) {
        Task { await state.removeExchangeConnection(id: connection.id) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "The encrypted API credentials are removed from this Mac, including its earlier local copy. An older encrypted copy you uploaded may still contain them until you save a new one."
      )
    }
    .disabled(state.vaultEditsDisabled)
  }
}

// MARK: - Export

struct ExportView: View {
  static let shareSaferExplanation = ExportCopy.shareSaferExplanation
  static let fullIdentifyingExplanation = ExportCopy.fullIdentifyingExplanation

  @EnvironmentObject private var state: AppState
  @State private var exportedPreview = ""
  @State private var showFullIdentifyingExports = false

  var body: some View {
    MacPage("Export") {
      Surface(style: .accent) {
        VStack(alignment: .leading, spacing: 16) {
          MacHeading("Share-safer summary")
          InfoCallout(
            title: "Safer to share, not anonymous",
            copy: "\(ShareSafePortfolioReport.privacyNotice) \(Self.shareSaferExplanation)",
            tone: .info
          )
          AdaptiveStack {
            Button {
              save(.shareSafeCSV(state.document))
            } label: {
              Label("Save CSV", systemImage: "arrow.down.doc")
            }
            .buttonStyle(MacPrimaryButtonStyle())
            Button {
              generatePreview(for: .shareSafeCSV(state.document))
            } label: {
              Label("Preview CSV", systemImage: "eye")
            }
            .buttonStyle(MacSecondaryButtonStyle())
            Button {
              save(.shareSafeJSON(state.document))
            } label: {
              Label("Save JSON", systemImage: "arrow.down.doc")
            }
            .buttonStyle(MacSecondaryButtonStyle())
            Button {
              generatePreview(for: .shareSafeJSON(state.document))
            } label: {
              Label("Preview JSON", systemImage: "eye")
            }
            .buttonStyle(MacSecondaryButtonStyle())
          }
          .disabled(state.isExportOperationInProgress)
          if state.isExportOperationInProgress {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Preparing export")
          }
        }
      }

      Surface(style: .danger) {
        DisclosureGroup(isExpanded: $showFullIdentifyingExports) {
          VStack(alignment: .leading, spacing: 14) {
            InfoCallout(
              title: "These reports identify you",
              copy: Self.fullIdentifyingExplanation,
              tone: .danger
            )
            AdaptiveStack {
              Button("Preview identifying CSV") {
                guard let payload = csvPayloadIncludingDrafts() else { return }
                generatePreview(for: payload)
              }
              .buttonStyle(MacSecondaryButtonStyle())
              Button("Save identifying CSV") {
                guard let payload = csvPayloadIncludingDrafts() else { return }
                save(payload)
              }
              .buttonStyle(MacSecondaryButtonStyle())
              Button("Preview identifying JSON") {
                guard let payload = jsonPayloadIncludingDrafts() else { return }
                generatePreview(for: payload)
              }
              .buttonStyle(MacSecondaryButtonStyle())
              Button("Save identifying JSON") {
                guard let payload = jsonPayloadIncludingDrafts() else { return }
                save(payload)
              }
              .buttonStyle(MacSecondaryButtonStyle())
            }
            .disabled(state.isExportOperationInProgress)
          }
          .padding(.top, 12)
        } label: {
          PanelHeader(
            title: "Full reports",
            subtitle: "Show your addresses and exact balances",
            systemImage: "exclamationmark.triangle.fill",
            tint: AtlasTheme.loss
          )
        }
        .accessibilityIdentifier("full-identifying-export-disclosure")
      }

      ExportPreview(exportedPreview: exportedPreview)
    }
  }

  private func generatePreview(for payload: ExportPayload) {
    guard state.beginExportOperation() else { return }
    state.error = ""
    Task { @MainActor in
      defer { state.finishExportOperation() }
      do {
        exportedPreview = try await Task.detached(priority: .userInitiated) {
          try ExportPipeline.renderPreview(for: payload)
        }.value
      } catch {
        state.presentUserFacingError(error)
      }
    }
  }

  private func csvPayloadIncludingDrafts() -> ExportPayload? {
    payloadIncludingDrafts {
      .csv(try state.holdingsForExportIncludingWalletLabelDrafts())
    }
  }

  private func jsonPayloadIncludingDrafts() -> ExportPayload? {
    payloadIncludingDrafts {
      .json(try state.documentForExportIncludingWalletLabelDrafts())
    }
  }

  private func payloadIncludingDrafts(
    _ makePayload: () throws -> ExportPayload
  ) -> ExportPayload? {
    do {
      return try makePayload()
    } catch WalletLabelDraftError.invalidLabel {
      state.notice = ""
      state.error = "Wallet names must be 1 to 80 characters before you export."
      return nil
    } catch {
      state.presentUserFacingError(error)
      return nil
    }
  }

  private func save(_ payload: ExportPayload) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = payload.suggestedName
    panel.allowedContentTypes = [payload.contentType]
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let url = panel.url {
      guard state.beginExportOperation() else { return }
      let isAccessing = url.startAccessingSecurityScopedResource()
      state.error = ""
      Task { @MainActor in
        defer {
          state.finishExportOperation()
          if isAccessing {
            url.stopAccessingSecurityScopedResource()
          }
        }
        do {
          exportedPreview = try await Task.detached(priority: .userInitiated) {
            try ExportPipeline.write(payload, to: url)
          }.value
          state.notice = "\(payload.displayName) saved."
          state.error = ""
        } catch {
          state.presentUserFacingError(error)
        }
      }
    }
  }
}

struct ExportPreview: View {
  static let contentAccessibilityIdentifier = "export-preview-content"

  var exportedPreview: String

  var displayedText: String {
    exportedPreview.isEmpty
      ? "Preview a report to see exactly what it contains before you save it. The share-safer summary lowers exposure but isn\u{2019}t anonymous."
      : exportedPreview
  }

  var accessibilityModel: ExportPreviewAccessibilityModel {
    ExportPreviewAccessibilityModel(text: displayedText)
  }

  var body: some View {
    let model = accessibilityModel

    Surface {
      VStack(alignment: .leading, spacing: 10) {
        MacHeading("Preview")
        Text(model.spokenSummary)
          .font(AtlasTheme.font(.label, .caption))
          .foregroundStyle(AtlasTheme.ink2)
          .accessibilityLabel(model.accessibilitySummaryLabel)
        Table(model.rows) {
          TableColumn("Location") { row in
            Text(row.locationLabel)
              .font(.caption.monospacedDigit())
              .accessibilityHidden(true)
          }
          TableColumn("Preview content") { row in
            Text(row.visibleContent)
              .font(.caption.monospaced())
              .textSelection(.enabled)
              .accessibilityLabel(row.locationLabel)
              .accessibilityValue(row.accessibilityValue)
              .accessibilityIdentifier(row.accessibilityIdentifier)
          }
        }
        .accessibilityLabel("Read-only export preview table")
        .accessibilityHint(ExportPreviewAccessibilityModel.navigationHint)
        .accessibilityIdentifier(Self.contentAccessibilityIdentifier)
        .frame(minHeight: 280, maxHeight: 520)
      }
      .accessibilityElement(children: .contain)
    }
  }
}

// MARK: - Settings

struct SettingsView: View {
  @EnvironmentObject private var state: AppState
  @State private var recoveryCode = ""
  @State private var restoreCode = ""

  var body: some View {
    MacPage("Settings") {
      Surface {
        AtlasThemeSection()
      }

      portfolioSection

      SyncView()

      MacPrivacySection()

      recoverySection

      Surface(style: .subtle) {
        PrivacySafeDiagnosticsControls()
      }
    }
  }

  // MARK: Portfolio

  private var portfolioSection: some View {
    Surface {
      VStack(alignment: .leading, spacing: 18) {
        MacHeading("Portfolio")
        PreferenceToggleRow(
          title: "Refresh every 15 minutes",
          copy: "While Address Atlas is open and unlocked.",
          systemImage: "arrow.clockwise",
          isOn: Binding(
            get: {
              state.document.preferences.autoRefresh
            },
            set: {
              let value = $0
              Task { await state.setAutoRefresh(value) }
            })
        )
        Divider().overlay(AtlasTheme.ruleSoft)
        PreferenceToggleRow(
          title: "Hide small balances",
          copy: "Keeps them out of lists and charts. The total still counts them.",
          systemImage: "line.3.horizontal.decrease.circle",
          isOn: Binding(
            get: {
              state.document.preferences.hideDust
            },
            set: {
              let value = $0
              Task { await state.setHideDust(value) }
            })
        )
        VStack(alignment: .leading, spacing: 7) {
          FieldLabel("Small balance limit", detail: "USD")
          TextField(
            "0.00",
            value: Binding(
              get: {
                state.document.preferences.dustThreshold
              },
              set: {
                let value = $0
                Task { await state.setDustThreshold(value) }
              }), format: .number
          )
          .textFieldStyle(AtlasTextFieldStyle())
          .frame(maxWidth: 240)
          .accessibilityLabel("Small balance limit in US dollars")
        }
      }
    }
    .disabled(state.vaultEditsDisabled)
  }

  // MARK: Recovery

  private var recoverySection: some View {
    Surface(style: .warning) {
      VStack(alignment: .leading, spacing: 16) {
        MacHeading("Recovery kit")
        Text(
          "A recovery file and a code you keep apart from it can restore this Mac\u{2019}s encryption key."
        )
        .font(AtlasTheme.font(.body, .callout))
        .foregroundStyle(AtlasTheme.ink2)
        Button {
          exportRecoveryKit()
        } label: {
          Label("Export recovery kit", systemImage: "arrow.down.doc")
        }
        .buttonStyle(MacPrimaryButtonStyle())
        VStack(alignment: .leading, spacing: 8) {
          FieldLabel("Restore from a recovery file")
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
              restoreCodeField
              restoreFileButton
            }
            VStack(alignment: .leading, spacing: 10) {
              restoreCodeField
              restoreFileButton
            }
          }
        }
        if !recoveryCode.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("Store this code apart from the recovery file")
              .font(AtlasTheme.font(.body, .callout, weight: .semibold))
            Text(recoveryCode)
              .font(AtlasTheme.font(.mono, .callout))
              .textSelection(.enabled)
              .padding(14)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(AtlasTheme.surface)
              .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
              .overlay {
                RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
                  .stroke(AtlasTheme.outline, lineWidth: 1)
              }
          }
        }
      }
    }
  }

  private var restoreCodeField: some View {
    SecureField("Recovery code", text: $restoreCode)
      .textFieldStyle(AtlasTextFieldStyle())
      .accessibilityLabel("Recovery code for restore")
  }

  private var restoreFileButton: some View {
    Button {
      restoreRecoveryKit()
    } label: {
      Label("Choose recovery file", systemImage: "folder")
    }
    .buttonStyle(MacSecondaryButtonStyle())
    .disabled(
      state.vaultEditsDisabled
        || restoreCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    )
  }

  private func exportRecoveryKit() {
    let panel = NSOpenPanel()
    panel.title = "Export Recovery Kit"
    panel.message = "Choose a folder for a uniquely named encrypted recovery file."
    panel.prompt = "Export Here"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let directory = panel.url {
      let isAccessing = directory.startAccessingSecurityScopedResource()
      defer {
        if isAccessing {
          directory.stopAccessingSecurityScopedResource()
        }
      }
      do {
        let filename = "address-atlas-\(Self.recoveryExportTimestamp()).atlas-recovery"
        let destination = directory.appending(path: filename)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
          state.error = "A recovery file with this timestamp already exists. Wait a second and try again."
          return
        }
        recoveryCode = try state.exportRecoveryKit(to: destination)
        state.notice = "Recovery kit saved as \(filename)."
      } catch {
        state.presentUserFacingError(error)
      }
    }
  }

  private func restoreRecoveryKit() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "atlas-recovery") ?? .data]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    if panel.runModal() == .OK, let url = panel.url {
      let isAccessing = url.startAccessingSecurityScopedResource()
      Task {
        defer {
          if isAccessing {
            url.stopAccessingSecurityScopedResource()
          }
        }
        await state.restoreRecoveryKit(from: url, recoveryCode: restoreCode)
      }
    }
  }

  private static func recoveryExportTimestamp(now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter.string(from: now)
  }
}

/// What stays on this Mac, what leaves it, and what is never asked for: the one
/// place the app explains privacy. Each fact is stated once, here.
struct MacPrivacySection: View {
  var body: some View {
    Surface {
      VStack(alignment: .leading, spacing: 16) {
        MacHeading("Privacy")
        VStack(alignment: .leading, spacing: 12) {
          fact(
            "Stays on this Mac",
            "Your wallets, balances, scan history and exchange keys, encrypted with a key in Keychain."
          )
          fact(
            "Goes to providers",
            "Public wallet addresses go to blockchain data providers and price lookups go to CoinGecko. Exchange requests go straight to the exchange. These services can see your IP address."
          )
          fact(
            "Never asked for",
            "Private keys or seed phrases. Address Atlas is read-only and can\u{2019}t sign or move funds."
          )
        }
        AdaptiveStack {
          Link(destination: AppState.privacyPolicyURL) {
            Label("Privacy policy", systemImage: "lock.doc")
          }
          .buttonStyle(MacSecondaryButtonStyle())
          Link(destination: AppState.termsOfUseURL) {
            Label("Terms of use", systemImage: "doc.text")
          }
          .buttonStyle(MacSecondaryButtonStyle())
          Link(destination: AppState.supportURL) {
            Label("Support", systemImage: "questionmark.circle")
          }
          .buttonStyle(MacSecondaryButtonStyle())
          Link(destination: AppState.coinGeckoAttributionURL) {
            Label("Prices by CoinGecko", systemImage: "chart.line.uptrend.xyaxis")
          }
          .buttonStyle(MacSecondaryButtonStyle())
        }
      }
    }
  }

  private func fact(_ title: String, _ copy: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(AtlasTheme.font(.body, .callout, weight: .semibold))
        .foregroundStyle(AtlasTheme.ink)
      Text(copy)
        .font(AtlasTheme.font(.body, .callout))
        .foregroundStyle(AtlasTheme.ink2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct PreferenceToggleRow: View {
  var title: String
  var copy: String
  var systemImage: String
  @Binding var isOn: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      Image(systemName: systemImage)
        .font(.body.weight(.semibold))
        .foregroundStyle(AtlasTheme.accent)
        .frame(width: 36, height: 36)
        .background(AtlasTheme.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(AtlasTheme.font(.body, .callout, weight: .semibold))
        Text(copy)
          .font(AtlasTheme.font(.label, .caption))
          .foregroundStyle(AtlasTheme.ink3)
      }
      .accessibilityHidden(true)
      Spacer(minLength: 16)
      Toggle(title, isOn: $isOn)
        .labelsHidden()
        .accessibilityLabel(title)
        .accessibilityHint(copy)
    }
  }
}
