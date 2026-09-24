import AddressAtlasCore
import SwiftUI

/// Custom token allowlist and manual (offline) holdings. Ports the macOS
/// `TokenAllowlistView` and the manual-holding half of `SnapshotsView` onto
/// the compact page: each section lists its saved records first, then the
/// form that adds one. Every mutation goes through the shared `AppState`,
/// which validates input, enforces the vault limits, and reports errors on
/// the status line.
struct TokensScreen: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    IOSPage(
      title: "Tokens",
      subtitle:
        "Add a verified contract or mint when an asset is not yet in the built-in registry, and record balances that cannot be scanned automatically. Everything stays in the encrypted vault on this device."
    ) {
      TokensCustomTokenSection()
      TokensManualHoldingSection()
    }
  }
}

// MARK: - Custom tokens

private struct TokensCustomTokenSection: View {
  @EnvironmentObject private var state: AppState
  @State private var chainKind: ChainFamily = .evm
  @State private var chainId = "ethereum"
  @State private var address = ""
  @State private var symbol = ""
  @State private var name = ""
  @State private var decimals = "18"
  @State private var coinGeckoId = ""
  @State private var priceUsd = ""
  @State private var isAdding = false

  private var tokens: [CustomTokenRecord] { state.document.customTokens }
  private var enabledCount: Int { tokens.filter(\.enabled).count }
  private var isAtLimit: Bool { tokens.count >= AppState.maximumCustomTokens }

  private var hasRequiredTokenInput: Bool {
    !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !decimals.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var selectedNetworkName: String {
    if chainKind == .solana { return "Solana" }
    return ChainRegistry.evmChains.first(where: { $0.id == chainId })?.name ?? chainId
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeader(
        title: "Custom tokens",
        meta: "\(enabledCount) enabled · \(tokens.count) of \(AppState.maximumCustomTokens)"
      )

      if tokens.isEmpty {
        EmptyState(
          title: "No custom tokens",
          systemImage: "tag",
          copy: "The built-in registry is still used during scans."
        )
      } else {
        Surface(padding: 0) {
          VStack(spacing: 0) {
            ForEach(tokens) { token in
              TokensCustomTokenRow(token: token)
              if token.id != tokens.last?.id {
                Divider().overlay(AtlasTheme.ruleSoft)
              }
            }
          }
        }
      }

      addTokenForm
    }
    .onChange(of: chainKind) { _, next in
      chainId = next == .solana ? "solana" : "ethereum"
      decimals = next == .solana ? "6" : "18"
    }
  }

  private var addTokenForm: some View {
    Surface {
      VStack(alignment: .leading, spacing: 18) {
        PanelHeader(
          title: "Add a custom token",
          subtitle: "Verify the contract or mint address before saving",
          systemImage: "tag.fill"
        )

        VStack(alignment: .leading, spacing: 8) {
          FieldLabel("Network family")
          Picker("Network family", selection: $chainKind) {
            Text("EVM").tag(ChainFamily.evm)
            Text("Solana").tag(ChainFamily.solana)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(minHeight: 44)
        }

        VStack(alignment: .leading, spacing: 8) {
          FieldLabel("Network")
          networkPicker
        }

        TokensFormField(
          title: chainKind == .evm ? "Token contract" : "Token mint",
          placeholder: chainKind == .evm ? "0x… contract address" : "Solana mint address",
          kind: .identifier,
          text: $address
        )

        AdaptiveStack(horizontalSpacing: 12, verticalSpacing: 14) {
          TokensFormField(title: "Symbol", placeholder: "USDC", kind: .symbol, text: $symbol)
          TokensFormField(
            title: "Decimals",
            placeholder: chainKind == .evm ? "18" : "6",
            kind: .decimal,
            text: $decimals
          )
        }

        TokensFormField(title: "Token name", placeholder: "USD Coin", kind: .name, text: $name)

        TokensFormField(
          title: "CoinGecko ID",
          detail: "Optional",
          placeholder: "usd-coin",
          kind: .identifier,
          text: $coinGeckoId
        )

        TokensFormField(
          title: "Manual USD price",
          detail: "Optional",
          placeholder: "0.00",
          kind: .decimal,
          text: $priceUsd
        )

        InfoCallout(
          title: "Contract addresses are authoritative",
          copy:
            "A misleading symbol or name cannot change which on-chain token is scanned. Confirm the address from a trusted source.",
          tone: .info
        )

        if isAtLimit {
          Text(
            "Limit reached: a vault holds at most \(AppState.maximumCustomTokens) custom tokens. Remove one before adding another."
          )
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
          .fixedSize(horizontal: false, vertical: true)
        }

        Button {
          addToken()
        } label: {
          HStack(spacing: 8) {
            if isAdding {
              ProgressView()
                .controlSize(.small)
                .tint(AtlasTheme.paper)
            }
            Label("Add token", systemImage: "plus")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        .disabled(!hasRequiredTokenInput || isAdding || isAtLimit)
      }
    }
    .disabled(state.vaultEditsDisabled)
  }

  /// A `Menu` wrapping the picker keeps the whole 44pt field row tappable,
  /// which the bare `.menu` picker style does not guarantee.
  private var networkPicker: some View {
    Menu {
      Picker("Network", selection: $chainId) {
        if chainKind == .evm {
          ForEach(ChainRegistry.evmChains, id: \.id) { chain in
            Text(chain.name).tag(chain.id)
          }
        } else {
          Text("Solana").tag("solana")
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

  private func addToken() {
    guard !isAdding else { return }
    isAdding = true
    Task {
      let added = await state.addCustomToken(
        chainKind: chainKind,
        chainId: chainKind == .solana ? "solana" : chainId,
        address: address,
        symbol: symbol,
        name: name,
        decimals: decimals,
        coinGeckoId: coinGeckoId,
        priceUsd: priceUsd
      )
      if added {
        address = ""
        symbol = ""
        name = ""
        decimals = chainKind == .evm ? "18" : "6"
        coinGeckoId = ""
        priceUsd = ""
      }
      isAdding = false
    }
  }
}

private struct TokensCustomTokenRow: View {
  @EnvironmentObject private var state: AppState
  @State private var confirmingRemoval = false
  @State private var pendingEnabled: Bool?
  @State private var isRemoving = false
  var token: CustomTokenRecord

  private var identity: String { AtlasAccessibility.tokenIdentity(token) }
  /// Optimistic switch position while the vault write is in flight, so the
  /// control does not snap back for a frame before the document updates.
  private var isEnabled: Bool { pendingEnabled ?? token.enabled }

  var body: some View {
    TokensSwipeRow(
      removeAccessibilityLabel: "Remove token \(identity)",
      onRemove: { confirmingRemoval = true }
    ) {
      HStack(spacing: 14) {
        Text(String(token.symbol.prefix(1)).uppercased())
          .font(.caption.weight(.bold))
          .foregroundStyle(AtlasTheme.accent)
          .frame(width: 38, height: 38)
          .background(AtlasTheme.accent.opacity(0.10))
          .clipShape(Circle())
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(token.symbol)
              .font(.body.weight(.semibold))
            Text(token.name)
              .font(.subheadline)
              .foregroundStyle(AtlasTheme.ink2)
              .lineLimit(1)
          }
          HStack(spacing: 8) {
            Badge(
              isEnabled ? "Enabled" : "Paused",
              color: isEnabled ? AtlasTheme.gain : AtlasTheme.ink3
            )
            Text("\(token.chainId) · \(token.address)")
              .font(.caption.monospaced())
              .foregroundStyle(AtlasTheme.ink3)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
      }
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

      Button(role: .destructive) {
        confirmingRemoval = true
      } label: {
        if isRemoving {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "trash")
        }
      }
      .buttonStyle(TokensIconButtonStyle())
      .disabled(isRemoving)
      .accessibilityLabel("Remove token \(identity)")
      .accessibilityHint("Asks for confirmation before removing the token from this device.")
    }
    .confirmationDialog(
      "Remove \(identity)?",
      isPresented: $confirmingRemoval,
      titleVisibility: .visible
    ) {
      Button("Remove token", role: .destructive) {
        isRemoving = true
        Task {
          await state.removeCustomToken(id: token.id)
          isRemoving = false
        }
      }
      Button("Cancel", role: .cancel) {}
    }
    .disabled(state.vaultEditsDisabled)
  }
}

// MARK: - Manual holdings

private struct TokensManualHoldingSection: View {
  @EnvironmentObject private var state: AppState
  @State private var symbol = ""
  @State private var amount = ""
  @State private var value = ""
  @State private var isAdding = false

  private var holdings: [ManualHoldingRecord] { state.document.manualHoldings }
  private var enabledCount: Int { holdings.filter(\.enabled).count }
  private var isAtLimit: Bool { holdings.count >= AppState.maximumManualHoldings }

  private var hasRequiredManualHoldingInput: Bool {
    !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    VStack(alignment: .leading, spacing: 12) {
      SectionHeader(
        title: "Manual holdings",
        meta: "\(enabledCount) enabled · \(holdings.count) of \(AppState.maximumManualHoldings)"
      )

      if holdings.isEmpty {
        EmptyState(
          title: "No manual entries",
          systemImage: "pencil.and.list.clipboard",
          copy: "Add offline balances below."
        )
      } else {
        Surface(padding: 0) {
          VStack(spacing: 0) {
            ForEach(holdings) { holding in
              TokensManualHoldingRow(holding: holding)
              if holding.id != holdings.last?.id {
                Divider().overlay(AtlasTheme.ruleSoft)
              }
            }
          }
        }
      }

      addHoldingForm
    }
  }

  private var addHoldingForm: some View {
    Surface {
      VStack(alignment: .leading, spacing: 18) {
        PanelHeader(
          title: "Add an offline holding",
          subtitle: "Included in the next portfolio snapshot",
          systemImage: "pencil.and.list.clipboard"
        )

        TokensFormField(title: "Asset symbol", placeholder: "BTC", kind: .symbol, text: $symbol)

        AdaptiveStack(horizontalSpacing: 12, verticalSpacing: 14) {
          TokensFormField(title: "Amount", placeholder: "0.00", kind: .decimal, text: $amount)
          TokensFormField(
            title: "Total value (USD)", placeholder: "0.00", kind: .decimal, text: $value)
        }

        if let impliedPrice {
          Text(
            "Implied price: \(money(impliedPrice)) per \(symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unit" : symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())"
          )
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
        }

        if isAtLimit {
          Text(
            "Limit reached: a vault holds at most \(AppState.maximumManualHoldings) manual holdings. Remove one before adding another."
          )
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
          .fixedSize(horizontal: false, vertical: true)
        }

        Button {
          addHolding()
        } label: {
          HStack(spacing: 8) {
            if isAdding {
              ProgressView()
                .controlSize(.small)
                .tint(AtlasTheme.paper)
            }
            Label("Add holding", systemImage: "plus")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        .disabled(!hasRequiredManualHoldingInput || isAdding || isAtLimit)

        Text("Manual values are stored in the encrypted local vault.")
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
      }
    }
    .disabled(state.vaultEditsDisabled)
  }

  private func addHolding() {
    guard !isAdding else { return }
    isAdding = true
    Task {
      let added = await state.addManualHolding(symbol: symbol, amount: amount, valueUsd: value)
      if added {
        symbol = ""
        amount = ""
        value = ""
      }
      isAdding = false
    }
  }
}

private struct TokensManualHoldingRow: View {
  @EnvironmentObject private var state: AppState
  @State private var confirmingRemoval = false
  @State private var pendingEnabled: Bool?
  @State private var isRemoving = false
  var holding: ManualHoldingRecord

  private var identity: String { AtlasAccessibility.manualHoldingIdentity(holding) }
  private var isEnabled: Bool { pendingEnabled ?? holding.enabled }

  var body: some View {
    TokensSwipeRow(
      removeAccessibilityLabel: "Remove manual holding \(identity)",
      onRemove: { confirmingRemoval = true }
    ) {
      HStack(spacing: 12) {
        Image(systemName: "pencil.and.list.clipboard")
          .foregroundStyle(AtlasTheme.accent)
          .frame(width: 34, height: 34)
          .background(AtlasTheme.accent.opacity(0.09))
          .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text("\(holding.symbol) · \(holding.label)")
            .font(.body.weight(.semibold))
            .lineLimit(1)
          Text(
            "\(holding.amount.formatted(.number.locale(AtlasFormatting.locale))) · \(money(holding.valueUsd))"
          )
          .font(.subheadline)
          .foregroundStyle(AtlasTheme.ink3)
          .lineLimit(1)
        }
      }
    } trailing: {
      Toggle(
        "Enable \(holding.symbol)",
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

      Button(role: .destructive) {
        confirmingRemoval = true
      } label: {
        if isRemoving {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "trash")
        }
      }
      .buttonStyle(TokensIconButtonStyle())
      .disabled(isRemoving)
      .accessibilityLabel("Remove manual holding \(identity)")
      .accessibilityHint("Asks for confirmation before removing the holding from this device.")
    }
    .confirmationDialog(
      "Remove \(identity)?",
      isPresented: $confirmingRemoval,
      titleVisibility: .visible
    ) {
      Button("Remove holding", role: .destructive) {
        isRemoving = true
        Task {
          await state.removeManualHolding(id: holding.id)
          isRemoving = false
        }
      }
      Button("Cancel", role: .cancel) {}
    }
    .disabled(state.vaultEditsDisabled)
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
  /// Amounts, prices, and decimals.
  case decimal
}

private struct TokensFormField: View {
  var title: String
  var detail: String? = nil
  var placeholder: String
  var kind: TokensFieldKind
  @Binding var text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      FieldLabel(title, detail: detail)
      field
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
    }
  }
}

// MARK: - Row chrome

/// 44pt variant of the design system's `IconButtonStyle` for touch targets;
/// the shared style fixes its frame at 34pt for pointer-driven rows.
private struct TokensIconButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout)
      .foregroundStyle(
        isEnabled
          ? (configuration.isPressed ? AtlasTheme.loss : AtlasTheme.ink3)
          : AtlasTheme.rule
      )
      .frame(width: 44, height: 44)
      .background(configuration.isPressed ? AtlasTheme.loss.opacity(0.09) : Color.clear)
      .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous))
      .opacity(isEnabled ? 1 : 0.55)
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .animation(
        AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
        value: configuration.isPressed
      )
  }
}

/// Compact-page stand-in for `List` swipe actions, because the page scrolls in
/// a `ScrollView` where a nested `List` has no intrinsic height. The leading
/// text region can be dragged left to reveal a Remove control; the trailing
/// controls keep their own gestures. The drag is simultaneous with the scroll
/// view and locks to an axis on first movement, so vertical scrolling is never
/// blocked. The visible trash button remains the accessible path, so assistive
/// technologies never depend on the swipe.
private struct TokensSwipeRow<Leading: View, Trailing: View>: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  var removeAccessibilityLabel: String
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
          if isOpen { settle(open: false) }
        }
        .simultaneousGesture(dragGesture)
      trailing()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 70)
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
