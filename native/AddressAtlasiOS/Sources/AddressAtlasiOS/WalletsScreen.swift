import AddressAtlasCore
import SwiftUI
import UIKit

/// Saved public addresses, list first. Adding happens in a sheet opened from
/// the toolbar "+", the empty state, or another screen through
/// `IOSNavigationModel` (`.addWallet`). Tapping a row opens its detail sheet
/// (rename through the shared label-draft API, copy, networks, delete).
struct WalletsScreen: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showsAddSheet = false
  @State private var detailRequest: WalletDetailRequest?
  @State private var pendingRemoval: WalletRecord?

  private var wallets: [WalletRecord] {
    state.document.wallets
  }

  var body: some View {
    List {
      SourcesPersistentStatusSection()

      if wallets.isEmpty {
        Section {
          SourcesEmptyState(
            systemImage: "wallet.pass",
            title: "No wallets yet",
            copy: "Add a public address to see its balances.",
            actionTitle: "Add a wallet",
            action: openAddSheet
          )
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
      } else {
        Section {
          ForEach(wallets) { wallet in
            walletRow(wallet)
          }
        } footer: {
          Text("Watch-only · encrypted on this device")
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
      value: wallets.map(\.id)
    )
    .navigationTitle("Wallets")
    .navigationBarTitleDisplayMode(.large)
    .toolbarBackground(AtlasTheme.canvas, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(action: openAddSheet) {
          Image(systemName: "plus")
        }
        .accessibilityLabel("Add wallet")
        .accessibilityHint("Opens a form to paste one or more public addresses.")
      }
    }
    .sheet(isPresented: $showsAddSheet) {
      AddWalletSheet()
    }
    .sheet(item: $detailRequest) { request in
      WalletDetailSheet(walletID: request.walletID, focusesName: request.focusesName)
    }
    .onAppear(perform: consumePendingAction)
    .onChange(of: navigation.pendingAction) { _, _ in
      consumePendingAction()
    }
  }

  private func walletRow(_ wallet: WalletRecord) -> some View {
    let name = state.walletDisplayName(for: wallet)
    let shortAddress = WalletPresentation.shortAddress(wallet.address)
    return Button {
      detailRequest = WalletDetailRequest(walletID: wallet.id, focusesName: false)
    } label: {
      WalletRowLabel(wallet: wallet, name: name)
    }
    .listRowBackground(AtlasTheme.surface)
    .accessibilityLabel(
      "\(name), \(WalletNetworkInfo(wallet: wallet).badge), address \(shortAddress)"
    )
    .accessibilityHint("Opens the wallet details.")
    .accessibilityAction(named: "Copy address") { copyAddress(wallet) }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button {
        pendingRemoval = wallet
      } label: {
        Label("Delete", systemImage: "trash")
      }
      .tint(AtlasTheme.loss)
      .disabled(state.vaultEditsDisabled)
      .accessibilityLabel("Remove \(name)")
    }
    .contextMenu {
      Button {
        copyAddress(wallet)
      } label: {
        Label("Copy address", systemImage: "doc.on.doc")
      }
      Button {
        detailRequest = WalletDetailRequest(walletID: wallet.id, focusesName: true)
      } label: {
        Label("Rename", systemImage: "pencil")
      }
      .disabled(state.vaultEditsDisabled)
      Button(role: .destructive) {
        pendingRemoval = wallet
      } label: {
        Label("Delete", systemImage: "trash")
      }
      .disabled(state.vaultEditsDisabled)
    }
    // Attached to the row so the confirmation points at the wallet it removes.
    .confirmationDialog(
      "Remove \(name)?",
      isPresented: removalBinding(for: wallet),
      titleVisibility: .visible
    ) {
      Button("Remove wallet", role: .destructive) {
        Task { await state.removeWallet(id: wallet.id) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("\(shortAddress) is removed from this device. Existing snapshots are unchanged.")
    }
  }

  private func removalBinding(for wallet: WalletRecord) -> Binding<Bool> {
    Binding(
      get: { pendingRemoval?.id == wallet.id },
      set: { if !$0, pendingRemoval?.id == wallet.id { pendingRemoval = nil } }
    )
  }

  private func openAddSheet() {
    showsAddSheet = true
  }

  private func consumePendingAction() {
    if navigation.consume(.addWallet) {
      showsAddSheet = true
    }
  }

  private func copyAddress(_ wallet: WalletRecord) {
    UIPasteboard.general.string = wallet.address
    state.error = ""
    state.notice = "Address copied."
  }
}

// MARK: - Presentation helpers

private struct WalletDetailRequest: Identifiable {
  var walletID: UUID
  var focusesName: Bool
  var id: UUID { walletID }
}

/// Network facts for one saved wallet, derived from the address itself so a
/// Cosmos address names its own chain instead of the "cosmos" family.
private struct WalletNetworkInfo {
  var symbol: String
  var badge: String
  var friendlyName: String
  var scannedNetworks: [String]
  var isRetired: Bool

  /// Single-character avatar glyph for the network.
  var glyph: String {
    switch symbol {
    case "ETH": "Ξ"
    case "BTC": "₿"
    default: String(badge.prefix(1))
    }
  }

  init(wallet: WalletRecord) {
    self.init(family: wallet.chainKind, address: wallet.address)
  }

  init(family: ChainFamily, address: String) {
    if family == .evm {
      symbol = "ETH"
      badge = "EVM"
      friendlyName = "Ethereum wallet"
      scannedNetworks = ChainRegistry.evmChains.map(\.name)
      isRetired = false
      return
    }
    if let chain = AddressDetection.detectChains(for: address).first {
      symbol = chain.symbol
      badge = family == .xrp ? "XRP" : chain.name
      friendlyName = "\(family == .xrp ? "XRP" : chain.name) wallet"
      scannedNetworks = [chain.name]
      isRetired = false
      return
    }
    if let retired = AddressDetection.retiredCosmosNetworkName(for: address) {
      symbol = retired
      badge = retired
      friendlyName = "\(retired) wallet"
      scannedNetworks = []
      isRetired = true
      return
    }
    let name = family.rawValue.capitalized
    symbol = name
    badge = name
    friendlyName = "\(name) wallet"
    scannedNetworks = []
    isRetired = false
  }
}

private enum WalletPresentation {
  /// Same "…" truncation as every other short address in the app.
  static func shortAddress(_ address: String) -> String {
    guard address.count > 14 else { return address }
    return "\(address.prefix(6))…\(address.suffix(4))"
  }

  /// One entry per network family in input order ("EVM", "Bitcoin", …).
  static func networkChips(for addresses: [String]) -> [String] {
    var chips: [String] = []
    for address in addresses {
      guard let chain = AddressDetection.detectChains(for: address).first else { continue }
      let chip = WalletNetworkInfo(family: chain.family, address: address).badge
      if !chips.contains(chip) { chips.append(chip) }
    }
    return chips
  }
}

/// Network avatar in the same circle and hue as `TokenMonogram`, so a wallet
/// shares its color with its native asset elsewhere, with a single glyph.
private struct WalletNetworkMonogram: View {
  @Environment(\.colorScheme) private var colorScheme
  var info: WalletNetworkInfo
  var size: CGFloat

  var body: some View {
    let hue = TokenMonogram.hue(for: info.symbol)
    let foreground =
      info.isRetired
      ? AtlasTheme.ink3
      : Color(hue: hue, saturation: 0.72, brightness: colorScheme == .dark ? 0.92 : 0.62)
    let background =
      info.isRetired
      ? AtlasTheme.ink3.opacity(0.12)
      : Color(hue: hue, saturation: 0.6, brightness: 0.85)
        .opacity(colorScheme == .dark ? 0.24 : 0.16)
    Text(info.glyph)
      .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
      .foregroundStyle(foreground)
      .frame(width: size, height: size)
      .background(Circle().fill(background))
      .accessibilityHidden(true)
  }
}

private struct WalletRowLabel: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var wallet: WalletRecord
  var name: String

  var body: some View {
    let info = WalletNetworkInfo(wallet: wallet)
    HStack(spacing: 12) {
      // The avatar is decorative; at accessibility sizes its width goes to
      // the name instead.
      if !dynamicTypeSize.isAccessibilitySize {
        WalletNetworkMonogram(info: info, size: 40)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(name)
          .font(.body.weight(.semibold))
          .foregroundStyle(AtlasTheme.ink)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 1)
        // A short address never breaks across lines; it shrinks a little
        // instead at the largest text sizes.
        Text(WalletPresentation.shortAddress(wallet.address))
          .font(.subheadline)
          .foregroundStyle(AtlasTheme.ink3)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
        if dynamicTypeSize.isAccessibilitySize {
          Badge(info.badge, color: AtlasTheme.accent)
        }
      }
      Spacer(minLength: 8)
      if !dynamicTypeSize.isAccessibilitySize {
        Badge(info.badge, color: AtlasTheme.accent)
          .fixedSize()
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

// MARK: - Add wallet sheet

private struct AddWalletSheet: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.dismiss) private var dismiss
  @State private var input = ""
  @State private var isAdding = false
  /// Set when the sheet itself rewrites the field after a partial add, so the
  /// error that explains the leftover entry is not cleared by that rewrite.
  @State private var programmaticInput: String?
  /// Set when a seed phrase or private key was pasted and cleared from the
  /// field; the explanation stays until the person types again.
  @State private var clearedSecret = false
  @FocusState private var fieldFocused: Bool
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var trimmedInput: String {
    input.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The whole paste is checked before it is split, so a seed phrase is
  /// refused as a unit instead of being tried word by word.
  private var inputLooksSafe: Bool {
    AddressDetection.isSafePublicAddress(trimmedInput)
  }

  private var parsed: AddressParseResult {
    guard !trimmedInput.isEmpty, inputLooksSafe else {
      return AddressParseResult(addresses: [], wasTruncated: false)
    }
    return AddressDetection.parseWithMetadata(trimmedInput, maxCount: AppState.maximumWallets)
  }

  /// Only entries a supported network recognizes are counted or offered for
  /// saving; anything else stays in the field and is named as unrecognized.
  private var recognized: [String] {
    parsed.addresses.filter { !AddressDetection.detectChains(for: $0).isEmpty }
  }

  private var unrecognized: [String] {
    parsed.addresses.filter { AddressDetection.detectChains(for: $0).isEmpty }
  }

  /// Recognized entries that are already in the vault are named up front and
  /// skipped, instead of failing the add with "already saved".
  private var alreadySaved: [String] {
    recognized.filter(isSaved)
  }

  private var newAddresses: [String] {
    recognized.filter { !isSaved($0) }
  }

  private func isSaved(_ address: String) -> Bool {
    guard let chain = AddressDetection.detectChains(for: address).first,
      let identity = AddressDetection.canonicalAddress(address, family: chain.family)
    else { return false }
    return state.document.wallets.contains {
      $0.chainKind == chain.family
        && AddressDetection.canonicalAddress($0.address, family: $0.chainKind) == identity
    }
  }

  private var isBusyElsewhere: Bool {
    state.scanning || state.syncing
  }

  private var canAdd: Bool {
    !isAdding && !newAddresses.isEmpty && !state.vaultEditsDisabled
  }

  private var addTitle: String {
    let count = newAddresses.count
    return count > 1 ? "Add \(count) wallets" : "Add wallet"
  }

  var body: some View {
    IOSFormSheet(title: "Add wallet") {
      VStack(alignment: .leading, spacing: 10) {
        let headerLayout =
          dynamicTypeSize.isAccessibilitySize
          ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
          : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        headerLayout {
          FieldLabel("Public address")
            .accessibilityHidden(true)
          if !dynamicTypeSize.isAccessibilitySize {
            Spacer(minLength: 8)
          }
          PasteButton(payloadType: String.self) { strings in
            Task { @MainActor in paste(strings) }
          }
          .labelStyle(.titleAndIcon)
          .buttonBorderShape(.capsule)
          .controlSize(.small)
          .tint(AtlasTheme.accent)
        }
        TextField(
          "0x…, bc1…, or another public address",
          text: $input,
          axis: .vertical
        )
        .lineLimit(3...6)
        .textFieldStyle(AtlasTextFieldStyle())
        .atlasIdentifierInput()
        .focused($fieldFocused)
        .accessibilityLabel("Public wallet address")
        .accessibilityHint("Paste one address, or several separated by new lines or commas.")

        detectionLine
          .font(.footnote)
          .fixedSize(horizontal: false, vertical: true)

        let chips = WalletPresentation.networkChips(for: newAddresses)
        if !chips.isEmpty {
          SourcesFlowLayout(spacing: 6) {
            ForEach(chips, id: \.self) { chip in
              Badge(chip, color: AtlasTheme.accent)
            }
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Networks: \(chips.joined(separator: ", "))")
        }
      }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          FormToolbarConfirmButton(title: "Add", isEnabled: canAdd, action: addWallets)
        }
      }

      IOSInlineError()

      VStack(alignment: .leading, spacing: 10) {
        Button(action: addWallets) {
          HStack(spacing: 8) {
            if isAdding {
              ProgressView()
                .controlSize(.small)
                .tint(AtlasTheme.paper)
            }
            Text(addTitle)
          }
          .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        .disabled(!canAdd)
        .accessibilityLabel(addTitle)
        .accessibilityHint(
          isAdding
            ? "Saving the detected addresses."
            : "Saves the detected public addresses on this device.")

        if isBusyElsewhere {
          Text("Available when the current scan or sync finishes.")
            .font(.footnote)
            .foregroundStyle(AtlasTheme.ink3)
        }
      }

      Label(
        "Watch-only. Address Atlas can't sign or move funds.",
        systemImage: "eye"
      )
      .font(.footnote)
      .foregroundStyle(AtlasTheme.ink3)

      LearnMoreDisclosure("Supported networks", systemImage: "network") {
        IOSFactRow(
          systemImage: "square.stack.3d.up",
          title: "EVM",
          copy: "One 0x address covers \(ChainRegistry.evmChains.map(\.name).joined(separator: ", "))."
        )
        IOSFactRow(
          systemImage: "circle.hexagongrid",
          title: "Other networks",
          copy:
            "Bitcoin, Solana, TRON, XRP Ledger, and \(ChainRegistry.cosmosChains.map(\.name).joined(separator: ", "))."
        )
        IOSFactRow(
          systemImage: "eye",
          title: "What's read",
          copy:
            "Public balances from network APIs. Seed phrases and private keys are refused, never stored."
        )
      }
    }
    .interactiveDismissDisabled(isAdding)
    .onAppear {
      state.error = ""
      fieldFocused = true
    }
    .onChange(of: input) { _, newValue in
      if programmaticInput == newValue {
        programmaticInput = nil
        return
      }
      programmaticInput = nil
      if !state.error.isEmpty { state.error = "" }
      let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty, !AddressDetection.isSafePublicAddress(trimmed) {
        // A secret never stays on screen: the field is emptied and the
        // reason stays visible instead.
        clearedSecret = true
        programmaticInput = ""
        input = ""
        AtlasAccessibilityAnnouncer.shared.announceEvent(
          "That looked like a seed phrase or private key, so it was cleared.", kind: .error)
      } else if !trimmed.isEmpty {
        clearedSecret = false
      }
    }
    .onDisappear {
      // A rejected entry's error belongs to this sheet; it must not reappear
      // as a toast on the page underneath.
      if !isAdding { state.error = "" }
    }
  }

  @ViewBuilder
  private var detectionLine: some View {
    if trimmedInput.isEmpty, clearedSecret {
      Label(
        "That looked like a seed phrase or private key, so it was cleared. Only public addresses are accepted.",
        systemImage: "exclamationmark.shield.fill"
      )
      .foregroundStyle(AtlasTheme.loss)
    } else if trimmedInput.isEmpty {
      Text("One per line, or separated by commas.")
        .foregroundStyle(AtlasTheme.ink3)
    } else if !inputLooksSafe {
      Label(
        "That looks like a seed phrase or private key. Only public addresses are accepted.",
        systemImage: "exclamationmark.shield.fill"
      )
      .foregroundStyle(AtlasTheme.loss)
    } else if recognized.isEmpty {
      Label(
        unrecognized.count > 1 ? "No recognized addresses" : "Not a recognized address",
        systemImage: "questionmark.circle"
      )
      .foregroundStyle(AtlasTheme.warning)
    } else if newAddresses.isEmpty {
      Label(
        alreadySaved.count > 1 ? "These wallets are already saved" : "This wallet is already saved",
        systemImage: "checkmark.circle"
      )
      .foregroundStyle(AtlasTheme.ink3)
    } else {
      VStack(alignment: .leading, spacing: 4) {
        Label(
          newAddresses.count == 1
            ? "1 address detected" : "\(newAddresses.count) addresses detected",
          systemImage: "checkmark.circle.fill"
        )
        .foregroundStyle(AtlasTheme.gain)
        if !alreadySaved.isEmpty {
          Text(
            alreadySaved.count == 1
              ? "1 already saved and will be skipped"
              : "\(alreadySaved.count) already saved and will be skipped"
          )
          .foregroundStyle(AtlasTheme.ink3)
        }
        if !unrecognized.isEmpty {
          Label(
            unrecognized.count == 1
              ? "1 entry isn't recognized and will stay here"
              : "\(unrecognized.count) entries aren't recognized and will stay here",
            systemImage: "exclamationmark.triangle"
          )
          .foregroundStyle(AtlasTheme.warning)
        }
        if parsed.wasTruncated {
          Text("Only the first \(AppState.maximumWallets) are used.")
            .foregroundStyle(AtlasTheme.ink3)
        }
      }
    }
  }

  private func paste(_ strings: [String]) {
    let pasted = strings.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pasted.isEmpty else { return }
    guard AddressDetection.isSafePublicAddress(pasted) else {
      // Never put a pasted secret on screen; keep what was already typed.
      clearedSecret = trimmedInput.isEmpty
      if !trimmedInput.isEmpty {
        state.error = "That looked like a seed phrase or private key, so it wasn't pasted."
      }
      return
    }
    input = trimmedInput.isEmpty ? pasted : trimmedInput + "\n" + pasted
  }

  /// Adds the new recognized addresses in order and stops at the first one the
  /// shared state rejects (its message is shown inline). The rejected entry,
  /// anything after it, and unrecognized entries stay in the field so
  /// nothing is silently dropped; a complete add closes the sheet.
  private func addWallets() {
    guard canAdd else { return }
    let toAdd = newAddresses
    let leftovers = unrecognized
    let before = state.document.wallets.count
    isAdding = true
    fieldFocused = false
    state.error = ""
    Task {
      var remaining = toAdd[...]
      for address in toAdd {
        guard await state.addWallet(address: address) else { break }
        remaining = remaining.dropFirst()
      }
      let added = state.document.wallets.count - before
      let rest = Array(remaining) + leftovers
      isAdding = false
      if rest.isEmpty {
        if added > 0 {
          state.notice = added == 1 ? "Wallet added." : "\(added) wallets added."
        }
        dismiss()
      } else {
        let text = rest.joined(separator: "\n")
        if text != input {
          programmaticInput = text
          input = text
        }
        if added > 0, state.error.isEmpty {
          state.notice = added == 1 ? "Wallet added." : "\(added) wallets added."
        }
      }
    }
  }
}

// MARK: - Wallet detail sheet

private struct WalletDetailSheet: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.dismiss) private var dismiss
  var walletID: UUID
  var focusesName: Bool
  @FocusState private var nameFocused: Bool
  @State private var confirmingRemoval = false
  @State private var copied = false
  /// The last name typed that the vault would accept, so closing the sheet
  /// with an over-long draft saves that instead of dropping every edit.
  @State private var lastValidDraft: String?

  private static let nameLimit = VaultTextLimits.walletLabelCharacters

  private var wallet: WalletRecord? {
    state.document.wallets.first { $0.id == walletID }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        if let wallet {
          content(for: wallet)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
      }
      .scrollDismissesKeyboard(.interactively)
      .background(AtlasTheme.canvas)
      .navigationTitle("Wallet")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(AtlasTheme.canvas, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          FormToolbarConfirmButton(
            title: "Done", isEnabled: !nameIsTooLong, action: commitAndDismiss)
        }
      }
      .atlasKeyboardDoneButton()
    }
    .presentationDragIndicator(.visible)
    .onAppear {
      state.error = ""
      if focusesName { nameFocused = true }
    }
    .onDisappear(perform: finalizeName)
  }

  private var draftLength: Int {
    guard let wallet else { return 0 }
    let draft = state.walletLabelDraft(for: wallet)
    guard draft != AddressDetection.defaultWalletLabel(wallet.address) else { return 0 }
    return draft.trimmingCharacters(in: .whitespacesAndNewlines).count
  }

  private var nameIsTooLong: Bool {
    draftLength > Self.nameLimit
  }

  /// The wallet's priced total in the latest snapshot, or nil when that
  /// snapshot predates the wallet.
  private func latestValue(for wallet: WalletRecord) -> (total: Double, assets: Int)? {
    guard let scan = state.latestScan, scan.generatedAt >= wallet.createdAt else { return nil }
    guard
      let identity = AddressDetection.canonicalAddress(wallet.address, family: wallet.chainKind)
    else { return nil }
    let holdings = scan.holdings.filter {
      $0.family == wallet.chainKind
        && AddressDetection.canonicalAddress($0.address, family: $0.family) == identity
    }
    return (AppState.validatedPortfolioTotal(holdings) ?? 0, holdings.count)
  }

  @ViewBuilder
  private func content(for wallet: WalletRecord) -> some View {
    let info = WalletNetworkInfo(wallet: wallet)
    let name = state.walletDisplayName(for: wallet)
    let value = latestValue(for: wallet)
    VStack(alignment: .leading, spacing: 22) {
      VStack(spacing: 8) {
        WalletNetworkMonogram(info: info, size: 60)
        Text(name)
          .font(.title2.weight(.semibold))
          .multilineTextAlignment(.center)
          .lineLimit(3)
        if let value {
          Text(money(value.total))
            .font(.title3.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(AtlasTheme.ink)
          Text(
            value.assets == 1
              ? "1 asset · latest scan" : "\(value.assets) assets · latest scan"
          )
          .font(.footnote)
          .foregroundStyle(AtlasTheme.ink3)
        } else {
          Text("Not in a scan yet")
            .font(.footnote)
            .foregroundStyle(AtlasTheme.ink3)
        }
        Badge(info.badge, color: AtlasTheme.accent)
          .padding(.top, 2)
      }
      .frame(maxWidth: .infinity)
      .accessibilityElement(children: .combine)

      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          FieldLabel("Name")
          Spacer(minLength: 8)
          if draftLength > Self.nameLimit - 15 {
            Text("\(draftLength)/\(Self.nameLimit)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(nameIsTooLong ? AtlasTheme.loss : AtlasTheme.ink3)
              .accessibilityLabel("\(draftLength) of \(Self.nameLimit) characters")
          }
        }
        TextField(info.friendlyName, text: nameBinding(for: wallet))
          .textFieldStyle(AtlasTextFieldStyle())
          .textInputAutocapitalization(.words)
          .submitLabel(.done)
          .focused($nameFocused)
          .onSubmit {
            guard !nameIsTooLong else { return }
            Task { _ = await state.commitWalletLabelDraft(id: wallet.id) }
          }
          .overlay {
            if nameIsTooLong {
              RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
                .stroke(AtlasTheme.loss.opacity(0.7), lineWidth: 1.5)
                .allowsHitTesting(false)
            }
          }
          .accessibilityLabel("Wallet name")
          .accessibilityHint("Edit the name shown in the app. Leave empty to use the default.")
          .disabled(state.vaultEditsDisabled)
        if nameIsTooLong {
          Label(
            "Names can be up to \(Self.nameLimit) characters.",
            systemImage: "exclamationmark.circle.fill"
          )
          .font(.footnote)
          .foregroundStyle(AtlasTheme.loss)
        }
        IOSInlineError()
      }

      VStack(alignment: .leading, spacing: 8) {
        FieldLabel("Address")
        Text(wallet.address)
          .font(.callout.monospaced())
          .foregroundStyle(AtlasTheme.ink)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .background(AtlasTheme.surface)
          .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
              .stroke(AtlasTheme.ruleSoft, lineWidth: 1)
          }
        Button {
          UIPasteboard.general.string = wallet.address
          copied = true
          AtlasAccessibilityAnnouncer.shared.announceEvent("Address copied.", kind: .notice)
        } label: {
          Label(
            copied ? "Copied" : "Copy address",
            systemImage: copied ? "checkmark" : "doc.on.doc"
          )
          .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        .task(id: copied) {
          guard copied else { return }
          try? await Task.sleep(for: .seconds(1.6))
          copied = false
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        FieldLabel(info.isRetired ? "Network" : "Networks scanned")
        if info.isRetired {
          Text("\(info.badge) is no longer scanned. Remove this wallet if you no longer need it.")
            .font(.callout)
            .foregroundStyle(AtlasTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          SourcesFlowLayout(spacing: 6) {
            ForEach(info.scannedNetworks, id: \.self) { network in
              Badge(network)
            }
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Networks scanned: \(info.scannedNetworks.joined(separator: ", "))")
        }
      }

      Button(role: .destructive) {
        confirmingRemoval = true
      } label: {
        Label("Remove wallet", systemImage: "trash")
          .foregroundStyle(AtlasTheme.loss)
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(AtlasSecondaryButtonStyle())
      .disabled(state.vaultEditsDisabled)
      .accessibilityLabel("Remove \(name)")
      .accessibilityHint("Asks for confirmation before removing this saved wallet.")
      .confirmationDialog(
        "Remove \(name)?",
        isPresented: $confirmingRemoval,
        titleVisibility: .visible
      ) {
        Button("Remove wallet", role: .destructive) {
          Task {
            await state.removeWallet(id: wallet.id)
            if self.wallet == nil { dismiss() }
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "\(WalletPresentation.shortAddress(wallet.address)) is removed from this device. Existing snapshots are unchanged."
        )
      }
    }
  }

  /// The field shows an empty value while the wallet still has its legacy
  /// (truncated-address) label, and clearing it restores that default, so a
  /// blank name never reaches the shared draft as an invalid label.
  private func nameBinding(for wallet: WalletRecord) -> Binding<String> {
    let defaultLabel = AddressDetection.defaultWalletLabel(wallet.address)
    return Binding(
      get: {
        let draft = state.walletLabelDraft(for: wallet)
        return draft == defaultLabel ? "" : draft
      },
      set: { newValue in
        if !state.error.isEmpty { state.error = "" }
        let isBlank = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let label = isBlank ? defaultLabel : newValue
        if AppState.normalizedWalletLabel(label) != nil {
          lastValidDraft = label
        }
        _ = state.setWalletLabelDraft(id: wallet.id, label: label)
      }
    )
  }

  private func commitAndDismiss() {
    nameFocused = false
    Task {
      if await state.commitWalletLabelDraft(id: walletID) {
        dismiss()
      }
    }
  }

  /// Swipe-to-dismiss saves the name. A draft the vault would refuse (over
  /// 80 characters) is replaced by the last valid name typed in this sheet,
  /// or the saved name, so it never lingers as a draft that blocks syncs.
  private func finalizeName() {
    guard let persisted = state.document.wallets.first(where: { $0.id == walletID })?.label,
      let wallet
    else { return }
    let draft = state.walletLabelDraft(for: wallet)
    if AppState.normalizedWalletLabel(draft) == nil {
      _ = state.setWalletLabelDraft(id: walletID, label: lastValidDraft ?? persisted)
      state.error = ""
    }
    Task { _ = await state.commitWalletLabelDraft(id: walletID) }
  }
}

/// Toolbar confirm action that looks disabled when it is. The root view's ink
/// foreground style otherwise keeps a disabled bar button looking active.
struct FormToolbarConfirmButton: View {
  var title: String
  var isEnabled: Bool
  var action: () -> Void

  var body: some View {
    Button(title, action: action)
      .fontWeight(.semibold)
      .foregroundStyle(isEnabled ? AtlasTheme.accent : AtlasTheme.ink3.opacity(0.55))
      .disabled(!isEnabled)
  }
}

// MARK: - Shared source-screen pieces (also used by ExchangesScreen)

/// Persistent page status (operator message, required action, update link)
/// as a list section; transient notices and errors float in the toast.
struct SourcesPersistentStatusSection: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    if state.operatorMessage != nil || state.persistentOperationGuidance != nil
      || !state.isAppVersionSupported
    {
      Section {
        IOSPersistentStatus()
      }
      .listRowBackground(AtlasTheme.surface)
    }
  }
}

/// Empty list state with one primary action.
struct SourcesEmptyState: View {
  var systemImage: String
  var title: String
  var copy: String
  var actionTitle: String
  var action: () -> Void

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: systemImage)
        .font(.system(size: 30, weight: .semibold))
        .foregroundStyle(AtlasTheme.accent)
        .frame(width: 72, height: 72)
        .background(AtlasTheme.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityHidden(true)
      VStack(spacing: 6) {
        Text(title)
          .font(.title3.weight(.semibold))
          .foregroundStyle(AtlasTheme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
        Text(copy)
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
      .multilineTextAlignment(.center)
      Button(action: action) {
        Label(actionTitle, systemImage: "plus")
          .frame(minHeight: 44)
          .padding(.horizontal, 8)
      }
      .buttonStyle(AtlasPrimaryButtonStyle())
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 24)
    .padding(.vertical, 48)
  }
}

/// Wrapping row of small chips (networks, badges).
struct SourcesFlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var maxX: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
      if x > 0, x + size.width > width {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      x += size.width + spacing
      maxX = max(maxX, x - spacing)
      rowHeight = max(rowHeight, size.height)
    }
    return CGSize(width: min(maxX, width), height: y + rowHeight)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
      if x > bounds.minX, x + size.width > bounds.maxX {
        x = bounds.minX
        y += rowHeight + spacing
        rowHeight = 0
      }
      subview.place(
        at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}
