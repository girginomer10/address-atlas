import AddressAtlasCore
import SwiftUI

/// Saved public addresses. Ported from the macOS `WalletsView`/`WalletRow`:
/// the same add rules, label-draft API, removal confirmation, and copy, laid
/// out as a paste-friendly add card and two-line touch rows.
struct WalletsScreen: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var addressInput = ""
  @State private var isAdding = false
  @FocusState private var addressFieldFocused: Bool

  private var trimmedInput: String {
    addressInput.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The whole paste is checked before it is split, so a seed phrase is
  /// refused as a unit instead of being tried word by word.
  private var inputLooksSafe: Bool {
    AddressDetection.isSafePublicAddress(trimmedInput)
  }

  /// One address per line, or several separated by commas, semicolons, or
  /// whitespace. `addWallet(address:)` still validates each one individually.
  private var parsedInput: AddressParseResult {
    guard !trimmedInput.isEmpty, inputLooksSafe else {
      return AddressParseResult(addresses: [], wasTruncated: false)
    }
    return AddressDetection.parseWithMetadata(trimmedInput, maxCount: AppState.maximumWallets)
  }

  private var canAdd: Bool {
    !isAdding && !parsedInput.addresses.isEmpty
  }

  private var addButtonTitle: String {
    let count = parsedInput.addresses.count
    return count > 1 ? "Add \(count) wallets" : "Add wallet"
  }

  var body: some View {
    IOSPage(
      title: "Wallets",
      subtitle:
        "Track public addresses across supported networks. Private keys never enter the app."
    ) {
      addCard

      SectionHeader(
        title: "Saved wallets",
        meta: "\(state.document.wallets.count) encrypted on this device")
      if state.document.wallets.isEmpty {
        EmptyState(
          title: "No wallets yet", systemImage: "wallet.pass",
          copy: "Add a public address to start scanning.")
      } else {
        Surface(padding: 0) {
          VStack(spacing: 0) {
            ForEach(state.document.wallets) { wallet in
              WalletsRow(wallet: wallet)
              if wallet.id != state.document.wallets.last?.id {
                Divider().overlay(AtlasTheme.ruleSoft)
              }
            }
          }
        }
        .animation(
          AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
          value: state.document.wallets.map(\.id)
        )
      }
    }
  }

  private var addCard: some View {
    Surface {
      VStack(alignment: .leading, spacing: 18) {
        PanelHeader(
          title: "Add a wallet",
          subtitle: "Paste a public address—never a seed phrase or private key",
          systemImage: "wallet.pass.fill"
        )
        VStack(alignment: .leading, spacing: 8) {
          FieldLabel("Public wallet address", detail: "one or more")
          TextField(
            "0x…, bc1…, solana, cosmos, or another supported address",
            text: $addressInput,
            axis: .vertical
          )
          .lineLimit(1...4)
          .textFieldStyle(AtlasTextFieldStyle())
          .atlasIdentifierInput()
          .submitLabel(.done)
          .focused($addressFieldFocused)
          .onSubmit(addWallets)
          .accessibilityLabel("Public wallet address")
          .accessibilityHint("Paste one address, or several separated by new lines or commas.")
          detectionHint
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
        Button(action: addWallets) {
          HStack(spacing: 8) {
            if isAdding {
              ProgressView()
                .controlSize(.small)
                .tint(AtlasTheme.paper)
            } else {
              Image(systemName: "plus")
            }
            Text(addButtonTitle)
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        .disabled(!canAdd)
        .accessibilityLabel(addButtonTitle)
        .accessibilityHint(
          isAdding
            ? "Saving the detected addresses."
            : "Saves the detected public addresses to this vault.")
        InfoCallout(
          title: "Watch-only access",
          copy:
            "Address Atlas reads public blockchain data. It cannot sign transactions or move funds.",
          tone: .success
        )
      }
    }
    .disabled(state.vaultEditsDisabled)
  }

  @ViewBuilder
  private var detectionHint: some View {
    if trimmedInput.isEmpty {
      Text("One address per line, or separate several with commas.")
        .foregroundStyle(AtlasTheme.ink3)
    } else if !inputLooksSafe {
      Label(
        "That looks like a seed phrase or private key. Only public addresses are accepted; nothing was saved.",
        systemImage: "exclamationmark.shield"
      )
      .foregroundStyle(AtlasTheme.loss)
    } else {
      Text(detectionSummary)
        .foregroundStyle(AtlasTheme.ink3)
    }
  }

  private var detectionSummary: String {
    let parsed = parsedInput
    let count = parsed.addresses.count
    guard count > 0 else { return "No address detected yet." }
    var networks: [String] = []
    for address in parsed.addresses {
      let network = Self.networkSummary(for: address)
      if !networks.contains(network) { networks.append(network) }
    }
    var summary =
      "\(count) address\(count == 1 ? "" : "es") detected · \(networks.joined(separator: ", "))."
    if parsed.wasTruncated {
      summary += " Only the first \(AppState.maximumWallets) are used."
    }
    return summary
  }

  private static func networkSummary(for address: String) -> String {
    let chains = AddressDetection.detectChains(for: address)
    guard let first = chains.first else { return "unrecognized network" }
    if chains.count > 1, chains.allSatisfy({ $0.family == .evm }) {
      return "EVM networks"
    }
    return first.name
  }

  /// Adds the detected addresses in order and stops at the first one the
  /// shared state rejects (its message is already on the status line). The
  /// unsaved remainder stays in the field so nothing is silently dropped.
  private func addWallets() {
    guard canAdd, !state.vaultEditsDisabled else { return }
    let addresses = parsedInput.addresses
    isAdding = true
    Task {
      var remaining = addresses[...]
      for address in addresses {
        guard await state.addWallet(address: address) else { break }
        remaining = remaining.dropFirst()
      }
      addressInput = remaining.joined(separator: "\n")
      if remaining.isEmpty {
        addressFieldFocused = false
      }
      isAdding = false
    }
  }
}

private struct WalletsRow: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var confirmingRemoval = false
  @State private var isRemoving = false
  @FocusState private var labelIsFocused: Bool
  var wallet: WalletRecord

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "wallet.pass.fill")
        .font(.body.weight(.semibold))
        .foregroundStyle(AtlasTheme.accent)
        .frame(width: 40, height: 40)
        .background(AtlasTheme.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 6) {
        labelField
        HStack(spacing: 8) {
          Text(wallet.address)
            .font(.caption.monospaced())
            .foregroundStyle(AtlasTheme.ink2)
            .lineLimit(1)
            .truncationMode(.middle)
          Badge(Self.chainBadge(for: wallet.chainKind))
            .fixedSize()
            .layoutPriority(1)
        }
      }

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
      .buttonStyle(WalletsIconButtonStyle())
      .disabled(isRemoving)
      .accessibilityLabel("Remove wallet \(AtlasAccessibility.walletIdentity(wallet))")
      .accessibilityHint("Asks for confirmation before removing this saved wallet.")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(minHeight: 72)
    .confirmationDialog(
      "Remove \(AtlasAccessibility.walletIdentity(wallet))?",
      isPresented: $confirmingRemoval,
      titleVisibility: .visible
    ) {
      Button("Remove wallet", role: .destructive) {
        isRemoving = true
        Task {
          await state.removeWallet(id: wallet.id)
          isRemoving = false
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The public address will be removed from this vault. Existing snapshots are unchanged.")
    }
    .onDisappear(perform: commitLabel)
    .disabled(state.vaultEditsDisabled)
  }

  private var labelField: some View {
    HStack(spacing: 7) {
      TextField("Wallet name", text: labelDraftBinding)
        .textFieldStyle(.plain)
        .font(.body.weight(.semibold))
        .submitLabel(.done)
        .focused($labelIsFocused)
        .accessibilityLabel("Label for wallet \(AtlasAccessibility.walletIdentity(wallet))")
        .accessibilityHint("Edit the local display label for this saved wallet.")
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
    .frame(minHeight: 44)
    .background(labelIsFocused ? AtlasTheme.accent.opacity(0.08) : Color.clear)
    .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous)
        .stroke(labelIsFocused ? AtlasTheme.accent : AtlasTheme.ruleSoft, lineWidth: 1)
    }
    .contentShape(RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous))
    .onTapGesture { labelIsFocused = true }
    .animation(
      AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
      value: labelIsFocused
    )
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

  private static func chainBadge(for family: ChainFamily) -> String {
    switch family {
    case .evm: "EVM"
    case .xrp: "XRP"
    default: family.rawValue.capitalized
    }
  }
}

/// `IconButtonStyle` frames its glyph at 34pt for pointer input. iOS needs a
/// 44pt touch target, so this twin keeps the same tokens, pressed tint, and
/// disabled treatment inside a 44pt hit area.
private struct WalletsIconButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    let pressedTint = configuration.role == .destructive ? AtlasTheme.loss : AtlasTheme.accent
    configuration.label
      .font(.callout)
      .foregroundStyle(
        isEnabled ? (configuration.isPressed ? pressedTint : AtlasTheme.ink3) : AtlasTheme.rule
      )
      .frame(width: 44, height: 44)
      .background(configuration.isPressed ? pressedTint.opacity(0.09) : Color.clear)
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
