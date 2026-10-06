import AddressAtlasCore
import SwiftUI
import UIKit

/// Manual (offline) holdings and the custom token allowlist. Ports the macOS
/// `TokenAllowlistView` and the manual-holding half of `SnapshotsView` onto a
/// list-first page: a segmented control picks the list, the toolbar "+" and
/// each empty state open the add sheet, and a row opens its detail sheet.
/// Every mutation goes through the shared `AppState`, which validates input,
/// enforces the vault limits, and reports errors that the sheets show inline.
struct TokensScreen: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var segment: TokensSegment = .holdings
  @State private var isAddingHolding = false
  @State private var isAddingToken = false
  @State private var detail: TokensDetailSelection?

  var body: some View {
    IOSPage(title: "Tokens") {
      Picker("List", selection: $segment) {
        Text(dynamicTypeSize.isAccessibilitySize ? "Manual" : "Manual holdings")
          .tag(TokensSegment.holdings)
        Text(dynamicTypeSize.isAccessibilitySize ? "Custom" : "Custom tokens")
          .tag(TokensSegment.customTokens)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel("List")
      .accessibilityIdentifier("tokens-segment-picker")

      switch segment {
      case .holdings:
        TokensManualHoldingList(
          onAdd: { openAddSheet(for: .holdings) },
          onSelect: { detail = .holding($0) }
        )
      case .customTokens:
        TokensCustomTokenList(
          onAdd: { openAddSheet(for: .customTokens) },
          onSelect: { detail = .token($0) }
        )
      }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          openAddSheet(for: segment)
        } label: {
          Image(systemName: "plus")
        }
        .disabled(state.vaultEditsDisabled)
        .accessibilityLabel(segment == .holdings ? "Add manual holding" : "Add custom token")
        .accessibilityIdentifier("tokens-add-button")
      }
    }
    .sheet(isPresented: $isAddingHolding) {
      TokensAddHoldingSheet()
    }
    .sheet(isPresented: $isAddingToken) {
      TokensAddCustomTokenSheet()
    }
    .sheet(item: $detail) { selection in
      switch selection {
      case .holding(let id): TokensHoldingDetailSheet(id: id)
      case .token(let id): TokensCustomTokenDetailSheet(id: id)
      }
    }
    .onAppear(perform: consumePendingAction)
    .onChange(of: navigation.pendingAction) { _, _ in
      consumePendingAction()
    }
  }

  private func openAddSheet(for segment: TokensSegment) {
    self.segment = segment
    switch segment {
    case .holdings: isAddingHolding = true
    case .customTokens: isAddingToken = true
    }
  }

  private func consumePendingAction() {
    if navigation.consume(.addManualHolding) {
      openAddSheet(for: .holdings)
    } else if navigation.consume(.addCustomToken) {
      openAddSheet(for: .customTokens)
    }
  }
}

private enum TokensSegment: Hashable {
  case holdings
  case customTokens
}

private enum TokensDetailSelection: Identifiable, Hashable {
  case holding(UUID)
  case token(UUID)

  var id: Self { self }
}

// MARK: - Shared helpers

private enum TokensCopy {
  static func networkName(chainKind: ChainFamily, chainId: String) -> String {
    if chainKind == .solana { return "Solana" }
    return ChainRegistry.evmChains.first(where: { $0.id == chainId })?.name ?? chainId
  }

  static func shortAddress(_ address: String) -> String {
    guard address.count > 14 else { return address }
    return "\(address.prefix(6))…\(address.suffix(4))"
  }

  static func amount(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...8)).locale(AtlasFormatting.locale))
  }

  /// The built-in registry entry that already covers this contract or mint;
  /// the shared state refuses such a copy because the scanner would ignore it.
  static func builtInToken(
    chainKind: ChainFamily, chainId: String, address: String
  ) -> TokenConfig? {
    AppState.builtInToken(chainKind: chainKind, chainId: chainId, address: address)
  }

  /// A stored number in the current locale without grouping, so it parses
  /// back through `UserInputValidation` unchanged when an edit is saved.
  static func editableNumber(_ value: Double) -> String {
    value.formatted(
      .number.grouping(.never).precision(.fractionLength(0...12)).locale(.current))
  }

  static var decimalHint: String {
    let separator = Locale.current.decimalSeparator ?? "."
    let example = 1.5.formatted(.number.locale(.current))
    return "Use “\(separator)” for decimals, like \(example)."
  }

  @MainActor
  static func dismissKeyboard() {
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
  }
}

/// Short empty state with a direct action, so an empty list is never a dead end.
private struct TokensEmptyState: View {
  @EnvironmentObject private var state: AppState
  var systemImage: String
  var title: String
  var copy: String
  var actionTitle: String
  var actionIdentifier: String
  var action: () -> Void

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: systemImage)
        .font(.title2.weight(.semibold))
        .foregroundStyle(AtlasTheme.accent)
        .frame(width: 56, height: 56)
        .background(AtlasTheme.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
      VStack(spacing: 6) {
        Text(title)
          .font(.title3.weight(.semibold))
          .foregroundStyle(AtlasTheme.ink)
          .accessibilityAddTraits(.isHeader)
        Text(copy)
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink3)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      Button(action: action) {
        Label(actionTitle, systemImage: "plus")
          .frame(minHeight: 44)
      }
      .buttonStyle(AtlasPrimaryButtonStyle())
      .disabled(state.vaultEditsDisabled)
      .accessibilityIdentifier(actionIdentifier)
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 24)
    .padding(.vertical, 32)
    .background(AtlasTheme.surfaceMuted.opacity(0.38))
    .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous))
  }
}

/// Caption under a list: quota and enabled count.
private struct TokensListFooter: View {
  var text: String

  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(AtlasTheme.ink3)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 4)
  }
}

// MARK: - Manual holdings list

private struct TokensManualHoldingList: View {
  @EnvironmentObject private var state: AppState
  var onAdd: () -> Void
  var onSelect: (UUID) -> Void

  private var holdings: [ManualHoldingRecord] { state.document.manualHoldings }
  private var enabledCount: Int { holdings.filter(\.enabled).count }
  private var includedValue: Double {
    holdings.filter(\.enabled).reduce(0) { $0 + $1.valueUsd }
  }

  var body: some View {
    if holdings.isEmpty {
      TokensEmptyState(
        systemImage: "pencil.and.list.clipboard",
        title: "No manual holdings",
        copy: "Record balances that can't be scanned, like an exchange you don't connect.",
        actionTitle: "Add holding",
        actionIdentifier: "tokens-empty-add-holding",
        action: onAdd
      )
    } else {
      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Included value")
            .font(.subheadline)
            .foregroundStyle(AtlasTheme.ink3)
          Text(money(includedValue))
            .font(.title2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(AtlasTheme.ink)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)

        Surface(padding: 0) {
          VStack(spacing: 0) {
            ForEach(holdings) { holding in
              TokensManualHoldingRow(holding: holding, onSelect: { onSelect(holding.id) })
              if holding.id != holdings.last?.id {
                Divider().overlay(AtlasTheme.ruleSoft).padding(.leading, 66)
              }
            }
          }
        }

        TokensListFooter(
          text:
            "\(enabledCount) included · \(holdings.count) of \(AppState.maximumManualHoldings)"
        )
      }
    }
  }
}

private struct TokensManualHoldingRow: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var confirmingRemoval = false
  @State private var pendingEnabled: Bool?
  var holding: ManualHoldingRecord
  var onSelect: () -> Void

  private var identity: String { AtlasAccessibility.manualHoldingIdentity(holding) }
  /// Optimistic switch position while the vault write is in flight, so the
  /// control does not snap back for a frame before the document updates.
  private var isEnabled: Bool { pendingEnabled ?? holding.enabled }

  private var detailLine: String {
    var parts = ["\(TokensCopy.amount(holding.amount)) \(holding.symbol)"]
    let label = holding.label.trimmingCharacters(in: .whitespacesAndNewlines)
    if !label.isEmpty, label != "Manual" { parts.append(label) }
    if !isEnabled { parts.append("Paused") }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    TokensSwipeRow(
      removeAccessibilityLabel: "Remove manual holding \(identity)",
      onOpen: onSelect,
      onRemove: { confirmingRemoval = true }
    ) {
      let layout =
        dynamicTypeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
      layout {
        HStack(spacing: 12) {
          TokenMonogram(symbol: holding.symbol, size: 40)
            .opacity(isEnabled ? 1 : 0.45)
          VStack(alignment: .leading, spacing: 2) {
            Text(holding.symbol)
              .font(.body.weight(.semibold))
              .foregroundStyle(AtlasTheme.ink)
              .lineLimit(1)
            Text(detailLine)
              .font(.subheadline)
              .foregroundStyle(AtlasTheme.ink3)
              .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Text(money(holding.valueUsd))
          .font(.body.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(isEnabled ? AtlasTheme.ink : AtlasTheme.ink3)
          .lineLimit(1)
          .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "\(holding.symbol), \(TokensCopy.amount(holding.amount)), \(money(holding.valueUsd))\(isEnabled ? "" : ", paused")"
      )
    } trailing: {
      Toggle(
        "Include \(holding.symbol)",
        isOn: Binding(
          get: { isEnabled },
          set: { newValue in
            pendingEnabled = newValue
            Task {
              await state.toggleManualHolding(id: holding.id)
              pendingEnabled = nil
            }
          }
        )
      )
      .labelsHidden()
      .frame(minHeight: 44)
      .accessibilityLabel(
        "\(holding.enabled ? "Disable" : "Enable") manual holding \(identity)"
      )
    }
    .contextMenu {
      Button {
        onSelect()
      } label: {
        Label("Details", systemImage: "info.circle")
      }
      Button(role: .destructive) {
        confirmingRemoval = true
      } label: {
        Label("Remove holding", systemImage: "trash")
      }
    }
    .confirmationDialog(
      "Remove \(holding.symbol) holding?",
      isPresented: $confirmingRemoval,
      titleVisibility: .visible
    ) {
      Button("Remove holding", role: .destructive) {
        Task { await state.removeManualHolding(id: holding.id) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("It is removed from this device and left out of future snapshots.")
    }
    .disabled(state.vaultEditsDisabled)
  }
}

// MARK: - Custom tokens list

private struct TokensCustomTokenList: View {
  @EnvironmentObject private var state: AppState
  var onAdd: () -> Void
  var onSelect: (UUID) -> Void

  private var tokens: [CustomTokenRecord] { state.document.customTokens }
  private var enabledCount: Int { tokens.filter(\.enabled).count }

  var body: some View {
    if tokens.isEmpty {
      TokensEmptyState(
        systemImage: "tag",
        title: "No custom tokens",
        copy: "Add a contract or mint the built-in token list doesn't cover.",
        actionTitle: "Add token",
        actionIdentifier: "tokens-empty-add-token",
        action: onAdd
      )
    } else {
      VStack(alignment: .leading, spacing: 10) {
        Surface(padding: 0) {
          VStack(spacing: 0) {
            ForEach(tokens) { token in
              TokensCustomTokenRow(token: token, onSelect: { onSelect(token.id) })
              if token.id != tokens.last?.id {
                Divider().overlay(AtlasTheme.ruleSoft).padding(.leading, 66)
              }
            }
          }
        }
        TokensListFooter(
          text: "\(enabledCount) enabled · \(tokens.count) of \(AppState.maximumCustomTokens)"
        )
      }
    }
  }
}

private struct TokensCustomTokenRow: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var confirmingRemoval = false
  @State private var pendingEnabled: Bool?
  var token: CustomTokenRecord
  var onSelect: () -> Void

  private var identity: String { AtlasAccessibility.tokenIdentity(token) }
  private var isEnabled: Bool { pendingEnabled ?? token.enabled }
  private var networkName: String {
    TokensCopy.networkName(chainKind: token.chainKind, chainId: token.chainId)
  }

  var body: some View {
    TokensSwipeRow(
      removeAccessibilityLabel: "Remove token \(identity)",
      onOpen: onSelect,
      onRemove: { confirmingRemoval = true }
    ) {
      HStack(spacing: 12) {
        TokenMonogram(symbol: token.symbol, size: 40)
          .opacity(isEnabled ? 1 : 0.45)
        VStack(alignment: .leading, spacing: 2) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(token.symbol)
              .font(.body.weight(.semibold))
              .foregroundStyle(AtlasTheme.ink)
              .lineLimit(1)
              .layoutPriority(1)
            Text(token.name)
              .font(.subheadline)
              .foregroundStyle(AtlasTheme.ink2)
              .lineLimit(1)
          }
          Text(
            "\(networkName) · \(TokensCopy.shortAddress(token.address))\(isEnabled ? "" : " · Paused")"
          )
          .font(.subheadline)
          .foregroundStyle(AtlasTheme.ink3)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "\(token.symbol), \(token.name), \(networkName)\(isEnabled ? "" : ", paused")")
    } trailing: {
      Toggle(
        "Enable \(token.symbol)",
        isOn: Binding(
          get: { isEnabled },
          set: { newValue in
            pendingEnabled = newValue
            Task {
              await state.toggleCustomToken(id: token.id)
              pendingEnabled = nil
            }
          }
        )
      )
      .labelsHidden()
      .frame(minHeight: 44)
      .accessibilityLabel("\(token.enabled ? "Disable" : "Enable") token \(identity)")
    }
    .contextMenu {
      Button {
        onSelect()
      } label: {
        Label("Details", systemImage: "info.circle")
      }
      Button {
        UIPasteboard.general.string = token.address
      } label: {
        Label(token.chainKind == .evm ? "Copy contract" : "Copy mint", systemImage: "doc.on.doc")
      }
      Button(role: .destructive) {
        confirmingRemoval = true
      } label: {
        Label("Remove token", systemImage: "trash")
      }
    }
    .confirmationDialog(
      "Remove \(token.symbol) on \(networkName)?",
      isPresented: $confirmingRemoval,
      titleVisibility: .visible
    ) {
      Button("Remove token", role: .destructive) {
        Task { await state.removeCustomToken(id: token.id) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Scans stop looking for this token on this device.")
    }
    .disabled(state.vaultEditsDisabled)
  }
}

// MARK: - Add holding sheet

private struct TokensAddHoldingSheet: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.dismiss) private var dismiss
  @State private var symbol: String
  @State private var amount: String
  @State private var value: String
  @State private var isAdding = false
  /// The saved holding being edited; nil adds a new one.
  private let editingID: UUID?

  /// Pushed inside the detail sheet's navigation stack instead of presented.
  private let embedded: Bool

  init(editing holding: ManualHoldingRecord? = nil, embedded: Bool = false) {
    editingID = holding?.id
    self.embedded = embedded
    _symbol = State(initialValue: holding?.symbol ?? "")
    _amount = State(initialValue: holding.map { TokensCopy.editableNumber($0.amount) } ?? "")
    _value = State(initialValue: holding.map { TokensCopy.editableNumber($0.valueUsd) } ?? "")
  }

  private var isEditing: Bool { editingID != nil }

  private var holdings: [ManualHoldingRecord] { state.document.manualHoldings }
  private var isAtLimit: Bool {
    !isEditing && holdings.count >= AppState.maximumManualHoldings
  }
  private var trimmedSymbol: String {
    symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  }

  private var hasRequiredInput: Bool {
    !trimmedSymbol.isEmpty
      && !amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Same derivation the vault write uses, shown live so the unit price the
  /// snapshot will carry is visible before saving.
  private var impliedPrice: Double? {
    guard let parsedAmount = UserInputValidation.nonnegativeFiniteNumber(amount),
      let parsedValue = UserInputValidation.nonnegativeFiniteNumber(value)
    else { return nil }
    return AppState.derivedManualPrice(amount: parsedAmount, valueUsd: parsedValue)
  }

  var body: some View {
    TokensFormContainer(title: isEditing ? "Edit holding" : "Add holding", embedded: embedded) {
      Text(
        isEditing
          ? "Changes apply from your next snapshot." : "Included in your next snapshot.")
        .font(.callout)
        .foregroundStyle(AtlasTheme.ink2)

      TokensFormField(title: "Symbol", placeholder: "BTC", kind: .symbol, text: $symbol)
        .accessibilityIdentifier("manual-holding-symbol")

      AdaptiveStack(horizontalSpacing: 12, verticalSpacing: 14) {
        TokensFormField(
          title: "Amount",
          placeholder: "0",
          kind: .decimal,
          accessibilityHint: TokensCopy.decimalHint,
          text: $amount
        )
        .accessibilityIdentifier("manual-holding-amount")
        TokensFormField(
          title: "Total value",
          detail: "USD",
          placeholder: "0",
          kind: .decimal,
          accessibilityLabel: "Total value, USD",
          accessibilityHint: TokensCopy.decimalHint,
          text: $value
        )
        .accessibilityIdentifier("manual-holding-value")
      }

      VStack(alignment: .leading, spacing: 4) {
        if let impliedPrice {
          Text("≈ \(money(impliedPrice)) per \(trimmedSymbol.isEmpty ? "unit" : trimmedSymbol)")
            .font(.callout.weight(.medium))
            .foregroundStyle(AtlasTheme.ink2)
            .monospacedDigit()
        }
        Text(TokensCopy.decimalHint)
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
          .accessibilityHidden(true)
      }

      if isAtLimit {
        Text(
          "Limit reached: \(AppState.maximumManualHoldings) of \(AppState.maximumManualHoldings) holdings. Remove one first."
        )
        .font(.callout)
        .foregroundStyle(AtlasTheme.warning)
        .fixedSize(horizontal: false, vertical: true)
      }

      IOSInlineError()

      Button(action: add) {
        HStack(spacing: 8) {
          if isAdding {
            ProgressView()
              .controlSize(.small)
              .tint(AtlasTheme.paper)
          }
          Text(isEditing ? "Save changes" : "Add holding")
        }
        .frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(AtlasPrimaryButtonStyle())
      .disabled(!hasRequiredInput || isAdding || isAtLimit || state.vaultEditsDisabled)
      .accessibilityIdentifier(isEditing ? "manual-holding-save" : "manual-holding-add")

      if !isEditing {
        Text("\(holdings.count) of \(AppState.maximumManualHoldings) holdings used")
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
          .frame(maxWidth: .infinity)
      }
    }
    .presentationDetents([.large])
    .onAppear { state.error = "" }
    // A sheet error belongs to the sheet; never leave it in the page toast.
    .onDisappear { clearError() }
    .onChange(of: [symbol, amount, value]) { _, _ in clearError() }
    .interactiveDismissDisabled(isAdding)
  }

  private func clearError() {
    if !state.error.isEmpty { state.error = "" }
  }

  private func add() {
    guard !isAdding else { return }
    // Lower the keyboard first so the inline error or the dismissal is
    // visible right next to the button that was pressed (F04).
    TokensCopy.dismissKeyboard()
    isAdding = true
    let addedSymbol = trimmedSymbol
    Task {
      let saved: Bool
      if let editingID {
        saved = await state.updateManualHolding(
          id: editingID, symbol: symbol, amount: amount, valueUsd: value)
      } else {
        saved = await state.addManualHolding(symbol: symbol, amount: amount, valueUsd: value)
      }
      isAdding = false
      if saved {
        if state.error.isEmpty {
          state.notice =
            isEditing ? "\(addedSymbol) holding updated." : "\(addedSymbol) holding added."
        }
        dismiss()
      }
    }
  }
}

// MARK: - Add custom token sheet

private struct TokensAddCustomTokenSheet: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.dismiss) private var dismiss
  @State private var chainKind: ChainFamily
  @State private var chainId: String
  @State private var address: String
  @State private var symbol: String
  @State private var name: String
  @State private var decimals: String
  @State private var coinGeckoId: String
  @State private var priceUsd: String
  @State private var isAdding = false
  /// The saved token being edited; nil adds a new one.
  private let editingID: UUID?

  /// Pushed inside the detail sheet's navigation stack instead of presented.
  private let embedded: Bool

  init(editing token: CustomTokenRecord? = nil, embedded: Bool = false) {
    editingID = token?.id
    self.embedded = embedded
    _chainKind = State(initialValue: token?.chainKind ?? .evm)
    _chainId = State(initialValue: token?.chainId ?? "ethereum")
    _address = State(initialValue: token?.address ?? "")
    _symbol = State(initialValue: token?.symbol ?? "")
    _name = State(initialValue: token?.name ?? "")
    _decimals = State(initialValue: token.map { "\($0.decimals)" } ?? "18")
    _coinGeckoId = State(initialValue: token?.coinGeckoId ?? "")
    _priceUsd = State(initialValue: token?.priceUsd.map(TokensCopy.editableNumber) ?? "")
  }

  private var isEditing: Bool { editingID != nil }
  private var tokens: [CustomTokenRecord] { state.document.customTokens }
  private var isAtLimit: Bool { !isEditing && tokens.count >= AppState.maximumCustomTokens }
  private var effectiveChainId: String { chainKind == .solana ? "solana" : chainId }

  private var hasRequiredInput: Bool {
    !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !decimals.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var builtIn: TokenConfig? {
    TokensCopy.builtInToken(chainKind: chainKind, chainId: effectiveChainId, address: address)
  }

  private var selectedNetworkName: String {
    TokensCopy.networkName(chainKind: chainKind, chainId: chainId)
  }

  var body: some View {
    TokensFormContainer(title: isEditing ? "Edit token" : "Add custom token", embedded: embedded) {
      networkSection
      addressSection
      if let builtIn {
        builtInNotice(builtIn)
      }
      detailFields
      footer
    }
    .presentationDetents([.large])
    .onAppear { state.error = "" }
    .onDisappear { clearError() }
    .onChange(of: chainKind) { _, next in
      chainId = next == .solana ? "solana" : "ethereum"
      decimals = next == .solana ? "6" : "18"
      clearError()
    }
    .onChange(of: [chainId, address, symbol, name, decimals, coinGeckoId, priceUsd]) { _, _ in
      clearError()
    }
    .interactiveDismissDisabled(isAdding)
  }

  private func clearError() {
    if !state.error.isEmpty { state.error = "" }
  }

  private var networkSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      FieldLabel("Network")
      Picker("Network family", selection: $chainKind) {
        Text("EVM").tag(ChainFamily.evm)
        Text("Solana").tag(ChainFamily.solana)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(minHeight: 44)
      .accessibilityLabel("Network family")
      if chainKind == .evm {
        networkPicker
      }
    }
  }

  private var addressSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      FieldLabel(chainKind == .evm ? "Contract address" : "Mint address")
      HStack(spacing: 8) {
        TextField(
          chainKind == .evm ? "0x…" : "Mint address",
          text: $address
        )
        .textFieldStyle(AtlasTextFieldStyle())
        .atlasIdentifierInput()
        .accessibilityLabel(chainKind == .evm ? "Contract address" : "Mint address")
        .accessibilityIdentifier("custom-token-address")
        PasteButton(payloadType: String.self) { strings in
          guard let pasted = strings.first else { return }
          Task { @MainActor in
            address = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
          }
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.roundedRectangle(radius: AtlasRadius.control))
        .frame(minHeight: 44)
      }
      Label(
        "The address decides what is scanned. Copy it from a trusted source.",
        systemImage: "checkmark.shield"
      )
      .font(.caption)
      .foregroundStyle(AtlasTheme.ink3)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private var detailFields: some View {
    AdaptiveStack(horizontalSpacing: 12, verticalSpacing: 14) {
      TokensFormField(title: "Symbol", placeholder: "USDC", kind: .symbol, text: $symbol)
      TokensFormField(
        title: "Decimals",
        placeholder: chainKind == .evm ? "18" : "6",
        kind: .integer,
        text: $decimals
      )
    }

    TokensFormField(title: "Name", placeholder: "USD Coin", kind: .name, text: $name)

    AdaptiveStack(horizontalSpacing: 12, verticalSpacing: 14) {
      TokensFormField(
        title: "CoinGecko ID",
        detail: "Optional",
        placeholder: "usd-coin",
        kind: .identifier,
        text: $coinGeckoId
      )
      TokensFormField(
        title: "USD price",
        detail: "Optional",
        placeholder: "0",
        kind: .decimal,
        accessibilityLabel: "Manual USD price, optional",
        accessibilityHint: TokensCopy.decimalHint,
        text: $priceUsd
      )
    }

    LearnMoreDisclosure("Why the address matters", systemImage: "info.circle") {
      Text(
        "A misleading symbol or name can't change which on-chain token is scanned; only the contract or mint address does. Confirm it on the issuer's site or a block explorer."
      )
      Text(
        "Common tokens such as USDC and USDT on major networks are built in already. Add only tokens the built-in list doesn't cover."
      )
      Text(
        "Without a CoinGecko ID or a manual price, the token's balance is shown as unpriced."
      )
    }
  }

  @ViewBuilder
  private var footer: some View {
    if isAtLimit {
      Text(
        "Limit reached: \(AppState.maximumCustomTokens) of \(AppState.maximumCustomTokens) custom tokens. Remove one first."
      )
      .font(.callout)
      .foregroundStyle(AtlasTheme.warning)
      .fixedSize(horizontal: false, vertical: true)
    }

    IOSInlineError()

    Button(action: add) {
      HStack(spacing: 8) {
        if isAdding {
          ProgressView()
            .controlSize(.small)
            .tint(AtlasTheme.paper)
        }
        Text(isEditing ? "Save changes" : "Add token")
      }
      .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(AtlasPrimaryButtonStyle())
    .disabled(
      !hasRequiredInput || isAdding || isAtLimit || builtIn != nil || state.vaultEditsDisabled
    )
    .accessibilityIdentifier(isEditing ? "custom-token-save" : "custom-token-add")

    if !isEditing {
      Text("\(tokens.count) of \(AppState.maximumCustomTokens) custom tokens used")
        .font(.caption)
        .foregroundStyle(AtlasTheme.ink3)
        .frame(maxWidth: .infinity)
    }
  }

  private func builtInNotice(_ token: TokenConfig) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "checkmark.seal.fill")
        .foregroundStyle(AtlasTheme.accent)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("\(token.symbol) is already built in")
          .font(.callout.weight(.semibold))
          .foregroundStyle(AtlasTheme.ink)
        Text(
          "Scans already include \(token.name) on \(selectedNetworkNameForNotice). A custom copy would be ignored, so there's nothing to add."
        )
        .font(.callout)
        .foregroundStyle(AtlasTheme.ink2)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AtlasTheme.accent.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("custom-token-built-in-notice")
  }

  private var selectedNetworkNameForNotice: String {
    chainKind == .solana ? "Solana" : selectedNetworkName
  }

  /// A `Menu` wrapping the picker keeps the whole 44pt field row tappable,
  /// which the bare `.menu` picker style does not guarantee.
  private var networkPicker: some View {
    Menu {
      Picker("Network", selection: $chainId) {
        ForEach(ChainRegistry.evmChains, id: \.id) { chain in
          Text(chain.name).tag(chain.id)
        }
      }
    } label: {
      HStack(spacing: 8) {
        Text(selectedNetworkName)
          .foregroundStyle(AtlasTheme.ink)
        Spacer(minLength: 8)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(AtlasTheme.ink3)
      }
      .padding(.horizontal, 13)
      .frame(minHeight: 44)
      .frame(maxWidth: .infinity)
      .contentShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
    }
    .background(AtlasTheme.surfaceMuted.opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
        .stroke(AtlasTheme.rule, lineWidth: 1)
    }
    .accessibilityLabel("Network")
    .accessibilityValue(selectedNetworkName)
  }

  private func add() {
    guard !isAdding, builtIn == nil else { return }
    TokensCopy.dismissKeyboard()
    isAdding = true
    let addedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    Task {
      let saved: Bool
      if let editingID {
        saved = await state.updateCustomToken(
          id: editingID,
          chainKind: chainKind,
          chainId: effectiveChainId,
          address: address,
          symbol: symbol,
          name: name,
          decimals: decimals,
          coinGeckoId: coinGeckoId,
          priceUsd: priceUsd
        )
      } else {
        saved = await state.addCustomToken(
          chainKind: chainKind,
          chainId: effectiveChainId,
          address: address,
          symbol: symbol,
          name: name,
          decimals: decimals,
          coinGeckoId: coinGeckoId,
          priceUsd: priceUsd
        )
      }
      isAdding = false
      if saved {
        if state.error.isEmpty {
          state.notice =
            isEditing
            ? "\(addedSymbol) updated. Changes apply from the next scan."
            : "\(addedSymbol) added. It's included in the next scan."
        }
        dismiss()
      }
    }
  }
}

// MARK: - Detail sheets

/// Facts plus the controls for a saved holding: edit, include/pause, remove.
private struct TokensHoldingDetailSheet: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.dismiss) private var dismiss
  @State private var isEditing = false
  @State private var confirmingRemoval = false
  @State private var isRemoving = false
  @State private var pendingEnabled: Bool?
  var id: UUID

  private var holding: ManualHoldingRecord? {
    state.document.manualHoldings.first(where: { $0.id == id })
  }

  var body: some View {
    TokensDetailScaffold(
      title: holding?.symbol ?? "Holding",
      onEdit: holding == nil || state.vaultEditsDisabled ? nil : { isEditing = true }
    ) {
      if let holding {
        content(holding)
      } else {
        Text("This holding was removed.")
          .foregroundStyle(AtlasTheme.ink3)
      }
    }
    .presentationDetents([.medium, .large])
  }

  @ViewBuilder
  private func content(_ holding: ManualHoldingRecord) -> some View {
    let isEnabled = pendingEnabled ?? holding.enabled
    TokensDetailHeader(
      symbol: holding.symbol,
      title: money(holding.valueUsd),
      subtitle: "\(TokensCopy.amount(holding.amount)) \(holding.symbol)",
      isEnabled: isEnabled
    )

    Surface(padding: 0) {
      VStack(spacing: 0) {
        TokensDetailRow(title: "Amount", value: TokensCopy.amount(holding.amount))
        TokensDetailDivider()
        TokensDetailRow(title: "Total value", value: money(holding.valueUsd))
        if let price = holding.priceUsd {
          TokensDetailDivider()
          TokensDetailRow(title: "Unit price", value: money(price))
        }
        TokensDetailDivider()
        TokensDetailRow(title: "Added", value: AtlasFormatting.dateTime(holding.createdAt))
        if holding.updatedAt.timeIntervalSince(holding.createdAt) > 1 {
          TokensDetailDivider()
          TokensDetailRow(title: "Updated", value: AtlasFormatting.dateTime(holding.updatedAt))
        }
      }
    }

    Surface(padding: 0) {
      Toggle(
        "Include in snapshots",
        isOn: Binding(
          get: { isEnabled },
          set: { newValue in
            pendingEnabled = newValue
            Task {
              await state.toggleManualHolding(id: holding.id)
              pendingEnabled = nil
            }
          }
        )
      )
      .font(.body)
      .tint(AtlasTheme.accent)
      .padding(.horizontal, 16)
      .frame(minHeight: 52)
      .disabled(state.vaultEditsDisabled)
    }

    Button {
      isEditing = true
    } label: {
      Label("Edit amount or value", systemImage: "pencil")
        .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(AtlasSecondaryButtonStyle())
    .disabled(state.vaultEditsDisabled)
    .accessibilityIdentifier("manual-holding-edit")
    .navigationDestination(isPresented: $isEditing) {
      TokensAddHoldingSheet(editing: holding, embedded: true)
    }

    Button(role: .destructive) {
      confirmingRemoval = true
    } label: {
      HStack(spacing: 8) {
        if isRemoving {
          ProgressView().controlSize(.small)
        }
        Label("Remove holding", systemImage: "trash")
      }
      .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(TokensDestructiveButtonStyle())
    .disabled(isRemoving || state.vaultEditsDisabled)
    .accessibilityLabel(
      "Remove manual holding \(AtlasAccessibility.manualHoldingIdentity(holding))"
    )
    .confirmationDialog(
      "Remove \(holding.symbol) holding?",
      isPresented: $confirmingRemoval,
      titleVisibility: .visible
    ) {
      Button("Remove holding", role: .destructive) {
        isRemoving = true
        Task {
          await state.removeManualHolding(id: holding.id)
          isRemoving = false
          if self.holding == nil { dismiss() }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("It is removed from this device and left out of future snapshots.")
    }
  }
}

private struct TokensCustomTokenDetailSheet: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.dismiss) private var dismiss
  @State private var isEditing = false
  @State private var confirmingRemoval = false
  @State private var isRemoving = false
  @State private var pendingEnabled: Bool?
  var id: UUID

  private var token: CustomTokenRecord? {
    state.document.customTokens.first(where: { $0.id == id })
  }

  var body: some View {
    TokensDetailScaffold(
      title: token?.symbol ?? "Token",
      onEdit: token == nil || state.vaultEditsDisabled ? nil : { isEditing = true }
    ) {
      if let token {
        content(token)
      } else {
        Text("This token was removed.")
          .foregroundStyle(AtlasTheme.ink3)
      }
    }
    .presentationDetents([.medium, .large])
  }

  private func priceSource(_ token: CustomTokenRecord) -> String {
    if let price = token.priceUsd { return "\(money(price)) (manual)" }
    if let id = token.coinGeckoId, !id.isEmpty { return "CoinGecko · \(id)" }
    return "Not priced"
  }

  @ViewBuilder
  private func content(_ token: CustomTokenRecord) -> some View {
    let isEnabled = pendingEnabled ?? token.enabled
    let network = TokensCopy.networkName(chainKind: token.chainKind, chainId: token.chainId)
    TokensDetailHeader(
      symbol: token.symbol,
      title: token.name,
      subtitle: network,
      isEnabled: isEnabled
    )

    if let builtIn = TokensCopy.builtInToken(
      chainKind: token.chainKind, chainId: token.chainId, address: token.address)
    {
      InfoCallout(
        title: "\(builtIn.symbol) is built in",
        copy:
          "Scans use the built-in \(builtIn.name) on \(network), so this copy has no effect. You can remove it.",
        tone: .warning
      )
    }

    Surface(padding: 0) {
      VStack(spacing: 0) {
        TokensDetailRow(title: "Network", value: network)
        TokensDetailDivider()
        TokensDetailRow(
          title: token.chainKind == .evm ? "Contract" : "Mint",
          value: token.address,
          isIdentifier: true
        )
        TokensDetailDivider()
        TokensDetailRow(title: "Decimals", value: "\(token.decimals)")
        TokensDetailDivider()
        TokensDetailRow(title: "Price", value: priceSource(token))
        TokensDetailDivider()
        TokensDetailRow(title: "Added", value: AtlasFormatting.dateTime(token.createdAt))
      }
    }

    Surface(padding: 0) {
      Toggle(
        "Include in scans",
        isOn: Binding(
          get: { isEnabled },
          set: { newValue in
            pendingEnabled = newValue
            Task {
              await state.toggleCustomToken(id: token.id)
              pendingEnabled = nil
            }
          }
        )
      )
      .font(.body)
      .tint(AtlasTheme.accent)
      .padding(.horizontal, 16)
      .frame(minHeight: 52)
      .disabled(state.vaultEditsDisabled)
    }

    Button {
      isEditing = true
    } label: {
      Label("Edit token", systemImage: "pencil")
        .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(AtlasSecondaryButtonStyle())
    .disabled(state.vaultEditsDisabled)
    .accessibilityIdentifier("custom-token-edit")
    .navigationDestination(isPresented: $isEditing) {
      TokensAddCustomTokenSheet(editing: token, embedded: true)
    }

    Button {
      UIPasteboard.general.string = token.address
      state.notice = token.chainKind == .evm ? "Contract address copied." : "Mint address copied."
    } label: {
      Label(
        token.chainKind == .evm ? "Copy contract address" : "Copy mint address",
        systemImage: "doc.on.doc"
      )
      .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(AtlasSecondaryButtonStyle())

    Button(role: .destructive) {
      confirmingRemoval = true
    } label: {
      HStack(spacing: 8) {
        if isRemoving {
          ProgressView().controlSize(.small)
        }
        Label("Remove token", systemImage: "trash")
      }
      .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(TokensDestructiveButtonStyle())
    .disabled(isRemoving || state.vaultEditsDisabled)
    .accessibilityLabel("Remove token \(AtlasAccessibility.tokenIdentity(token))")
    .confirmationDialog(
      "Remove \(token.symbol) on \(network)?",
      isPresented: $confirmingRemoval,
      titleVisibility: .visible
    ) {
      Button("Remove token", role: .destructive) {
        isRemoving = true
        Task {
          await state.removeCustomToken(id: token.id)
          isRemoving = false
          if self.token == nil { dismiss() }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Scans stop looking for this token on this device.")
    }
  }
}

/// Add forms are their own sheet; edit forms are pushed inside the detail
/// sheet, so a second sheet never stacks on the first.
private struct TokensFormContainer<Content: View>: View {
  var title: String
  var embedded: Bool
  var content: Content

  init(title: String, embedded: Bool, @ViewBuilder content: () -> Content) {
    self.title = title
    self.embedded = embedded
    self.content = content()
  }

  var body: some View {
    if embedded {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          content
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 32)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .scrollDismissesKeyboard(.interactively)
      .background(AtlasTheme.canvas)
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .atlasKeyboardDoneButton()
    } else {
      IOSFormSheet(title: title) {
        content
      }
    }
  }
}

/// Detail sheets show saved records, so they close with "Done" rather than
/// the add sheets' "Cancel"; otherwise the same chrome as `IOSFormSheet`.
private struct TokensDetailScaffold<Content: View>: View {
  @Environment(\.dismiss) private var dismiss
  var title: String
  /// Leading "Edit" action, visible at the medium detent where the body's
  /// own buttons may be below the fold.
  var onEdit: (() -> Void)?
  var content: Content

  init(title: String, onEdit: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.onEdit = onEdit
    self.content = content()
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          content
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 32)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .background(AtlasTheme.canvas)
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(AtlasTheme.canvas, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
        if let onEdit {
          ToolbarItem(placement: .cancellationAction) {
            Button("Edit", action: onEdit)
          }
        }
      }
    }
    .presentationDragIndicator(.visible)
  }
}

private struct TokensDetailHeader: View {
  var symbol: String
  var title: String
  var subtitle: String
  var isEnabled: Bool

  var body: some View {
    HStack(spacing: 14) {
      TokenMonogram(symbol: symbol, size: 52)
        .opacity(isEnabled ? 1 : 0.45)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.title2.weight(.semibold))
          .foregroundStyle(AtlasTheme.ink)
          .monospacedDigit()
          .fixedSize(horizontal: false, vertical: true)
        Text(isEnabled ? subtitle : "\(subtitle) · Paused")
          .font(.subheadline)
          .foregroundStyle(AtlasTheme.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct TokensDetailRow: View {
  var title: String
  var value: String
  var isIdentifier = false

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        titleText
        Spacer(minLength: 12)
        valueText
          .multilineTextAlignment(.trailing)
          .lineLimit(1)
      }
      VStack(alignment: .leading, spacing: 3) {
        titleText
        valueText
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 48)
    .accessibilityElement(children: .combine)
  }

  private var titleText: some View {
    Text(title)
      .font(.callout)
      .foregroundStyle(AtlasTheme.ink3)
  }

  private var valueText: some View {
    Text(value)
      .font(isIdentifier ? .callout.monospaced() : .callout.weight(.medium))
      .foregroundStyle(AtlasTheme.ink)
      .textSelection(.enabled)
  }
}

private struct TokensDetailDivider: View {
  var body: some View {
    Divider().overlay(AtlasTheme.ruleSoft).padding(.leading, 16)
  }
}

// MARK: - Form field

private enum TokensFieldKind {
  /// Contract addresses, mints, and registry IDs: never corrected or filled.
  case identifier
  /// Ticker symbols: uppercase keyboard, no correction.
  case symbol
  /// Human-readable names: keep the user's casing, no correction.
  case name
  /// Amounts and prices.
  case decimal
  /// Whole numbers such as token decimals.
  case integer
}

/// Visible label above a field. The visible title (or an explicit label such
/// as "Total value, USD") is also the field's accessible name, so VoiceOver
/// never falls back to the shared placeholder (F05).
private struct TokensFormField: View {
  var title: String
  var detail: String? = nil
  var placeholder: String
  var kind: TokensFieldKind
  var accessibilityLabel: String? = nil
  var accessibilityHint: String? = nil
  @Binding var text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ViewThatFits(in: .horizontal) {
        FieldLabel(title, detail: detail)
        VStack(alignment: .leading, spacing: 2) {
          FieldLabel(title)
          if let detail {
            Text(detail)
              .font(.caption)
              .foregroundStyle(AtlasTheme.ink3)
          }
        }
      }
      .accessibilityHidden(true)
      field
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityHint(accessibilityHint ?? "")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var field: some View {
    let base = TextField(placeholder, text: $text)
      .textFieldStyle(AtlasTextFieldStyle())
    switch kind {
    case .identifier:
      base.atlasIdentifierInput()
    case .symbol:
      base
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .keyboardType(.asciiCapable)
    case .name:
      base.autocorrectionDisabled()
    case .decimal:
      base.atlasDecimalInput()
    case .integer:
      base
        .keyboardType(.numberPad)
        .autocorrectionDisabled()
    }
  }
}

// MARK: - Row chrome

/// Full-width destructive action for detail sheets.
private struct TokensDestructiveButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.semibold))
      .foregroundStyle(AtlasTheme.loss)
      .padding(.horizontal, 14)
      .background(AtlasTheme.loss.opacity(configuration.isPressed ? 0.16 : 0.08))
      .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
      .opacity(isEnabled ? 1 : 0.5)
      .scaleEffect(configuration.isPressed && isEnabled ? 0.985 : 1)
      .animation(
        AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
        value: configuration.isPressed
      )
  }
}

/// Compact-page stand-in for `List` swipe actions, because the page scrolls in
/// a `ScrollView` where a nested `List` has no intrinsic height. Tapping the
/// leading region opens the record; dragging it left reveals a Remove
/// control; the trailing controls keep their own gestures. The drag is
/// simultaneous with the scroll view and locks to an axis on first movement,
/// so vertical scrolling is never blocked. Assistive technologies get the
/// same actions as named accessibility actions, so they never depend on the
/// swipe.
private struct TokensSwipeRow<Leading: View, Trailing: View>: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  var removeAccessibilityLabel: String
  var onOpen: () -> Void
  var onRemove: () -> Void
  @ViewBuilder var leading: () -> Leading
  @ViewBuilder var trailing: () -> Trailing

  @State private var offset: CGFloat = 0
  @State private var isOpen = false
  @State private var lockedAxis: Axis?
  @GestureState private var isDragging = false

  private let actionWidth: CGFloat = 88

  var body: some View {
    HStack(spacing: 12) {
      leading()
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
          if isOpen { settle(open: false) } else { onOpen() }
        }
        .simultaneousGesture(dragGesture)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows details.")
        .accessibilityAction(.default) { onOpen() }
        .accessibilityAction(named: Text("Remove")) { onRemove() }
      trailing()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(minHeight: 64)
    .background(AtlasTheme.surface)
    .offset(x: offset)
    .background(alignment: .trailing) {
      removeControl
    }
    .clipped()
    .onChange(of: isDragging) { _, dragging in
      guard !dragging else { return }
      lockedAxis = nil
      settle(open: isOpen)
    }
  }

  private var removeControl: some View {
    Button(role: .destructive) {
      settle(open: false)
      onRemove()
    } label: {
      VStack(spacing: 4) {
        Image(systemName: "trash")
          .font(.body.weight(.semibold))
        Text("Remove")
          .font(.caption2.weight(.semibold))
      }
      .foregroundStyle(.white)
      .frame(width: actionWidth)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(AtlasTheme.loss)
    .allowsHitTesting(isOpen)
    .accessibilityHidden(!isOpen)
    .accessibilityLabel(removeAccessibilityLabel)
  }

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 12, coordinateSpace: .local)
      .updating($isDragging) { _, dragging, _ in
        dragging = true
      }
      .onChanged { value in
        guard isEnabled else { return }
        let translation = value.translation
        if lockedAxis == nil {
          lockedAxis = abs(translation.width) > abs(translation.height) ? .horizontal : .vertical
        }
        guard lockedAxis == .horizontal else { return }
        let base: CGFloat = isOpen ? -actionWidth : 0
        offset = min(0, max(-actionWidth, base + translation.width))
      }
      .onEnded { value in
        guard isEnabled, lockedAxis == .horizontal else { return }
        let base: CGFloat = isOpen ? -actionWidth : 0
        let projected = base + value.predictedEndTranslation.width
        settle(open: projected < -actionWidth / 2)
      }
  }

  private func settle(open: Bool) {
    withAnimation(AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion)) {
      isOpen = open
      offset = open ? -actionWidth : 0
    }
  }
}
