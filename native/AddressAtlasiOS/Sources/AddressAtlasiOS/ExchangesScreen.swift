import AddressAtlasCore
import SwiftUI

/// Read-only exchange connections, one themed card per connection. Connecting
/// happens in a sheet opened from the Sources "+" menu, the empty state, or
/// another screen through `IOSNavigationModel` (`.connectExchange`). The sheet
/// keeps the macOS flow: provider-specific guidance, the scope check inside
/// `saveExchangeConnection`, and masked credentials that are re-hidden when
/// the app leaves the foreground and discarded when the sheet closes. The
/// Sources host owns the navigation title and toolbar.
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
        SourcesEmptyState(
          systemImage: "building.columns",
          title: "No exchanges yet",
          copy: "Connect a read-only API key to see your exchange balances.",
          actionTitle: "Connect exchange",
          action: openConnectSheet
        )
        .sourcesEmptyRow()
      } else {
        ForEach(connections) { connection in
          connectionRow(connection)
        }
      }
    }
    .sourcesListStyle()
    .animation(
      AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
      value: connections.map(\.id)
    )
    .sheet(isPresented: $showsConnectSheet) {
      ConnectExchangeSheet()
    }
    .sheet(item: $detailConnectionID) { request in
      ExchangeDetailSheet(connectionID: request.id)
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
        .iosCardSurface()
    }
    .buttonStyle(SourcesRowButtonStyle())
    .iosListRow()
    .accessibilityLabel(ExchangePresentation.rowAccessibilityLabel(connection))
    .accessibilityHint("Opens the connection details.")
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button {
        pendingRemoval = connection
      } label: {
        Label("Remove", systemImage: "trash")
      }
      .tint(AtlasTheme.loss)
      .disabled(state.vaultEditsDisabled)
      .accessibilityLabel("Remove \(connection.label)")
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
        Label("Remove", systemImage: "trash")
      }
      .disabled(state.vaultEditsDisabled)
    }
    // Attached to the row so the confirmation points at the connection it
    // removes.
    .confirmationDialog(
      "Remove \(connection.label)?",
      isPresented: removalBinding(for: connection),
      titleVisibility: .visible
    ) {
      Button("Remove", role: .destructive) {
        Task { await state.removeExchangeConnection(id: connection.id) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(ExchangePresentation.removalMessage)
    }
  }

  private func removalBinding(for connection: ExchangeConnectionRecord) -> Binding<Bool> {
    Binding(
      get: { pendingRemoval?.id == connection.id },
      set: { if !$0, pendingRemoval?.id == connection.id { pendingRemoval = nil } }
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
  /// The permission to enable is named once, in the setup steps.
  fileprivate var exchangesScopeLine: String {
    switch self {
    case .binance:
      "Keys with trading, transfer, or withdrawal rights are refused."
    case .coinbase, .kraken:
      "\(label) doesn't report key permissions. Make sure the key is read-only before you connect."
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
    "The saved keys are removed from this device and its backup. An older iCloud copy keeps them until you save to iCloud again or delete that copy."

  /// The provider name under a connection's own name, unless the connection
  /// is simply called after its provider ("Coinbase / Coinbase").
  static func providerSubtitle(_ connection: ExchangeConnectionRecord) -> String? {
    connection.label.trimmingCharacters(in: .whitespacesAndNewlines)
      .caseInsensitiveCompare(connection.provider.label) == .orderedSame
      ? nil : connection.provider.label
  }

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
    var parts = [connection.label]
    if let provider = providerSubtitle(connection) { parts.append(provider) }
    parts.append(summary(connection))
    if !isScopeVerified(connection) { parts.append("scope not verified") }
    return parts.joined(separator: ", ")
  }
}

/// The provider's initial on a theme-coloured mark (no third-party logos),
/// drawn like `TokenMonogram`: the theme's mark shape, outline and number font.
private struct ProviderMonogram: View {
  @Environment(\.atlasTheme) private var tokens
  var provider: ExchangeProvider
  var size: CGFloat = 40

  var body: some View {
    let shape = tokens.shape
    let index = ExchangeProvider.allCases.firstIndex(of: provider) ?? 0
    let fill = tokens.chart.categorical(at: index)
    let markShape: AnyShape =
      shape.pillControls
      ? AnyShape(Circle())
      : AnyShape(RoundedRectangle(cornerRadius: min(shape.radiusSmall, size * 0.25), style: .continuous))
    ZStack {
      markShape.fill(fill.color)
      if shape.hasBoldBorders {
        markShape.stroke(tokens.palette.outline.color, lineWidth: max(1.5, size * 0.05))
      }
      Text(String(provider.label.prefix(1)))
        .font(tokens.font(.number, size: size * 0.42, relativeTo: .body, weight: .bold))
        .foregroundStyle(fill.readableInk.color)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// The card content of one connection; the caller draws the card around it so
/// the whole card is the tap target.
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
          .font(AtlasTheme.font(.body, .body, weight: .semibold))
          .foregroundStyle(AtlasTheme.ink)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
        HStack(spacing: 6) {
          Circle()
            .fill(ExchangePresentation.statusColor(connection))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
          Text(ExchangePresentation.summary(connection))
            .font(AtlasTheme.font(.body, .subheadline))
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
        .font(AtlasTheme.font(.body, .footnote, weight: .semibold))
        .foregroundStyle(AtlasTheme.ink3)
        .accessibilityHidden(true)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(minHeight: 64)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}

/// What the scope check does for this provider, in one line: a quiet note when
/// the app verifies the key itself, a warning when the person has to.
private struct ExchangeScopeNote: View {
  var provider: ExchangeProvider

  var body: some View {
    if provider.exchangesVerifiesScope {
      Label(provider.exchangesScopeLine, systemImage: "checkmark.shield.fill")
        .font(AtlasTheme.font(.body, .footnote))
        .foregroundStyle(AtlasTheme.ink3)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      IOSNotice(systemImage: "exclamationmark.shield.fill", text: provider.exchangesScopeLine)
    }
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
  /// A local format problem, shown under the field it belongs to.
  @State private var fieldIssue: ExchangeCredentialFormatIssue?
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
    SourcesSheet(title: "Connect exchange") {
      ExchangeProviderPicker(selection: $provider)
        .disabled(state.isValidatingExchangeCredentials)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            FormToolbarConfirmButton(
              title: "Connect", isEnabled: canSubmit, action: saveConnection)
          }
        }

      LearnMoreDisclosure("Create a read-only key", systemImage: "checklist") {
        ForEach(Array(provider.exchangesSetupSteps.enumerated()), id: \.offset) { index, step in
          HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
              .font(AtlasTheme.font(.number, .caption, weight: .bold))
              .foregroundStyle(AtlasTheme.accent)
              .frame(width: 22, height: 22)
              .background(AtlasTheme.accentSoft)
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
          copy: "The key is encrypted on this device and sent only to \(provider.label)."
        )
      }

      if provider == .kraken {
        IOSNotice(
          systemImage: "iphone",
          text: "A Kraken key works on one device only. Create a separate key for each."
        )
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
          submitLabel: .next,
          issue: fieldIssue?.field == .apiKey ? fieldIssue?.message : nil
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
          submitLabel: .done,
          issue: fieldIssue?.field == .secret ? fieldIssue?.message : nil
        ) {
          if canSubmit {
            saveConnection()
          } else {
            focusedField = nil
          }
        }
      }
      .disabled(state.isValidatingExchangeCredentials)

      ExchangeScopeNote(provider: provider)

      if isAtConnectionLimit {
        IOSNotice(
          systemImage: "exclamationmark.triangle.fill",
          text:
            "Limit of \(AppState.maximumExchangeConnections) exchange connections reached. Remove one to connect another."
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
      // Keys never carry over to another exchange's fields.
      apiKey = ""
      secret = ""
      revealsAPIKey = false
      revealsSecret = false
      fieldIssue = nil
      if !state.error.isEmpty { state.error = "" }
    }
    .onChange(of: apiKey) { _, _ in
      if fieldIssue?.field == .apiKey { fieldIssue = nil }
      if !state.error.isEmpty { state.error = "" }
    }
    .onChange(of: secret) { _, _ in
      if fieldIssue?.field == .secret { fieldIssue = nil }
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
    fieldIssue = nil
  }

  private func saveConnection() {
    guard canSubmit else { return }
    state.error = ""
    let provider = provider
    let label = label
    let credentials = ExchangeCredentialEntry.credentials(
      provider: provider, apiKey: apiKey, secret: secret)
    if let issue = AppState.exchangeCredentialFormatIssue(
      provider: provider, credentials: credentials)
    {
      fieldIssue = issue
      focusedField = issue.field == .apiKey ? .apiKey : .secret
      AtlasAccessibilityAnnouncer.shared.announceEvent(issue.message, kind: .error)
      return
    }
    focusedField = nil
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

/// Three provider cards in the theme's selected-chip style; a vertical list at
/// accessibility sizes.
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
    let shape = AtlasTheme.shape
    let shadow = shape.controlShadowOffset ?? .zero
    return Button {
      selection = provider
    } label: {
      Group {
        if dynamicTypeSize.isAccessibilitySize {
          HStack(spacing: 12) {
            ProviderMonogram(provider: provider, size: 36)
            Text(provider.label)
              .font(AtlasTheme.font(.label, .callout, weight: .semibold))
            Spacer(minLength: 0)
            if isSelected {
              Image(systemName: "checkmark.circle.fill")
                .accessibilityHidden(true)
            }
          }
          .padding(.horizontal, 12)
        } else {
          VStack(spacing: 8) {
            ProviderMonogram(provider: provider, size: 36)
            Text(provider.label)
              .font(AtlasTheme.font(.label, .callout, weight: .semibold))
              .lineLimit(1)
              .minimumScaleFactor(0.8)
          }
        }
      }
      .foregroundStyle(isSelected ? AtlasTheme.onSelection : AtlasTheme.ink)
      .frame(maxWidth: .infinity, minHeight: 44)
      .padding(.vertical, 12)
      .atlasChrome(
        fill: isSelected ? AtlasTheme.selection : AtlasTheme.surface,
        border: isSelected ? AtlasTheme.outline : AtlasTheme.controlBoundary.opacity(0.55),
        level: .control,
        radius: AtlasRadius.control,
        borderWidth: isSelected
          ? max(shape.controlBorderWidth, 1.5) : (shape.hasBoldBorders ? 1.5 : 1),
        showsShadow: isSelected
      )
      // Hard shadows need room to the right and below.
      .padding(.trailing, shadow.width)
      .padding(.bottom, shadow.height)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(provider.label)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
  /// A local format problem with this field's value.
  var issue: String? = nil
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
        .overlay {
          if issue != nil {
            RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
              .stroke(AtlasTheme.loss, lineWidth: 2)
              .allowsHitTesting(false)
          }
        }
        .accessibilityLabel(title)
        .accessibilityValue(issue.map { "Error: \($0)" } ?? "")

        Button {
          isRevealed.toggle()
        } label: {
          Image(systemName: isRevealed ? "eye.slash" : "eye")
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .buttonStyle(ExchangesTouchIconButtonStyle())
        .accessibilityLabel(isRevealed ? "Hide \(title)" : "Show \(title)")
        .accessibilityHint(
          isRevealed ? "Masks the value again." : "Shows the pasted value on screen.")
      }
      if let issue {
        Label(issue, systemImage: "exclamationmark.circle.fill")
          .font(AtlasTheme.font(.body, .footnote))
          .foregroundStyle(AtlasTheme.loss)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityHidden(true)
      }
    }
  }
}

/// Builds what a key form submits: trimmed values, with a Coinbase PEM key
/// rebuilt from a one-line paste so the signer can read it.
private enum ExchangeCredentialEntry {
  static func credentials(
    provider: ExchangeProvider, apiKey: String, secret: String
  ) -> ExchangeCredentials {
    ExchangeCredentials(
      apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
      secret: provider == .coinbase
        ? AppState.normalizedCoinbasePrivateKey(secret)
        : secret.trimmingCharacters(in: .whitespacesAndNewlines),
      passphrase: nil
    )
  }
}

// MARK: - Connection detail sheet

private struct ExchangeDetailSheet: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.dismiss) private var dismiss
  var connectionID: UUID
  @State private var confirmingRemoval = false
  @State private var isRenaming = false
  @State private var renameDraft = ""
  @State private var isReplacingKeys = false
  /// Shown in the sheet after a key replacement; the page toast sits behind
  /// this sheet.
  @State private var replacedMessage = ""

  private var connection: ExchangeConnectionRecord? {
    state.document.exchangeConnections.first { $0.id == connectionID }
  }

  var body: some View {
    SourcesSheet(title: "Connection", cancelTitle: nil) {
      VStack(alignment: .leading, spacing: 22) {
        if let connection {
          content(for: connection)
        }
      }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          FormToolbarConfirmButton(title: "Done", isEnabled: true) { dismiss() }
        }
      }
      .navigationDestination(isPresented: $isReplacingKeys) {
        if let connection {
          ReplaceExchangeKeysView(connection: connection) {
            replacedMessage = state.notice.isEmpty ? "Keys replaced." : state.notice
            state.notice = ""
          }
        }
      }
    }
    .onAppear { state.error = "" }
    .alert("Rename connection", isPresented: $isRenaming) {
      TextField("Name", text: $renameDraft)
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled()
      Button("Save") { rename() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Up to 80 characters. Leave empty to use the exchange name.")
    }
  }

  @ViewBuilder
  private func content(for connection: ExchangeConnectionRecord) -> some View {
    let verified = ExchangePresentation.isScopeVerified(connection)

    VStack(spacing: 10) {
      ProviderMonogram(provider: connection.provider, size: 60)
      Text(connection.label)
        .font(AtlasTheme.font(.display, .title2))
        .foregroundStyle(AtlasTheme.ink)
        .multilineTextAlignment(.center)
      if let provider = ExchangePresentation.providerSubtitle(connection) {
        Text(provider)
          .font(AtlasTheme.font(.body, .callout))
          .foregroundStyle(AtlasTheme.ink3)
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)

    Surface(padding: 0) {
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
            .font(AtlasTheme.font(.body, .callout))
            .foregroundStyle(AtlasTheme.ink2)
        }
        Divider().overlay(AtlasTheme.ruleSoft)
        detailRow("Added") {
          Text(AtlasFormatting.dateTime(connection.createdAt))
            .font(AtlasTheme.font(.body, .callout))
            .foregroundStyle(AtlasTheme.ink2)
        }
      }
      .padding(.horizontal, 14)
    }

    if ExchangePresentation.hasInvalidKrakenBinding(connection) {
      IOSNotice(
        systemImage: "exclamationmark.triangle.fill",
        text: "This Kraken key predates device binding. Replace it with a new read-only key made for this device before you scan."
      )
    }

    if let lastError = connection.lastError, !lastError.isEmpty {
      IOSNotice(
        systemImage: "exclamationmark.octagon.fill",
        text: "Last scan failed. \(lastError)",
        tone: .danger
      )
    }

    if !verified {
      Text(
        connection.provider == .binance
          ? "This key was saved before permissions were checked. Make sure it is read-only in \(connection.provider.label)."
          : "\(connection.provider.label) doesn't report key permissions. Make sure trading and transfer are off."
      )
      .font(AtlasTheme.font(.body, .footnote))
      .foregroundStyle(AtlasTheme.ink3)
      .fixedSize(horizontal: false, vertical: true)
    }

    IOSInlineError()

    if !replacedMessage.isEmpty {
      IOSNotice(
        systemImage: "checkmark.circle.fill",
        text: replacedMessage,
        tone: .success
      )
      .accessibilityIdentifier("exchange.keysReplaced")
    }

    VStack(spacing: 10) {
      Button {
        state.error = ""
        replacedMessage = ""
        isReplacingKeys = true
      } label: {
        Label("Replace keys", systemImage: "key")
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(AtlasSecondaryButtonStyle())
      .disabled(state.vaultEditsDisabled)
      .accessibilityHint("Opens a form to enter a new API key and secret for this connection.")

      Button {
        state.error = ""
        renameDraft = connection.label
        isRenaming = true
      } label: {
        Label("Rename", systemImage: "pencil")
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(AtlasSecondaryButtonStyle())
      .disabled(state.vaultEditsDisabled)

      Button(role: .destructive) {
        confirmingRemoval = true
      } label: {
        Label("Remove connection", systemImage: "trash")
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(SourcesDestructiveButtonStyle())
      .disabled(state.vaultEditsDisabled)
      .accessibilityLabel("Remove \(connection.label)")
      .accessibilityHint("Asks for confirmation before removing the saved keys.")
      .confirmationDialog(
        "Remove \(connection.label)?",
        isPresented: $confirmingRemoval,
        titleVisibility: .visible
      ) {
        Button("Remove", role: .destructive) {
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

  private func rename() {
    let draft = renameDraft
    Task {
      if await state.renameExchangeConnection(id: connectionID, label: draft) {
        state.error = ""
      }
    }
  }

  private func detailRow<Value: View>(
    _ title: String, @ViewBuilder value: () -> Value
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        Text(title)
          .font(AtlasTheme.font(.body, .callout))
          .foregroundStyle(AtlasTheme.ink3)
        Spacer(minLength: 8)
        value()
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(title)
          .font(AtlasTheme.font(.body, .callout))
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

// MARK: - Replace keys

/// New credentials for a saved connection, pushed inside its detail sheet.
/// Same local format check, masking, and re-hiding as the connect sheet; the
/// shared state re-runs the scope and device checks before anything changes.
private struct ReplaceExchangeKeysView: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  var connection: ExchangeConnectionRecord
  var onReplaced: () -> Void
  @State private var apiKey = ""
  @State private var secret = ""
  @State private var revealsAPIKey = false
  @State private var revealsSecret = false
  @State private var fieldIssue: ExchangeCredentialFormatIssue?
  @State private var isSaving = false
  @FocusState private var focusedField: ExchangesFormField?

  private var provider: ExchangeProvider { connection.provider }

  private var canSubmit: Bool {
    !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isSaving && !state.isValidatingExchangeCredentials && !state.vaultEditsDisabled
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("The new key replaces the saved one for \(connection.label).")
          .font(AtlasTheme.font(.body, .callout))
          .foregroundStyle(AtlasTheme.ink2)
          .fixedSize(horizontal: false, vertical: true)

        if provider == .kraken {
          IOSNotice(
            systemImage: "iphone",
            text: "Use a key made for this device. It works only here."
          )
        }

        VStack(alignment: .leading, spacing: 14) {
          ExchangesSecretField(
            title: provider.exchangesAPIKeyTitle,
            placeholder: provider.exchangesAPIKeyPlaceholder,
            text: $apiKey,
            isRevealed: $revealsAPIKey,
            field: .apiKey,
            focusedField: $focusedField,
            submitLabel: .next,
            issue: fieldIssue?.field == .apiKey ? fieldIssue?.message : nil
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
            submitLabel: .done,
            issue: fieldIssue?.field == .secret ? fieldIssue?.message : nil
          ) {
            if canSubmit { save() } else { focusedField = nil }
          }
        }
        .disabled(isSaving || state.isValidatingExchangeCredentials)

        ExchangeScopeNote(provider: provider)

        IOSInlineError()

        Button(action: save) {
          Group {
            if isSaving || state.isValidatingExchangeCredentials {
              HStack(spacing: 8) {
                ProgressView()
                  .controlSize(.small)
                  .tint(AtlasTheme.ink3)
                Text("Checking key permissions…")
              }
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("Checking API key permissions")
            } else {
              Label("Replace keys", systemImage: "lock.fill")
            }
          }
          .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        .disabled(!canSubmit)
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 32)
      .frame(maxWidth: 640, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively)
    .background(AtlasCanvasBackground().ignoresSafeArea())
    .iosTitle("Replace keys")
    .navigationBarBackButtonHidden(isSaving)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        FormToolbarConfirmButton(title: "Save", isEnabled: canSubmit, action: save)
      }
    }
    .atlasKeyboardDoneButton()
    .interactiveDismissDisabled(isSaving)
    .onAppear { state.error = "" }
    .onChange(of: apiKey) { _, _ in
      if fieldIssue?.field == .apiKey { fieldIssue = nil }
      if !state.error.isEmpty { state.error = "" }
    }
    .onChange(of: secret) { _, _ in
      if fieldIssue?.field == .secret { fieldIssue = nil }
      if !state.error.isEmpty { state.error = "" }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active {
        revealsAPIKey = false
        revealsSecret = false
      }
    }
    .onDisappear {
      apiKey = ""
      secret = ""
      revealsAPIKey = false
      revealsSecret = false
      if !isSaving { state.error = "" }
    }
  }

  private func save() {
    guard canSubmit else { return }
    state.error = ""
    let credentials = ExchangeCredentialEntry.credentials(
      provider: provider, apiKey: apiKey, secret: secret)
    if let issue = AppState.exchangeCredentialFormatIssue(
      provider: provider, credentials: credentials)
    {
      fieldIssue = issue
      focusedField = issue.field == .apiKey ? .apiKey : .secret
      AtlasAccessibilityAnnouncer.shared.announceEvent(issue.message, kind: .error)
      return
    }
    focusedField = nil
    isSaving = true
    let id = connection.id
    Task {
      let replaced = await state.replaceExchangeCredentials(id: id, credentials: credentials)
      isSaving = false
      if replaced {
        apiKey = ""
        secret = ""
        onReplaced()
        dismiss()
      }
    }
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
      .font(AtlasTheme.font(.body, .callout))
      .foregroundStyle(
        isEnabled
          ? (configuration.isPressed
            ? (configuration.role == .destructive ? AtlasTheme.loss : AtlasTheme.accent)
            : AtlasTheme.ink3)
          : AtlasTheme.ink3
      )
      .frame(width: 44, height: 44)
      .background(
        configuration.isPressed
          ? (configuration.role == .destructive ? AtlasTheme.lossSoft : AtlasTheme.accentSoft)
          : Color.clear
      )
      .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
      .overlay {
        if isFocused {
          RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
            .stroke(AtlasTheme.focusRing, lineWidth: 3)
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
