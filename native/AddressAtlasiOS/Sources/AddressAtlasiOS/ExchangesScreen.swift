import AddressAtlasCore
import SwiftUI

/// Read-only exchange connections, list first. Connecting happens in a sheet
/// opened from the toolbar "+", the empty state, or another screen through
/// `IOSNavigationModel` (`.connectExchange`). The sheet keeps the macOS flow:
/// provider-specific guidance, the scope check inside
/// `saveExchangeConnection`, and masked credentials that are re-hidden when
/// the app leaves the foreground and discarded when the sheet closes.
struct ExchangesScreen: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showsConnectSheet = false
  @State private var detailConnectionID: ExchangeDetailRequest?
  @State private var pendingRemoval: ExchangeConnectionRecord?

  private var connections: [ExchangeConnectionRecord] {
    state.document.exchangeConnections
  }

  var body: some View {
    List {
      SourcesPersistentStatusSection()

      if connections.isEmpty {
        Section {
          SourcesEmptyState(
            systemImage: "building.columns",
            title: "No exchanges connected",
            copy: "Add a read-only API key to include exchange balances.",
            actionTitle: "Connect an exchange",
            action: openConnectSheet
          )
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
      } else {
        Section {
          ForEach(connections) { connection in
            connectionRow(connection)
          }
        } footer: {
          Text("Read-only keys · encrypted on this device")
            .font(.footnote)
            .foregroundStyle(AtlasTheme.ink3)
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(AtlasTheme.canvas)
    .animation(
      AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
      value: connections.map(\.id)
    )
    .navigationTitle("Exchanges")
    .navigationBarTitleDisplayMode(.large)
    .toolbarBackground(AtlasTheme.canvas, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(action: openConnectSheet) {
          Image(systemName: "plus")
        }
        .accessibilityLabel("Connect exchange")
        .accessibilityHint("Opens a form to add a read-only API key.")
      }
    }
    .sheet(isPresented: $showsConnectSheet) {
      ConnectExchangeSheet()
    }
    .sheet(item: $detailConnectionID) { request in
      ExchangeDetailSheet(connectionID: request.id)
    }
    .confirmationDialog(
      pendingRemoval.map { "Remove \($0.label)?" } ?? "Remove connection?",
      isPresented: removalBinding,
      titleVisibility: .visible,
      presenting: pendingRemoval
    ) { connection in
      Button("Remove connection", role: .destructive) {
        Task { await state.removeExchangeConnection(id: connection.id) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text(ExchangePresentation.removalMessage)
    }
    .onAppear(perform: consumePendingAction)
    .onChange(of: navigation.pendingAction) { _, _ in
      consumePendingAction()
    }
  }

  private func connectionRow(_ connection: ExchangeConnectionRecord) -> some View {
    Button {
      detailConnectionID = ExchangeDetailRequest(id: connection.id)
    } label: {
      ExchangeRowLabel(connection: connection)
    }
    .listRowBackground(AtlasTheme.surface)
    .accessibilityLabel(ExchangePresentation.rowAccessibilityLabel(connection))
    .accessibilityHint("Opens the connection details.")
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button {
        pendingRemoval = connection
      } label: {
        Label("Delete", systemImage: "trash")
      }
      .tint(AtlasTheme.loss)
      .disabled(state.vaultEditsDisabled)
      .accessibilityLabel(
        "Remove exchange connection \(AtlasAccessibility.exchangeIdentity(connection))")
    }
    .contextMenu {
      Button {
        detailConnectionID = ExchangeDetailRequest(id: connection.id)
      } label: {
        Label("Details", systemImage: "info.circle")
      }
      Button(role: .destructive) {
        pendingRemoval = connection
      } label: {
        Label("Remove connection", systemImage: "trash")
      }
      .disabled(state.vaultEditsDisabled)
    }
  }

  private var removalBinding: Binding<Bool> {
    Binding(
      get: { pendingRemoval != nil },
      set: { if !$0 { pendingRemoval = nil } }
    )
  }

  private func openConnectSheet() {
    showsConnectSheet = true
  }

  private func consumePendingAction() {
    if navigation.consume(.connectExchange) {
      showsConnectSheet = true
    }
  }
}

private struct ExchangeDetailRequest: Identifiable {
  var id: UUID
}

// MARK: - Provider copy

extension ExchangeProvider {
  /// Hue for the provider monogram; a neutral identity color, not a logo.
  fileprivate var exchangesHue: Double {
    switch self {
    case .binance: 0.1
    case .coinbase: 0.6
    case .kraken: 0.74
    }
  }

  fileprivate var exchangesConnectionPlaceholder: String {
    switch self {
    case .binance: "Binance main account"
    case .coinbase: "Coinbase portfolio"
    case .kraken: "Kraken read-only"
    }
  }

  fileprivate var exchangesAPIKeyTitle: String {
    switch self {
    case .coinbase: "CDP API key name"
    case .binance, .kraken: "API key"
    }
  }

  fileprivate var exchangesAPIKeyPlaceholder: String {
    switch self {
    case .coinbase: "organizations/…/apiKeys/…"
    case .binance, .kraken: "Paste API key"
    }
  }

  fileprivate var exchangesSecretTitle: String {
    switch self {
    case .coinbase: "ES256 private key"
    case .binance: "Secret key"
    case .kraken: "Private key"
    }
  }

  fileprivate var exchangesSecretPlaceholder: String {
    switch self {
    case .coinbase: "Paste private key"
    case .binance: "Paste secret key"
    case .kraken: "Paste private key"
    }
  }

  /// Whether `saveExchangeConnection` can verify the key's scope itself.
  fileprivate var exchangesVerifiesScope: Bool {
    self == .binance
  }

  /// One line under the fields: what the scope check does for this provider.
  fileprivate var exchangesScopeLine: String {
    switch self {
    case .binance:
      "Only read permissions are accepted. Keys with trading, transfer, or withdrawal rights are refused."
    case .coinbase:
      "Use View permission only. Coinbase scope can't be checked automatically."
    case .kraken:
      "Enable Query Funds only. Kraken scope can't be checked automatically."
    }
  }

  /// Short "create a read-only key" checklist for the provider.
  fileprivate var exchangesSetupSteps: [String] {
    switch self {
    case .binance:
      [
        "In Binance, open API Management and create a system-generated key.",
        "Leave only Enable Reading on. Keep trading, transfers, margin, futures, and withdrawals off.",
        "Copy the API key and secret key here.",
      ]
    case .coinbase:
      [
        "In the Coinbase Developer Platform, create a Secret API key with the ECDSA (ES256) algorithm.",
        "Grant View permission only. Keep Trade and Transfer off.",
        "Copy the key name (organizations/…/apiKeys/…) and the private key. Escaped \\n line breaks are accepted.",
      ]
    case .kraken:
      [
        "In Kraken, open the API settings and create a new key just for this device.",
        "Enable Query Funds only. Keep trading, deposits, withdrawals, and account changes off.",
        "Copy the API key and private key here.",
      ]
    }
  }
}

private enum ExchangePresentation {
  static let removalMessage =
    "The encrypted credentials are removed from this device and its automatic rollback point. An earlier iCloud copy may still contain them until you save the updated portfolio to iCloud or delete that copy."

  static func hasInvalidKrakenBinding(_ connection: ExchangeConnectionRecord) -> Bool {
    connection.provider == .kraken
      && connection.krakenDeviceIdentifier.flatMap(KrakenDeviceIdentity.normalizedIdentifier)
        == nil
  }

  static func isScopeVerified(_ connection: ExchangeConnectionRecord) -> Bool {
    connection.credentialScopeAssurance == .verifiedReadOnly
  }

  static func needsAttention(_ connection: ExchangeConnectionRecord) -> Bool {
    connection.lastError?.isEmpty == false || hasInvalidKrakenBinding(connection)
      || connection.status == .failed
  }

  static func statusLabel(_ connection: ExchangeConnectionRecord) -> String {
    if hasInvalidKrakenBinding(connection) { return "Needs a new key" }
    switch connection.status {
    case .ok: return "Ready"
    case .empty: return "Not scanned yet"
    case .failed: return "Needs attention"
    }
  }

  static func statusColor(_ connection: ExchangeConnectionRecord) -> Color {
    if needsAttention(connection) { return AtlasTheme.loss }
    switch connection.status {
    case .ok: return AtlasTheme.gain
    case .empty, .failed: return AtlasTheme.ink3
    }
  }

  /// Secondary row line: the latest outcome in a few words.
  static func summary(_ connection: ExchangeConnectionRecord) -> String {
    if needsAttention(connection) { return statusLabel(connection) }
    if let lastSync = connection.lastSyncAt {
      return "Updated \(AtlasFormatting.dateTime(lastSync))"
    }
    return statusLabel(connection)
  }

  static func rowAccessibilityLabel(_ connection: ExchangeConnectionRecord) -> String {
    var parts = [connection.label, connection.provider.label, summary(connection)]
    if !isScopeVerified(connection) { parts.append("scope not verified") }
    return parts.joined(separator: ", ")
  }
}

/// Colored rounded-square initial for a provider (no third-party logos).
private struct ProviderMonogram: View {
  @Environment(\.colorScheme) private var colorScheme
  var provider: ExchangeProvider
  var size: CGFloat = 40

  var body: some View {
    let hue = provider.exchangesHue
    Text(String(provider.label.prefix(1)))
      .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
      .foregroundStyle(
        Color(hue: hue, saturation: 0.75, brightness: colorScheme == .dark ? 0.95 : 0.6)
      )
      .frame(width: size, height: size)
      .background(
        Color(hue: hue, saturation: 0.6, brightness: 0.88)
          .opacity(colorScheme == .dark ? 0.24 : 0.18)
      )
      .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
      .accessibilityHidden(true)
  }
}

private struct ExchangeRowLabel: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var connection: ExchangeConnectionRecord

  var body: some View {
    HStack(spacing: 12) {
      if !dynamicTypeSize.isAccessibilitySize {
        ProviderMonogram(provider: connection.provider)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(connection.label)
          .font(.body.weight(.semibold))
          .foregroundStyle(AtlasTheme.ink)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
        HStack(spacing: 6) {
          Circle()
            .fill(ExchangePresentation.statusColor(connection))
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
          Text(ExchangePresentation.summary(connection))
            .font(.subheadline)
            .foregroundStyle(
              ExchangePresentation.needsAttention(connection) ? AtlasTheme.loss : AtlasTheme.ink3
            )
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
        }
      }
      Spacer(minLength: 8)
      if !ExchangePresentation.isScopeVerified(connection) {
        Image(systemName: "exclamationmark.shield")
          .foregroundStyle(AtlasTheme.warning)
          .accessibilityHidden(true)
      }
      Image(systemName: "chevron.right")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(AtlasTheme.ink3)
        .accessibilityHidden(true)
    }
    .padding(.vertical, 4)
    .frame(minHeight: 52)
    .contentShape(Rectangle())
  }
}

// MARK: - Connect sheet

private enum ExchangesFormField: Hashable {
  case label
  case apiKey
  case secret
}

private struct ConnectExchangeSheet: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var provider: ExchangeProvider = .binance
  @State private var label = ""
  @State private var apiKey = ""
  @State private var secret = ""
  @State private var revealsAPIKey = false
  @State private var revealsSecret = false
  @FocusState private var focusedField: ExchangesFormField?

  private var connections: [ExchangeConnectionRecord] {
    state.document.exchangeConnections
  }

  private var hasRequiredCredentialInput: Bool {
    !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var isAtConnectionLimit: Bool {
    connections.count >= AppState.maximumExchangeConnections
  }

  private var canSubmit: Bool {
    hasRequiredCredentialInput && !isAtConnectionLimit
      && !state.isValidatingExchangeCredentials && !state.vaultEditsDisabled
  }

  var body: some View {
    IOSFormSheet(title: "Connect exchange") {
      ExchangeProviderPicker(selection: $provider)
        .disabled(state.isValidatingExchangeCredentials)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Connect", action: saveConnection)
              .disabled(!canSubmit)
          }
        }

      LearnMoreDisclosure("Create a read-only key", systemImage: "checklist") {
        ForEach(Array(provider.exchangesSetupSteps.enumerated()), id: \.offset) { index, step in
          HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
              .font(.caption.monospacedDigit().weight(.bold))
              .foregroundStyle(AtlasTheme.accent)
              .frame(width: 22, height: 22)
              .background(AtlasTheme.accent.opacity(0.12))
              .clipShape(Circle())
              .accessibilityHidden(true)
            Text(step)
              .fixedSize(horizontal: false, vertical: true)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Step \(index + 1): \(step)")
        }
        IOSFactRow(
          systemImage: "lock.shield",
          title: "What's stored",
          copy:
            "Credentials are encrypted with a dedicated key on this device. Balance requests go straight from this device to \(provider.label)."
        )
      }

      if provider == .kraken {
        Label(
          "Use a separate key on every device. A Kraken key saved here works only on this device.",
          systemImage: "iphone"
        )
        .font(.footnote)
        .foregroundStyle(AtlasTheme.warning)
        .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 8) {
          FieldLabel("Name", detail: "Optional")
          TextField(provider.exchangesConnectionPlaceholder, text: $label)
            .textFieldStyle(AtlasTextFieldStyle())
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .submitLabel(.next)
            .focused($focusedField, equals: .label)
            .onSubmit { focusedField = .apiKey }
            .accessibilityLabel("Connection name")
        }

        ExchangesSecretField(
          title: provider.exchangesAPIKeyTitle,
          placeholder: provider.exchangesAPIKeyPlaceholder,
          text: $apiKey,
          isRevealed: $revealsAPIKey,
          field: .apiKey,
          focusedField: $focusedField,
          submitLabel: .next
        ) {
          focusedField = .secret
        }

        ExchangesSecretField(
          title: provider.exchangesSecretTitle,
          placeholder: provider.exchangesSecretPlaceholder,
          text: $secret,
          isRevealed: $revealsSecret,
          field: .secret,
          focusedField: $focusedField,
          submitLabel: .done
        ) {
          if canSubmit {
            saveConnection()
          } else {
            focusedField = nil
          }
        }
      }
      .disabled(state.isValidatingExchangeCredentials)

      Label(
        provider.exchangesScopeLine,
        systemImage: provider.exchangesVerifiesScope ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
      )
      .font(.footnote)
      .foregroundStyle(provider.exchangesVerifiesScope ? AtlasTheme.ink3 : AtlasTheme.warning)
      .fixedSize(horizontal: false, vertical: true)

      if isAtConnectionLimit {
        InfoCallout(
          title: "Connection limit reached",
          copy:
            "A vault can hold \(AppState.maximumExchangeConnections) exchange connections. Remove one first.",
          tone: .warning
        )
      }

      IOSInlineError()

      Button(action: saveConnection) {
        Group {
          if state.isValidatingExchangeCredentials {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
                .tint(AtlasTheme.ink3)
              Text("Checking key permissions…")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Checking API key permissions")
          } else {
            Label("Connect \(provider.label)", systemImage: "lock.fill")
          }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(AtlasPrimaryButtonStyle())
      .disabled(!canSubmit)
    }
    .animation(
      AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
      value: provider
    )
    // The scope check cannot be cancelled; keep the sheet (and its error
    // line) in place until it finishes.
    .interactiveDismissDisabled(state.isValidatingExchangeCredentials)
    .onAppear {
      state.error = ""
    }
    .onChange(of: provider) { _, _ in
      if !state.error.isEmpty { state.error = "" }
    }
    .onChange(of: apiKey) { _, _ in
      if !state.error.isEmpty { state.error = "" }
    }
    .onChange(of: secret) { _, _ in
      if !state.error.isEmpty { state.error = "" }
    }
    .onChange(of: label) { _, _ in
      if !state.error.isEmpty { state.error = "" }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active {
        revealsAPIKey = false
        revealsSecret = false
      }
    }
    .onDisappear {
      clearCredentials()
      if !state.isValidatingExchangeCredentials { state.error = "" }
    }
  }

  private func clearCredentials() {
    label = ""
    apiKey = ""
    secret = ""
    revealsAPIKey = false
    revealsSecret = false
  }

  private func saveConnection() {
    guard canSubmit else { return }
    focusedField = nil
    state.error = ""
    let provider = provider
    let label = label
    let credentials = ExchangeCredentials(apiKey: apiKey, secret: secret, passphrase: nil)
    Task {
      if await state.saveExchangeConnection(
        provider: provider,
        label: label,
        credentials: credentials
      ) {
        clearCredentials()
        if state.notice.isEmpty {
          state.notice = "\(provider.label) connected."
        }
        dismiss()
      }
    }
  }
}

/// Three provider cards; falls back to a vertical list at accessibility sizes.
private struct ExchangeProviderPicker: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Binding var selection: ExchangeProvider

  var body: some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
    layout {
      ForEach(ExchangeProvider.allCases, id: \.self) { provider in
        card(provider)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Exchange provider")
  }

  private func card(_ provider: ExchangeProvider) -> some View {
    let isSelected = selection == provider
    return Button {
      selection = provider
    } label: {
      Group {
        if dynamicTypeSize.isAccessibilitySize {
          HStack(spacing: 12) {
            ProviderMonogram(provider: provider, size: 36)
            Text(provider.label)
              .font(.callout.weight(.semibold))
            Spacer(minLength: 0)
            if isSelected {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AtlasTheme.accent)
            }
          }
          .padding(.horizontal, 12)
        } else {
          VStack(spacing: 8) {
            ProviderMonogram(provider: provider, size: 36)
            Text(provider.label)
              .font(.callout.weight(.semibold))
              .lineLimit(1)
              .minimumScaleFactor(0.8)
          }
        }
      }
      .foregroundStyle(AtlasTheme.ink)
      .frame(maxWidth: .infinity, minHeight: 44)
      .padding(.vertical, 12)
      .background(isSelected ? AtlasTheme.accent.opacity(0.08) : AtlasTheme.surface)
      .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
          .stroke(
            isSelected ? AtlasTheme.accent : AtlasTheme.ruleSoft,
            lineWidth: isSelected ? 2 : 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(provider.label)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}

/// Masked credential entry with a reveal toggle. Identifier hygiene applies to
/// both the masked and revealed variants: no autocorrect, no capitalization,
/// and the one-time-code content type so password AutoFill never offers to
/// save or fill exchange secrets.
private struct ExchangesSecretField: View {
  var title: String
  var placeholder: String
  @Binding var text: String
  @Binding var isRevealed: Bool
  var field: ExchangesFormField
  var focusedField: FocusState<ExchangesFormField?>.Binding
  var submitLabel: SubmitLabel
  var onSubmit: () -> Void

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
        .atlasIdentifierInput()
        .focused(focusedField, equals: field)
        .submitLabel(submitLabel)
        .onSubmit(onSubmit)
        .accessibilityLabel(title)

        Button {
          isRevealed.toggle()
        } label: {
          Image(systemName: isRevealed ? "eye.slash" : "eye")
        }
        .buttonStyle(ExchangesTouchIconButtonStyle())
        .accessibilityLabel(isRevealed ? "Hide \(title)" : "Show \(title)")
        .accessibilityHint(
          isRevealed ? "Masks the value again." : "Shows the pasted value on screen.")
      }
    }
  }
}

// MARK: - Connection detail sheet

private struct ExchangeDetailSheet: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.dismiss) private var dismiss
  var connectionID: UUID
  @State private var confirmingRemoval = false

  private var connection: ExchangeConnectionRecord? {
    state.document.exchangeConnections.first { $0.id == connectionID }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        if let connection {
          content(for: connection)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
      }
      .background(AtlasTheme.canvas)
      .navigationTitle("Connection")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(AtlasTheme.canvas, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .fontWeight(.semibold)
        }
      }
    }
    .presentationDragIndicator(.visible)
  }

  @ViewBuilder
  private func content(for connection: ExchangeConnectionRecord) -> some View {
    let verified = ExchangePresentation.isScopeVerified(connection)
    VStack(alignment: .leading, spacing: 22) {
      VStack(spacing: 10) {
        ProviderMonogram(provider: connection.provider, size: 60)
        Text(connection.label)
          .font(.title2.weight(.semibold))
          .multilineTextAlignment(.center)
        Text(connection.provider.label)
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink3)
      }
      .frame(maxWidth: .infinity)
      .accessibilityElement(children: .combine)

      VStack(spacing: 0) {
        detailRow("Status") {
          Badge(
            ExchangePresentation.statusLabel(connection),
            color: ExchangePresentation.statusColor(connection))
        }
        Divider().overlay(AtlasTheme.ruleSoft)
        detailRow("Permissions") {
          Badge(
            verified ? "Read-only verified" : "Confirm scope",
            color: verified ? AtlasTheme.gain : AtlasTheme.warning)
        }
        Divider().overlay(AtlasTheme.ruleSoft)
        detailRow("Last updated") {
          Text(connection.lastSyncAt.map(AtlasFormatting.dateTime) ?? "Not yet")
            .font(.callout)
            .foregroundStyle(AtlasTheme.ink2)
        }
        Divider().overlay(AtlasTheme.ruleSoft)
        detailRow("Added") {
          Text(AtlasFormatting.dateTime(connection.createdAt))
            .font(.callout)
            .foregroundStyle(AtlasTheme.ink2)
        }
      }
      .padding(.horizontal, 14)
      .background(AtlasTheme.surface)
      .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous)
          .stroke(AtlasTheme.ruleSoft, lineWidth: 1)
      }

      if ExchangePresentation.hasInvalidKrakenBinding(connection) {
        InfoCallout(
          title: "Legacy Kraken key",
          copy: "Add a new per-device read-only key before scanning, then remove this one.",
          tone: .warning
        )
      }

      if let lastError = connection.lastError, !lastError.isEmpty {
        InfoCallout(title: "Last scan failed", copy: lastError, tone: .danger)
      }

      if !verified {
        Text(
          connection.provider == .binance
            ? "This key was saved before permissions were checked. Make sure it is read-only in \(connection.provider.label)."
            : "\(connection.provider.label) scope can't be checked automatically. Make sure trading and transfer permissions are off."
        )
        .font(.footnote)
        .foregroundStyle(AtlasTheme.ink3)
        .fixedSize(horizontal: false, vertical: true)
      }

      Button(role: .destructive) {
        confirmingRemoval = true
      } label: {
        Label("Remove connection", systemImage: "trash")
          .foregroundStyle(AtlasTheme.loss)
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(AtlasSecondaryButtonStyle())
      .disabled(state.vaultEditsDisabled)
      .accessibilityLabel(
        "Remove exchange connection \(AtlasAccessibility.exchangeIdentity(connection))")
      .accessibilityHint("Asks for confirmation before removing the encrypted credentials.")
      .confirmationDialog(
        "Remove \(connection.label)?",
        isPresented: $confirmingRemoval,
        titleVisibility: .visible
      ) {
        Button("Remove connection", role: .destructive) {
          Task {
            await state.removeExchangeConnection(id: connection.id)
            if self.connection == nil { dismiss() }
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(ExchangePresentation.removalMessage)
      }
    }
  }

  private func detailRow<Value: View>(
    _ title: String, @ViewBuilder value: () -> Value
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        Text(title)
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink3)
        Spacer(minLength: 8)
        value()
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(title)
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink3)
        value()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 12)
    .frame(minHeight: 44)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Touch-sized icon button

/// The shared `IconButtonStyle` renders a 34pt control, which is below the iOS
/// 44pt touch-target floor; this keeps its colors, focus ring, and motion rules
/// on a 44pt frame.
private struct ExchangesTouchIconButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout)
      .foregroundStyle(
        isEnabled
          ? (configuration.isPressed
            ? (configuration.role == .destructive ? AtlasTheme.loss : AtlasTheme.accent)
            : AtlasTheme.ink3)
          : AtlasTheme.rule
      )
      .frame(width: 44, height: 44)
      .background(
        configuration.isPressed
          ? (configuration.role == .destructive
            ? AtlasTheme.loss.opacity(0.09) : AtlasTheme.accent.opacity(0.09))
          : Color.clear
      )
      .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
      .overlay {
        if isFocused {
          RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
            .stroke(AtlasTheme.accent, lineWidth: 3)
            .accessibilityHidden(true)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
      .opacity(isEnabled ? 1 : 0.55)
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .animation(
        AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
        value: configuration.isPressed
      )
  }
}
