import AddressAtlasCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Wallets

/// Saved wallets, with a switch to the Tokens pane (custom tokens and manual
/// holdings). Saved items come first; the add form sits under them.
struct WalletsView: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: MacNavigationModel
  @State private var address = ""
  @FocusState private var addressFocused: Bool
  @Environment(\.macScrollTo) private var scrollTo

  private var hasAddressInput: Bool {
    !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    MacPage(
      "Wallets",
      trailing: {
        MacChipPicker(
          label: "Show", options: MacWalletsPane.allCases,
          selection: $navigation.walletsPane, title: { $0.rawValue })
      }
    ) {
      switch navigation.walletsPane {
      case .wallets: walletsPane
      case .tokens: TokenAllowlistView()
      }
    }
    .onAppear { focusIfRequested() }
    .onChange(of: navigation.pendingAction) { _, _ in focusIfRequested() }
  }

  private func focusIfRequested() {
    guard navigation.consume(.focusWalletAddress) else { return }
    scrollTo(Self.addFormID)
    addressFocused = true
  }

  static let addFormID = "add-wallet"

  @ViewBuilder
  private var walletsPane: some View {
    if state.document.wallets.isEmpty {
      MacEmptyState(
        "No wallets yet",
        copy: "Add a wallet address or an exchange to see what you hold.",
        systemImage: "wallet.pass"
      ) {
        Button {
          navigation.go(.exchanges)
        } label: {
          Label("Connect exchange", systemImage: "building.columns")
        }
        .buttonStyle(MacSecondaryButtonStyle())
      }
    } else {
      MacRowList(state.document.wallets) { wallet in
        WalletRow(wallet: wallet)
      }
    }
    addForm
  }

  private var addForm: some View {
    Surface {
      VStack(alignment: .leading, spacing: 14) {
        MacHeading("Add a wallet")
        AdaptiveStack(horizontalSpacing: 12) {
          TextField("0x\u{2026}, bc1\u{2026}, or any supported address", text: $address)
            .textFieldStyle(AtlasTextFieldStyle())
            .focused($addressFocused)
            .onSubmit(addWallet)
            .accessibilityLabel("Public wallet address")
          Button {
            addWallet()
          } label: {
            Label("Add wallet", systemImage: "plus")
          }
          .buttonStyle(MacPrimaryButtonStyle())
          .disabled(!hasAddressInput)
        }
        Text("Public addresses only.")
          .font(AtlasTheme.font(.label, .caption))
          .foregroundStyle(AtlasTheme.ink3)
      }
    }
    .id(Self.addFormID)
    .disabled(state.vaultEditsDisabled)
  }

  private func addWallet() {
    guard hasAddressInput else { return }
    Task {
      if await state.addWallet(address: address) {
        address = ""
      }
    }
  }
}

struct WalletRow: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.atlasTheme) private var tokens
  @State private var confirmingRemoval = false
  @FocusState private var labelIsFocused: Bool
  var wallet: WalletRecord

  var body: some View {
    HStack(spacing: 14) {
      CoinMark(symbol: networkSymbol, size: 38)

      HStack(spacing: 7) {
        TextField("Wallet name", text: labelDraftBinding)
          .textFieldStyle(.plain)
          .font(AtlasTheme.font(.body, .body, weight: .semibold))
          .focused($labelIsFocused)
          .accessibilityLabel("Name of wallet \(AtlasAccessibility.walletIdentity(wallet))")
          .accessibilityHint("Edit the name shown for this wallet on this Mac.")
          .onSubmit(commitLabel)
          .onChange(of: labelIsFocused) { _, isFocused in
            if !isFocused { commitLabel() }
          }
        Image(systemName: "pencil")
          .font(.caption)
          .foregroundStyle(labelIsFocused ? AtlasTheme.accent : AtlasTheme.ink3)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 9)
      .frame(width: 190)
      .frame(minHeight: 36)
      .background(labelIsFocused ? AtlasTheme.accentSoft : Color.clear)
      .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous)
          .stroke(labelIsFocused ? AtlasTheme.focusRing : AtlasTheme.ruleSoft, lineWidth: labelIsFocused ? 2 : 1)
      }

      Text(wallet.address)
        .font(tokens.font(.mono, .caption))
        .foregroundStyle(AtlasTheme.ink2)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)

      MacBadge(wallet.chainKind == .evm ? "EVM" : wallet.chainKind.rawValue.capitalized)

      Button(role: .destructive) {
        confirmingRemoval = true
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(IconButtonStyle())
      .accessibilityLabel("Remove wallet \(AtlasAccessibility.walletIdentity(wallet))")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 66)
    .confirmationDialog(
      "Remove \(AtlasAccessibility.walletIdentity(wallet))?",
      isPresented: $confirmingRemoval,
      titleVisibility: .visible
    ) {
      Button("Remove wallet", role: .destructive) {
        Task { await state.removeWallet(id: wallet.id) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The address is removed from this Mac. Saved snapshots are unchanged.")
    }
    .onDisappear(perform: commitLabel)
    .disabled(state.vaultEditsDisabled)
  }

  /// A symbol whose chart colour is the wallet's network colour.
  private var networkSymbol: String {
    switch wallet.chainKind {
    case .bitcoin: "BTC"
    case .evm: "ETH"
    case .solana: "SOL"
    case .cosmos: "ATOM"
    case .tron: "TRX"
    case .xrp: "XRP"
    case .exchange: "?"
    }
  }

  private func commitLabel() {
    Task { await state.commitWalletLabelDraft(id: wallet.id) }
  }

  private var labelDraftBinding: Binding<String> {
    Binding(
      get: { state.walletLabelDraft(for: wallet) },
      set: { _ = state.setWalletLabelDraft(id: wallet.id, label: $0) }
    )
  }
}

// MARK: - Tokens

/// The Tokens pane of Wallets: tokens that are not in the built-in registry,
/// and balances that cannot be scanned (manual holdings).
struct TokenAllowlistView: View {
  @EnvironmentObject private var state: AppState
  @State private var chainKind: ChainFamily = .evm
  @State private var chainId = "ethereum"
  @State private var address = ""
  @State private var symbol = ""
  @State private var name = ""
  @State private var decimals = "18"
  @State private var coinGeckoId = ""
  @State private var priceUsd = ""
  @State private var manualSymbol = ""
  @State private var manualAmount = ""
  @State private var manualValue = ""

  private var hasRequiredTokenInput: Bool {
    !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !decimals.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var isBuiltInToken: Bool {
    AppState.builtInToken(
      chainKind: chainKind,
      chainId: chainKind == .solana ? "solana" : chainId,
      address: address
    ) != nil
  }

  private var hasRequiredManualHoldingInput: Bool {
    !manualSymbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !manualAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !manualValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    customTokens
    manualHoldings
  }

  // MARK: Custom tokens

  @ViewBuilder
  private var customTokens: some View {
    VStack(alignment: .leading, spacing: 12) {
      MacHeading("Custom tokens") {
        Text(MacFormat.count(state.document.customTokens.count, "token"))
          .font(AtlasTheme.font(.label, .callout, weight: .medium))
          .foregroundStyle(AtlasTheme.ink3)
      }
      if state.document.customTokens.isEmpty {
        MacNote(
          text: "Tokens in the built-in list are scanned automatically. Add one here if yours isn\u{2019}t.",
          tone: .info)
      } else {
        MacRowList(state.document.customTokens) { token in
          TokenRow(token: token)
        }
      }
    }

    Surface {
      VStack(alignment: .leading, spacing: 18) {
        MacHeading("Add a token")
        CustomTokenFormFields(
          chainKind: $chainKind,
          chainId: $chainId,
          address: $address,
          symbol: $symbol,
          name: $name,
          decimals: $decimals,
          coinGeckoId: $coinGeckoId,
          priceUsd: $priceUsd
        )
        Text(
          "The contract address decides which token is scanned, not the symbol or name. Check it with a source you trust."
        )
        .font(AtlasTheme.font(.label, .caption))
        .foregroundStyle(AtlasTheme.ink3)
        Button {
          addToken()
        } label: {
          Label("Add token", systemImage: "plus")
        }
        .buttonStyle(MacPrimaryButtonStyle())
        .disabled(!hasRequiredTokenInput || isBuiltInToken)
      }
    }
    .disabled(state.vaultEditsDisabled)
  }

  private func addToken() {
    Task {
      if await state.addCustomToken(
        chainKind: chainKind,
        chainId: chainKind == .solana ? "solana" : chainId,
        address: address,
        symbol: symbol,
        name: name,
        decimals: decimals,
        coinGeckoId: coinGeckoId,
        priceUsd: priceUsd
      ) {
        address = ""
        symbol = ""
        name = ""
        decimals = chainKind == .evm ? "18" : "6"
        coinGeckoId = ""
        priceUsd = ""
      }
    }
  }

  // MARK: Manual holdings

  @ViewBuilder
  private var manualHoldings: some View {
    ManualHoldingList()

    Surface {
      VStack(alignment: .leading, spacing: 18) {
        MacHeading("Add a manual holding")
        ManualHoldingFormFields(symbol: $manualSymbol, amount: $manualAmount, value: $manualValue)
        Text("For balances that can\u{2019}t be scanned. They count in the next scan.")
          .font(AtlasTheme.font(.label, .caption))
          .foregroundStyle(AtlasTheme.ink3)
        Button {
          Task {
            if await state.addManualHolding(
              symbol: manualSymbol,
              amount: manualAmount,
              valueUsd: manualValue
            ) {
              manualSymbol = ""
              manualAmount = ""
              manualValue = ""
            }
          }
        } label: {
          Label("Add holding", systemImage: "plus")
        }
        .buttonStyle(MacPrimaryButtonStyle())
        .disabled(!hasRequiredManualHoldingInput)
      }
    }
    .disabled(state.vaultEditsDisabled)
  }
}

struct TokenRow: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.atlasTheme) private var tokens
  @State private var confirmingRemoval = false
  @State private var editing = false
  var token: CustomTokenRecord

  var body: some View {
    HStack(spacing: 14) {
      CoinMark(symbol: token.symbol, size: 38)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(token.symbol)
            .font(AtlasTheme.font(.body, .body, weight: .semibold))
          Text(token.name)
            .font(AtlasTheme.font(.body, .callout))
            .foregroundStyle(AtlasTheme.ink2)
            .lineLimit(1)
        }
        Text("\(token.chainId) \u{00B7} \(token.address)")
          .font(tokens.font(.mono, .caption))
          .foregroundStyle(AtlasTheme.ink3)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      MacBadge(
        token.enabled ? "On" : "Paused",
        color: token.enabled ? AtlasTheme.gain : AtlasTheme.ink3)
      Toggle(
        "Scan \(token.symbol)",
        isOn: Binding(
          get: {
            token.enabled
          },
          set: { _ in
            Task { await state.toggleCustomToken(id: token.id) }
          })
      )
      .labelsHidden()
      .accessibilityLabel(
        "\(token.enabled ? "Pause" : "Resume") token \(AtlasAccessibility.tokenIdentity(token))"
      )
      Button {
        editing = true
      } label: {
        Image(systemName: "pencil")
      }
      .buttonStyle(IconButtonStyle())
      .help("Edit token")
      .accessibilityLabel("Edit token \(AtlasAccessibility.tokenIdentity(token))")
      Button(role: .destructive) {
        confirmingRemoval = true
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(IconButtonStyle())
      .accessibilityLabel("Remove token \(AtlasAccessibility.tokenIdentity(token))")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 66)
    .confirmationDialog(
      "Remove \(AtlasAccessibility.tokenIdentity(token))?",
      isPresented: $confirmingRemoval,
      titleVisibility: .visible
    ) {
      Button("Remove token", role: .destructive) {
        Task { await state.removeCustomToken(id: token.id) }
      }
      Button("Cancel", role: .cancel) {}
    }
    .disabled(state.vaultEditsDisabled)
    // Presented outside `.disabled` so Cancel stays usable if edits pause.
    .sheet(isPresented: $editing) {
      CustomTokenEditSheet(token: token)
        .environmentObject(state)
    }
  }
}

struct ManualHoldingList: View {
  @EnvironmentObject private var state: AppState
  @State private var pendingRemoval: UUID?
  @State private var editingHolding: ManualHoldingRecord?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      MacHeading("Manual holdings") {
        Text(MacFormat.count(state.document.manualHoldings.count, "holding"))
          .font(AtlasTheme.font(.label, .callout, weight: .medium))
          .foregroundStyle(AtlasTheme.ink3)
      }
      if state.document.manualHoldings.isEmpty {
        MacNote(
          text: "Add balances that can\u{2019}t be scanned, like coins on a paper wallet.",
          tone: .info)
      } else {
        MacRowList(state.document.manualHoldings) { holding in
          row(holding)
        }
      }
    }
    .confirmationDialog(
      "Remove \(pendingRemovalIdentity)?",
      isPresented: Binding(
        get: { pendingRemoval != nil },
        set: { if !$0 { pendingRemoval = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Remove holding", role: .destructive) {
        if let pendingRemoval {
          Task { await state.removeManualHolding(id: pendingRemoval) }
        }
        pendingRemoval = nil
      }
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
    }
    .disabled(state.vaultEditsDisabled)
    // Presented outside `.disabled` so Cancel stays usable if edits pause.
    .sheet(item: $editingHolding) { holding in
      ManualHoldingEditSheet(holding: holding)
        .environmentObject(state)
    }
  }

  private func row(_ holding: ManualHoldingRecord) -> some View {
    HStack(spacing: 14) {
      CoinMark(symbol: holding.symbol, size: 38)
      VStack(alignment: .leading, spacing: 3) {
        Text("\(holding.symbol) \u{00B7} \(holding.label)")
          .font(AtlasTheme.font(.body, .body, weight: .semibold))
          .lineLimit(1)
        Text(
          "\(holding.amount.formatted(.number.locale(AtlasFormatting.locale))) \u{00B7} \(money(holding.valueUsd))"
        )
        .font(AtlasTheme.font(.label, .caption))
        .foregroundStyle(AtlasTheme.ink3)
      }
      Spacer()
      Toggle(
        "Count \(holding.symbol)",
        isOn: Binding(
          get: {
            holding.enabled
          },
          set: { _ in
            Task { await state.toggleManualHolding(id: holding.id) }
          })
      )
      .labelsHidden()
      .accessibilityLabel(
        "\(holding.enabled ? "Pause" : "Resume") manual holding \(AtlasAccessibility.manualHoldingIdentity(holding))"
      )
      Button {
        editingHolding = holding
      } label: {
        Image(systemName: "pencil")
      }
      .buttonStyle(IconButtonStyle())
      .help("Edit manual holding")
      .accessibilityLabel(
        "Edit manual holding \(AtlasAccessibility.manualHoldingIdentity(holding))"
      )
      Button(role: .destructive) {
        pendingRemoval = holding.id
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(IconButtonStyle())
      .accessibilityLabel(
        "Remove manual holding \(AtlasAccessibility.manualHoldingIdentity(holding))"
      )
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(minHeight: 60)
  }

  private var pendingRemovalIdentity: String {
    guard let pendingRemoval,
      let holding = state.document.manualHoldings.first(where: { $0.id == pendingRemoval })
    else { return "this manual holding" }
    return AtlasAccessibility.manualHoldingIdentity(holding)
  }
}

// MARK: - Shared add/edit form fields

private struct PortfolioFormField: View {
  var title: String
  var detail: String?
  var placeholder: String
  @Binding var text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      FieldLabel(title, detail: detail)
      TextField(placeholder, text: $text)
        .textFieldStyle(AtlasTextFieldStyle())
    }
    .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
  }
}

/// Custom-token fields shared by the add form and the edit sheet.
private struct CustomTokenFormFields: View {
  @Binding var chainKind: ChainFamily
  @Binding var chainId: String
  @Binding var address: String
  @Binding var symbol: String
  @Binding var name: String
  @Binding var decimals: String
  @Binding var coinGeckoId: String
  @Binding var priceUsd: String

  /// The shared state refuses a custom copy of a built-in registry token
  /// because the scanner would ignore it; say so before the user submits.
  private var builtIn: TokenConfig? {
    AppState.builtInToken(
      chainKind: chainKind,
      chainId: chainKind == .solana ? "solana" : chainId,
      address: address
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      AdaptiveStack(horizontalSpacing: 12, verticalSpacing: 14) {
        VStack(alignment: .leading, spacing: 8) {
          FieldLabel("Network family")
          Picker("Network family", selection: $chainKind) {
            Text("EVM").tag(ChainFamily.evm)
            Text("Solana").tag(ChainFamily.solana)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(minWidth: 170)
        }
        VStack(alignment: .leading, spacing: 8) {
          FieldLabel("Network")
          Picker("Network", selection: $chainId) {
            if chainKind == .evm {
              ForEach(ChainRegistry.evmChains, id: \.id) { chain in
                Text(chain.name).tag(chain.id)
              }
            } else {
              Text("Solana").tag("solana")
            }
          }
          .labelsHidden()
          .accessibilityLabel("Network")
          .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        FieldLabel(chainKind == .evm ? "Token contract" : "Token mint")
        TextField(
          chainKind == .evm ? "0x\u{2026} contract address" : "Solana mint address",
          text: $address
        )
        .textFieldStyle(AtlasTextFieldStyle())
        if let builtIn {
          Label(
            "\(builtIn.symbol) is built in and scanned automatically; a custom copy would be ignored.",
            systemImage: "checkmark.seal"
          )
          .font(AtlasTheme.font(.label, .caption))
          .foregroundStyle(AtlasTheme.warning)
          .accessibilityLabel(
            "Notice: \(builtIn.symbol) is built in and scanned automatically; a custom copy would be ignored."
          )
        }
      }

      AdaptiveStack(horizontalSpacing: 12, verticalSpacing: 14) {
        PortfolioFormField(title: "Symbol", placeholder: "USDC", text: $symbol)
        PortfolioFormField(title: "Token name", placeholder: "USD Coin", text: $name)
        PortfolioFormField(
          title: "Decimals", placeholder: chainKind == .evm ? "18" : "6", text: $decimals)
      }

      AdaptiveStack(horizontalSpacing: 12, verticalSpacing: 14) {
        PortfolioFormField(
          title: "CoinGecko ID",
          detail: "Optional",
          placeholder: "usd-coin",
          text: $coinGeckoId
        )
        PortfolioFormField(
          title: "Manual USD price",
          detail: "Optional",
          placeholder: "0.00",
          text: $priceUsd
        )
      }
    }
    .onChange(of: chainKind) { _, next in
      chainId = next == .solana ? "solana" : "ethereum"
      decimals = next == .solana ? "6" : "18"
    }
  }
}

/// Manual-holding fields shared by the add form and the edit sheet.
private struct ManualHoldingFormFields: View {
  @Binding var symbol: String
  @Binding var amount: String
  @Binding var value: String

  var body: some View {
    AdaptiveStack(horizontalSpacing: 12, verticalSpacing: 14) {
      PortfolioFormField(title: "Asset symbol", placeholder: "BTC", text: $symbol)
      PortfolioFormField(title: "Amount", placeholder: "0.00", text: $amount)
      PortfolioFormField(title: "Total value (USD)", placeholder: "0.00", text: $value)
    }
  }
}

// MARK: - Edit sheets

enum PortfolioEditing {
  /// A stored number in the current locale without grouping, so it parses
  /// back through `UserInputValidation.nonnegativeFiniteNumber` (which uses
  /// `Locale.current`) unchanged when the edit is saved.
  static func editableNumber(_ value: Double, locale: Locale = .current) -> String {
    value.formatted(
      .number.grouping(.never).precision(.fractionLength(0...12)).locale(locale))
  }
}

/// Sheet chrome shared by the edit flows: a title, fields, an inline error from
/// `state.error`, and Cancel/Save. Errors are cleared on open, on every edit,
/// and on close so a stale message never describes the current input.
private struct VaultRecordEditSheet<Fields: View>: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.dismiss) private var dismiss
  @State private var isSaving = false

  var title: String
  var subtitle: String
  var canSave: Bool
  var editedValues: [String]
  var save: () async -> Bool
  @ViewBuilder var fields: () -> Fields

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(AtlasTheme.font(.display, .title2, weight: .bold))
          .accessibilityAddTraits(.isHeader)
        Text(subtitle)
          .font(AtlasTheme.font(.body, .callout))
          .foregroundStyle(AtlasTheme.ink3)
      }

      fields()
        .disabled(state.vaultEditsDisabled || isSaving)

      if state.vaultEditsDisabled && !isSaving {
        InfoCallout(
          title: "Editing is paused",
          copy: "Wait for the scan, sync, or save to finish, then save again.",
          tone: .warning
        )
      }

      if !state.error.isEmpty {
        InfoCallout(title: "Not saved", copy: state.error, tone: .danger)
          .accessibilityLabel("Error: \(state.error)")
      }

      HStack(spacing: 10) {
        Spacer()
        Button("Cancel") { dismiss() }
          .buttonStyle(MacSecondaryButtonStyle())
          .keyboardShortcut(.cancelAction)
          .disabled(isSaving)
        Button {
          submit()
        } label: {
          Label("Save", systemImage: "checkmark")
        }
        .buttonStyle(MacPrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(!canSave || isSaving || state.vaultEditsDisabled)
      }
    }
    .padding(24)
    .frame(minWidth: 560, idealWidth: 600, maxWidth: 680, alignment: .topLeading)
    .background(AtlasTheme.canvas)
    .interactiveDismissDisabled(isSaving)
    .onAppear { clearError() }
    .onDisappear { clearError() }
    .onChange(of: editedValues) { _, _ in clearError() }
  }

  private func clearError() {
    if !state.error.isEmpty { state.error = "" }
  }

  private func submit() {
    guard !isSaving, canSave, !state.vaultEditsDisabled else { return }
    clearError()
    isSaving = true
    Task {
      let saved = await save()
      isSaving = false
      if saved { dismiss() }
    }
  }
}

struct CustomTokenEditSheet: View {
  @EnvironmentObject private var state: AppState
  private let tokenID: UUID
  private let originalSymbol: String
  @State private var chainKind: ChainFamily
  @State private var chainId: String
  @State private var address: String
  @State private var symbol: String
  @State private var name: String
  @State private var decimals: String
  @State private var coinGeckoId: String
  @State private var priceUsd: String

  init(token: CustomTokenRecord) {
    tokenID = token.id
    originalSymbol = token.symbol
    _chainKind = State(initialValue: token.chainKind)
    _chainId = State(initialValue: token.chainId)
    _address = State(initialValue: token.address)
    _symbol = State(initialValue: token.symbol)
    _name = State(initialValue: token.name)
    _decimals = State(initialValue: "\(token.decimals)")
    _coinGeckoId = State(initialValue: token.coinGeckoId ?? "")
    _priceUsd = State(
      initialValue: token.priceUsd.map { PortfolioEditing.editableNumber($0) } ?? "")
  }

  private var effectiveChainId: String { chainKind == .solana ? "solana" : chainId }

  private var canSave: Bool {
    !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !decimals.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && AppState.builtInToken(
        chainKind: chainKind, chainId: effectiveChainId, address: address) == nil
  }

  var body: some View {
    VaultRecordEditSheet(
      title: "Edit token",
      subtitle: "\(originalSymbol). Changes apply from the next scan.",
      canSave: canSave,
      editedValues: [
        chainKind.rawValue, chainId, address, symbol, name, decimals, coinGeckoId, priceUsd,
      ],
      save: {
        await state.updateCustomToken(
          id: tokenID,
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
    ) {
      CustomTokenFormFields(
        chainKind: $chainKind,
        chainId: $chainId,
        address: $address,
        symbol: $symbol,
        name: $name,
        decimals: $decimals,
        coinGeckoId: $coinGeckoId,
        priceUsd: $priceUsd
      )
    }
  }
}

struct ManualHoldingEditSheet: View {
  @EnvironmentObject private var state: AppState
  private let holdingID: UUID
  private let originalSymbol: String
  @State private var symbol: String
  @State private var amount: String
  @State private var value: String

  init(holding: ManualHoldingRecord) {
    holdingID = holding.id
    originalSymbol = holding.symbol
    _symbol = State(initialValue: holding.symbol)
    _amount = State(initialValue: PortfolioEditing.editableNumber(holding.amount))
    _value = State(initialValue: PortfolioEditing.editableNumber(holding.valueUsd))
  }

  private var canSave: Bool {
    !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VaultRecordEditSheet(
      title: "Edit manual holding",
      subtitle: "\(originalSymbol). Changes count in the next scan.",
      canSave: canSave,
      editedValues: [symbol, amount, value],
      save: {
        await state.updateManualHolding(
          id: holdingID, symbol: symbol, amount: amount, valueUsd: value)
      }
    ) {
      ManualHoldingFormFields(symbol: $symbol, amount: $amount, value: $value)
    }
  }
}
