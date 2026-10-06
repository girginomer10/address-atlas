import AddressAtlasCore
import SwiftUI
import UIKit

// MARK: - Cross-screen navigation

/// A task that one screen asks another to start, such as the onboarding
/// finish or a Portfolio empty-state button opening the add-wallet sheet on
/// the Wallets tab. The destination screen consumes it exactly once.
enum IOSPendingAction: Equatable, Sendable {
  case addWallet
  case connectExchange
  case addManualHolding
  case addCustomToken
  /// Portfolio starts a scan (when one is allowed) as soon as it appears.
  /// Used right after the first source is saved, before any snapshot exists.
  case runFirstScan
}

/// Shared iPhone/iPad navigation intent. `TabShell` and `SplitShell` switch
/// to `selectedSection` whenever `openRequest` changes (so reopening the
/// section the person already left still works); screens observe
/// `pendingAction` and clear it with `consume(_:)` once they have presented
/// the requested sheet.
@MainActor
final class IOSNavigationModel: ObservableObject {
  @Published private(set) var selectedSection: AtlasSection = .portfolio
  @Published private(set) var openRequest = 0
  @Published var pendingAction: IOSPendingAction?
  /// Search text Assets applies once when it appears (then clears), so a
  /// Portfolio allocation row can open Assets filtered to one symbol.
  @Published var assetsQuery: IOSAssetsQuery?

  func open(_ section: AtlasSection, then action: IOSPendingAction? = nil) {
    selectedSection = section
    pendingAction = action
    openRequest &+= 1
  }

  /// Opens Assets showing exactly the holdings of `symbol` (nil = all).
  func openAssets(symbol: String?) {
    assetsQuery = IOSAssetsQuery(symbol: symbol)
    open(.assets)
  }

  /// Returns and clears the pending Assets query.
  func consumeAssetsQuery() -> IOSAssetsQuery? {
    guard let query = assetsQuery else { return nil }
    assetsQuery = nil
    return query
  }

  /// Returns true (and clears the request) when `action` is pending.
  func consume(_ action: IOSPendingAction) -> Bool {
    guard pendingAction == action else { return false }
    pendingAction = nil
    return true
  }
}

/// A one-shot Assets search request. `symbol` matches holdings whose symbol
/// is exactly this one (case-insensitive) while the search text is unchanged.
struct IOSAssetsQuery: Equatable, Sendable {
  var id = UUID()
  var symbol: String?
}

/// The first-run walkthrough is shown once per install, and only while the
/// vault has no sources; restored or returning vaults go straight to the app.
enum IOSOnboarding {
  static let completedKey = "onboarding.completed.v1"
}

// MARK: - Token monogram

/// Colored initial for an asset. The hue is derived from the symbol so the
/// same asset always gets the same color across Portfolio and Assets; a few
/// well-known assets use their familiar hue.
struct TokenMonogram: View {
  @Environment(\.colorScheme) private var colorScheme
  var symbol: String
  var size: CGFloat = 36
  var isPlaceholder = false

  private static let knownHues: [String: Double] = [
    "BTC": 0.08, "WBTC": 0.08, "ETH": 0.64, "WETH": 0.64, "STETH": 0.6,
    "USDT": 0.44, "USDC": 0.58, "DAI": 0.12, "SOL": 0.78, "BNB": 0.13,
    "XRP": 0.0, "ADA": 0.6, "DOT": 0.92, "ATOM": 0.7, "MATIC": 0.75, "POL": 0.75,
    "ARB": 0.57, "OP": 0.99, "AVAX": 0.0, "LINK": 0.62, "TRX": 0.99,
  ]

  static func hue(for symbol: String) -> Double {
    let key = symbol.uppercased()
    if let known = knownHues[key] { return known }
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in key.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return Double(hash % 360) / 360
  }

  private var initials: String {
    let letters = symbol.uppercased().filter { $0.isLetter || $0.isNumber }
    return String(letters.prefix(1))
  }

  var body: some View {
    let hue = Self.hue(for: symbol)
    let foreground =
      isPlaceholder
      ? AtlasTheme.ink3
      : Color(hue: hue, saturation: 0.72, brightness: colorScheme == .dark ? 0.92 : 0.62)
    let background =
      isPlaceholder
      ? AtlasTheme.ink3.opacity(0.12)
      : Color(hue: hue, saturation: 0.6, brightness: 0.85).opacity(colorScheme == .dark ? 0.24 : 0.16)
    ZStack {
      Circle().fill(background)
      if isPlaceholder {
        Image(systemName: "ellipsis")
          .font(.system(size: size * 0.36, weight: .bold))
      } else {
        Text(initials.isEmpty ? "?" : initials)
          .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
          .minimumScaleFactor(0.6)
          .lineLimit(1)
      }
    }
    .foregroundStyle(foreground)
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

// MARK: - Formatting

enum AtlasPercent {
  /// Locale-aware share of a total, with a "<0.1%" floor for tiny non-zero
  /// shares so the floor uses the same separators as every other percentage.
  static func text(_ fraction: Double) -> String {
    let style = FloatingPointFormatStyle<Double>.Percent()
      .precision(.fractionLength(0...1))
      .locale(AtlasFormatting.locale)
    guard fraction.isFinite else { return "–" }
    if fraction > 0, fraction < 0.001 {
      return "<" + 0.001.formatted(style)
    }
    return fraction.formatted(style)
  }

  /// A signed change such as "+1.2%" or "−0.04%". Changes too small to show
  /// at two decimals read "0%" without a sign instead of a signed floor.
  static func signedChange(_ fraction: Double) -> String {
    guard fraction.isFinite else { return "–" }
    let style = FloatingPointFormatStyle<Double>.Percent()
      .precision(.fractionLength(0...(abs(fraction) < 0.01 ? 2 : 1)))
      .locale(AtlasFormatting.locale)
    guard abs(fraction) >= 0.00005 else { return (0.0).formatted(style) }
    let text = abs(fraction).formatted(style)
    return (fraction > 0 ? "+" : "−") + text
  }
}

/// Locale-aware holding amounts shared by Portfolio, Assets, and Snapshots,
/// so a manual "1.5" reads "1,5" everywhere in a comma-decimal locale.
enum AtlasAmount {
  private static let posix = Locale(identifier: "en_US_POSIX")

  /// The stored amount as a Decimal: the exact exchange decimal when there
  /// is one, else the shortest round-trip form of the stored Double.
  static func decimal(_ asset: TrackedAsset) -> Decimal? {
    Decimal(string: asset.canonicalAmount, locale: posix)
  }

  /// Every stored digit, localized, never rounded.
  static func full(_ asset: TrackedAsset) -> String {
    guard let decimal = decimal(asset) else {
      return asset.displayedAmount(locale: AtlasFormatting.locale)
    }
    return decimal.formatted(
      .number.precision(.fractionLength(0...30)).locale(AtlasFormatting.locale))
  }

  /// A list-friendly amount: up to four decimals from 1 upward and six
  /// significant digits below 1, with the locale's separators.
  static func compact(_ asset: TrackedAsset) -> String {
    guard let decimal = decimal(asset) else {
      return asset.displayedAmount(locale: AtlasFormatting.locale)
    }
    if decimal == 0 { return (0 as Decimal).formatted(.number.locale(AtlasFormatting.locale)) }
    if abs(decimal) >= 1 {
      return decimal.formatted(
        .number.precision(.fractionLength(0...4)).locale(AtlasFormatting.locale))
    }
    return decimal.formatted(
      .number.precision(.significantDigits(1...6)).locale(AtlasFormatting.locale))
  }
}

// MARK: - Holding presentation

extension TrackedAsset {
  /// True for holdings entered by hand in Tokens.
  var atlasIOSIsManual: Bool { id.hasPrefix("manual-") }

  /// The network for chain holdings; the exchange or manual venue otherwise.
  var atlasIOSVenue: String { exchangeProvider?.label ?? chainName }

  /// A human description of what the holding is.
  var atlasIOSKindLabel: String {
    switch source {
    case .native: "Native coin"
    case .erc20: "ERC-20 token"
    case .spl: "SPL token"
    case .trc20: "TRC-20 token"
    case .issued: "Issued asset"
    case .exchange: atlasIOSIsManual ? "Manual holding" : "Exchange balance"
    case .staked: "Staked"
    case .rewards: "Staking rewards"
    }
  }
}

/// VoiceOver text for holdings: locale numbers and human source names
/// instead of raw decimals and internal source identifiers.
enum AtlasIOSAccessibility {
  static func holding(_ asset: TrackedAsset) -> String {
    var parts = [asset.symbol]
    let name = asset.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty, name.caseInsensitiveCompare(asset.symbol) != .orderedSame,
      name.caseInsensitiveCompare(asset.atlasIOSVenue) != .orderedSame
    {
      parts.append(name)
    }
    parts.append(asset.atlasIOSVenue)
    if let label = asset.walletLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
      !label.isEmpty, label != asset.atlasIOSVenue
    {
      parts.append(label)
    }
    parts.append(asset.atlasIOSKindLabel)
    parts.append("amount \(AtlasAmount.full(asset))")
    parts.append(valuation(asset))
    return parts.joined(separator: ", ")
  }

  static func valuation(_ asset: TrackedAsset) -> String {
    switch asset.pricingStatus {
    case .priced: "value \(money(asset.valueUsd))"
    case .unpriced: "no USD price"
    case .valuationUnavailable: "USD value unavailable"
    }
  }
}

// MARK: - Detail sheet sizing

extension View {
  /// Medium/large detents on iPhone; a page-sized sheet on iPad (iOS 18+)
  /// instead of a cramped centered form.
  func atlasDetailSheetPresentation() -> some View {
    modifier(AtlasDetailSheetPresentation())
  }
}

private struct AtlasDetailSheetPresentation: ViewModifier {
  /// The sheet's own size class is compact inside an iPad form sheet, so the
  /// device idiom decides.
  private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

  func body(content: Content) -> some View {
    if isPad {
      if #available(iOS 18.0, *) {
        content
          .presentationSizing(.page)
          .presentationDragIndicator(.hidden)
      } else {
        content.presentationDetents([.large])
      }
    } else {
      content
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
  }
}

// MARK: - Sheets

/// Standard add/edit sheet: inline title, Cancel, an optional confirm action
/// in the navigation bar, a scrolling form body, and the sheet's own inline
/// status so errors appear next to the form instead of behind the sheet.
struct IOSFormSheet<Content: View>: View {
  @Environment(\.dismiss) private var dismiss
  var title: String
  var content: Content

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    NavigationStack {
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
      .toolbarBackground(AtlasTheme.canvas, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      .atlasKeyboardDoneButton()
    }
    .presentationDragIndicator(.visible)
  }
}

/// The shared error line for a form shown inside a sheet or right under the
/// control that produced it. Reads `state.error`, so the message is the same
/// one the shared state layer produced.
struct IOSInlineError: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    if !state.error.isEmpty {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "exclamationmark.circle.fill")
          .accessibilityHidden(true)
        Text(state.error)
          .fixedSize(horizontal: false, vertical: true)
      }
      .font(.callout)
      .foregroundStyle(AtlasTheme.loss)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(AtlasTheme.loss.opacity(0.08))
      .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Error: \(state.error)")
      .onAppear {
        AtlasAccessibilityAnnouncer.shared.announceEvent(state.error, kind: .error)
      }
    }
  }
}

// MARK: - Progressive disclosure

/// Collapsed explanation for details most people do not need on every visit.
/// Long privacy and mechanism copy lives here instead of in always-open
/// callouts.
struct LearnMoreDisclosure<Content: View>: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var isExpanded = false
  var title: String
  var systemImage: String
  var content: Content

  init(
    _ title: String = "How this works",
    systemImage: String = "info.circle",
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 10) {
          if !dynamicTypeSize.isAccessibilitySize {
            Image(systemName: systemImage)
              .foregroundStyle(AtlasTheme.accent)
              .accessibilityHidden(true)
          }
          Text(title)
            .font(.callout.weight(.medium))
            .foregroundStyle(AtlasTheme.ink)
            .multilineTextAlignment(.leading)
          Spacer(minLength: 8)
          Image(systemName: "chevron.down")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AtlasTheme.ink3)
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
            .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      .accessibilityHint(isExpanded ? "Hides the details." : "Shows the details.")

      if isExpanded {
        VStack(alignment: .leading, spacing: 10) {
          content
        }
        .font(.callout)
        .foregroundStyle(AtlasTheme.ink2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 10)
        .transition(.opacity)
      }
    }
    .padding(.horizontal, 14)
    .background(AtlasTheme.surfaceMuted.opacity(0.4))
    .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
  }
}

/// One fact inside a `LearnMoreDisclosure` or onboarding page.
struct IOSFactRow: View {
  var systemImage: String
  var title: String
  var copy: String
  var tint: Color = AtlasTheme.accent

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.body.weight(.semibold))
        .foregroundStyle(tint)
        .frame(width: 28)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout.weight(.semibold))
          .foregroundStyle(AtlasTheme.ink)
        Text(copy)
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Keyboard

extension View {
  /// Decimal and number pads have no return key; this adds a Done button
  /// above every keyboard on the page. Apply once per page or sheet.
  func atlasKeyboardDoneButton() -> some View {
    toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") {
          UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .font(.body.weight(.semibold))
      }
    }
  }
}

// MARK: - Status

/// Long-lived status that must stay on the page: operator messages, required
/// actions, and the unsupported-version update link. Transient notices and
/// errors are shown by `IOSStatusToast` instead.
struct IOSPersistentStatus: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    if state.operatorMessage != nil || state.persistentOperationGuidance != nil
      || !state.isAppVersionSupported
    {
      VStack(alignment: .leading, spacing: 8) {
        if let operatorMessage = state.operatorMessage {
          Label(operatorMessage, systemImage: "info.circle")
            .foregroundStyle(AtlasTheme.accent)
            .accessibilityLabel("Sync server message: \(operatorMessage)")
        }
        if let guidance = state.persistentOperationGuidance {
          Label(guidance, systemImage: "exclamationmark.shield")
            .foregroundStyle(AtlasTheme.warning)
            .accessibilityLabel("Action required: \(guidance)")
        }
        if !state.isAppVersionSupported {
          Link(destination: state.safeUpdateDownloadURL) {
            Label(state.updateActionTitle, systemImage: "arrow.down.circle")
          }
          .accessibilityHint(state.updateActionHint)
        }
      }
      .font(.callout)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}

// MARK: - Status toast

/// How a transient message reads: green only for work that completed.
enum IOSToastTone: Equatable {
  case success
  case neutral
  case warning
  case error

  /// Cancellations and "already running" are information, not success; a
  /// snapshot saved with warnings is a warning.
  static func forNotice(_ notice: String) -> IOSToastTone {
    let lowered = notice.lowercased()
    if lowered.contains("warning") { return .warning }
    if lowered.contains("cancelled") || lowered.contains("canceled")
      || lowered.contains("already running")
    {
      return .neutral
    }
    return .success
  }

  var color: Color {
    switch self {
    case .success: AtlasTheme.gain
    case .neutral: AtlasTheme.ink3
    case .warning: AtlasTheme.warning
    case .error: AtlasTheme.loss
    }
  }

  var systemImage: String {
    switch self {
    case .success: "checkmark.circle.fill"
    case .neutral: "info.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .error: "exclamationmark.circle.fill"
    }
  }

  var accessibilityPrefix: String {
    switch self {
    case .success, .neutral: "Status"
    case .warning: "Warning"
    case .error: "Error"
    }
  }
}

/// The parts of the vault whose local saves the toast can describe.
struct IOSSaveFingerprint: Equatable {
  struct Revision: Equatable {
    var enabled: Bool
    var updatedAt: Date
  }

  var wallets: [UUID: String] = [:]
  var exchanges: Set<UUID> = []
  var tokens: [UUID: Revision] = [:]
  var manualHoldings: [UUID: Revision] = [:]
  var scanRuns: Set<UUID> = []
  var hideDust = false
  var autoRefresh = false
  var dustThreshold = 0.0

  init(_ document: VaultDocument) {
    for wallet in document.wallets { wallets[wallet.id] = wallet.label }
    exchanges = Set(document.exchangeConnections.map(\.id))
    for token in document.customTokens {
      tokens[token.id] = Revision(enabled: token.enabled, updatedAt: token.updatedAt)
    }
    for holding in document.manualHoldings {
      manualHoldings[holding.id] = Revision(enabled: holding.enabled, updatedAt: holding.updatedAt)
    }
    scanRuns = Set(document.scanRuns.map(\.id))
    hideDust = document.preferences.hideDust
    autoRefresh = document.preferences.autoRefresh
    dustThreshold = document.preferences.dustThreshold
  }
}

/// What one local save changed, in the words the toast shows instead of the
/// generic "Saved locally.".
struct IOSSaveSummary: Equatable {
  /// Nil when the control that changed already shows the result (a switch,
  /// a filter), so a confirmation would only be noise.
  var message: String?
  /// A wallet, exchange connection, or manual holding was added.
  var addedSource = false

  private struct CollectionChange {
    var added = 0
    var removed = 0
    var edited = 0
    var toggled = 0

    init(_ old: [UUID: IOSSaveFingerprint.Revision], _ new: [UUID: IOSSaveFingerprint.Revision]) {
      for (id, revision) in new {
        guard let previous = old[id] else {
          added += 1
          continue
        }
        if previous.enabled != revision.enabled {
          toggled += 1
        } else if previous.updatedAt != revision.updatedAt {
          edited += 1
        }
      }
      removed = old.keys.filter { new[$0] == nil }.count
    }
  }

  private static func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
    count == 1 ? singular : "\(count) \(plural)"
  }

  /// Nil when the change is not one the toast knows how to name.
  static func between(_ old: IOSSaveFingerprint, _ new: IOSSaveFingerprint) -> IOSSaveSummary? {
    let addedWallets = new.wallets.keys.filter { old.wallets[$0] == nil }.count
    let removedWallets = old.wallets.keys.filter { new.wallets[$0] == nil }.count
    let renamed = new.wallets.contains { id, label in
      old.wallets[id].map { $0 != label } ?? false
    }
    let addedExchanges = new.exchanges.subtracting(old.exchanges).count
    let tokens = CollectionChange(old.tokens, new.tokens)
    let manual = CollectionChange(old.manualHoldings, new.manualHoldings)
    let removedRuns = old.scanRuns.subtracting(new.scanRuns).count
    let addedRuns = new.scanRuns.subtracting(old.scanRuns).count

    if addedWallets > 0 {
      return IOSSaveSummary(
        message: counted(addedWallets, "Wallet added.", "wallets added."), addedSource: true)
    }
    if addedExchanges > 0 {
      return IOSSaveSummary(message: "Exchange connected.", addedSource: true)
    }
    if manual.added > 0 {
      return IOSSaveSummary(
        message: counted(manual.added, "Holding added.", "holdings added."), addedSource: true)
    }
    if removedWallets > 0 {
      return IOSSaveSummary(message: counted(removedWallets, "Wallet removed.", "wallets removed."))
    }
    if renamed { return IOSSaveSummary(message: "Name saved.") }
    if manual.removed > 0 {
      return IOSSaveSummary(message: counted(manual.removed, "Holding removed.", "holdings removed."))
    }
    if manual.edited > 0 { return IOSSaveSummary(message: "Holding updated.") }
    if tokens.added > 0 {
      return IOSSaveSummary(message: counted(tokens.added, "Token added.", "tokens added."))
    }
    if tokens.removed > 0 {
      return IOSSaveSummary(message: counted(tokens.removed, "Token removed.", "tokens removed."))
    }
    if tokens.edited > 0 { return IOSSaveSummary(message: "Token updated.") }
    if removedRuns > 0 {
      return IOSSaveSummary(
        message: counted(removedRuns, "Snapshot deleted.", "snapshots deleted."))
    }
    if addedRuns > 0 { return nil }
    if new.dustThreshold != old.dustThreshold {
      return IOSSaveSummary(message: "Threshold saved.")
    }
    if tokens.toggled > 0 || manual.toggled > 0 || new.hideDust != old.hideDust
      || new.autoRefresh != old.autoRefresh
    {
      return IOSSaveSummary(message: nil)
    }
    return nil
  }
}

/// Floating capsule above the tab bar for `state.notice` (auto-dismissed) and
/// `state.error` (stays until tapped, replaced, or cleared by navigation).
/// It also posts the VoiceOver announcement the inline status line used to.
///
/// The shared state layer reports every local save as "Saved locally."; the
/// toast names what was saved instead ("Wallet added.", "Name saved.") and
/// stays quiet for switches and filters whose control already shows the
/// change. Right after the first source is saved, before any snapshot
/// exists, it offers the first scan.
struct IOSStatusToast: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var navigation: IOSNavigationModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  /// Bottom inset above the tab bar; nil pins the toast to the top edge
  /// (unlock and onboarding pages keep their primary buttons at the bottom).
  var bottomPadding: CGFloat?
  /// Onboarding and unlock never offer the first scan.
  var offersFirstScan = true

  static let noticeDuration: Duration = .seconds(4)
  static let actionNoticeDuration: Duration = .seconds(8)
  static let genericSaveNotice = "Saved locally."
  /// A save summary only explains a notice posted right after it.
  private static let summaryWindow: TimeInterval = 2

  private struct RecentSave: Equatable {
    var summary: IOSSaveSummary?
    var at: Date
  }

  private struct ResolvedNotice: Equatable {
    var raw: String
    var text: String?
    var offersFirstScan: Bool
    var token = UUID()
  }

  private struct Display: Equatable {
    var text: String
    var tone: IOSToastTone
    var offersFirstScan: Bool
  }

  @State private var recentSave: RecentSave?
  @State private var resolved: ResolvedNotice?

  private var display: Display? {
    if !state.error.isEmpty {
      return Display(text: state.error, tone: .error, offersFirstScan: false)
    }
    guard let resolved, resolved.raw == state.notice, let text = resolved.text else { return nil }
    return Display(
      text: text, tone: IOSToastTone.forNotice(text), offersFirstScan: resolved.offersFirstScan)
  }

  var body: some View {
    VStack {
      if bottomPadding != nil { Spacer() }
      if let display {
        capsule(display)
          .padding(.horizontal, 16)
          .padding(.bottom, bottomPadding ?? 0)
          .padding(.top, bottomPadding == nil ? 8 : 0)
          .transition(
            reduceMotion
              ? .opacity
              : .move(edge: bottomPadding == nil ? .top : .bottom).combined(with: .opacity))
          .id(display.text)
      }
      if bottomPadding == nil { Spacer() }
    }
    .animation(
      AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
      value: display
    )
    .onAppear { resolve() }
    .onChange(of: IOSSaveFingerprint(state.document)) { old, new in
      recentSave = RecentSave(summary: IOSSaveSummary.between(old, new), at: Date())
      resolve()
    }
    .onChange(of: state.notice) { _, _ in resolve() }
    .task(id: resolved) {
      guard let resolved, !resolved.raw.isEmpty else { return }
      // A save and its notice can arrive in either order; wait a beat so
      // only the final wording is announced.
      do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      if let text = resolved.text {
        AtlasAccessibilityAnnouncer.shared.announceEvent(text, kind: .notice)
      }
      let duration = resolved.offersFirstScan ? Self.actionNoticeDuration : Self.noticeDuration
      do { try await Task.sleep(for: duration) } catch { return }
      if state.notice == resolved.raw { state.notice = "" }
    }
    .onChange(of: state.error) { _, error in
      AtlasAccessibilityAnnouncer.shared.announceEvent(error, kind: .error)
    }
  }

  private func resolve() {
    let notice = state.notice
    guard !notice.isEmpty else {
      resolved = nil
      return
    }
    var summary: IOSSaveSummary?
    if let recentSave, Date().timeIntervalSince(recentSave.at) < Self.summaryWindow {
      summary = recentSave.summary
    }
    var text: String? = notice
    if notice.hasPrefix(Self.genericSaveNotice), let summary {
      // Keep any extra sentence the save appended (such as pruned snapshots).
      let suffix = notice.dropFirst(Self.genericSaveNotice.count)
        .trimmingCharacters(in: .whitespaces)
      if let message = summary.message {
        text = suffix.isEmpty ? message : "\(message) \(suffix)"
      } else {
        text = suffix.isEmpty ? nil : suffix
      }
    }
    let offers =
      offersFirstScan && (summary?.addedSource ?? false) && state.document.scanRuns.isEmpty
      && state.hasScanSources && !state.scanning
    resolved = ResolvedNotice(raw: notice, text: text, offersFirstScan: offers)
  }

  private func dismiss(_ display: Display) {
    if display.tone == .error { state.error = "" } else { state.notice = "" }
  }

  private func capsule(_ display: Display) -> some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
      : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
    return layout {
      Button {
        dismiss(display)
      } label: {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: display.tone.systemImage)
            .foregroundStyle(display.tone.color)
            .accessibilityHidden(true)
          Text(display.text)
            .font(.callout.weight(.medium))
            .foregroundStyle(AtlasTheme.ink)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          if display.tone == .error {
            Image(systemName: "xmark")
              .font(.caption.weight(.bold))
              .foregroundStyle(AtlasTheme.ink3)
              .accessibilityHidden(true)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(display.tone.accessibilityPrefix): \(display.text)")
      .accessibilityHint("Dismisses the message.")

      if display.offersFirstScan {
        Button {
          state.notice = ""
          navigation.open(.portfolio, then: .runFirstScan)
        } label: {
          Text("Scan now")
            .font(.callout.weight(.semibold))
            .foregroundStyle(AtlasTheme.paper)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(Capsule().fill(AtlasTheme.accent))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityHint("Opens Portfolio and reads the balances of your saved sources.")
        .accessibilityIdentifier("toast-first-scan")
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, display.offersFirstScan ? 6 : 12)
    .frame(minHeight: 48)
    .background(
      RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous)
        .fill(.regularMaterial)
    )
    .overlay {
      RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous)
        .stroke(display.tone.color.opacity(0.35), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    .frame(maxWidth: 560)
  }
}

// MARK: - Privacy cover

/// Opaque brand cover shown whenever the scene is not active, so the app
/// switcher snapshot never contains balances, addresses, revealed API keys,
/// or a recovery code.
struct IOSPrivacyCover: View {
  var body: some View {
    ZStack {
      AtlasTheme.canvas.ignoresSafeArea()
      VStack(spacing: 14) {
        ZStack {
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
              LinearGradient(
                colors: [AtlasTheme.accent, AtlasTheme.accent.opacity(0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              ))
          Image(systemName: "lock.fill")
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(AtlasTheme.paper)
        }
        .frame(width: 72, height: 72)
        .shadow(color: AtlasTheme.accent.opacity(0.25), radius: 12, y: 5)
        Text("Address Atlas")
          .font(.headline)
          .foregroundStyle(AtlasTheme.ink)
      }
    }
    .accessibilityHidden(true)
  }
}

/// Shows `IOSPrivacyCover` in its own window above every sheet, popover, and
/// alert the app presents. A SwiftUI overlay sits under presented sheets, so
/// the app switcher would otherwise capture an open asset, wallet, or
/// exchange sheet. The window appears as soon as the scene starts to resign
/// active (before the switcher snapshot) and hides when it is active again.
@MainActor
final class IOSPrivacyShield {
  static let shared = IOSPrivacyShield()

  private var window: UIWindow?
  private var observers: [NSObjectProtocol] = []

  private init() {}

  func install() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    observers = [
      center.addObserver(
        forName: UIScene.willDeactivateNotification, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated { IOSPrivacyShield.shared.show() }
      },
      center.addObserver(
        forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated { IOSPrivacyShield.shared.show() }
      },
      center.addObserver(
        forName: UIScene.didActivateNotification, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated { IOSPrivacyShield.shared.hide() }
      },
    ]
  }

  func show() {
    guard
      let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState != .unattached })
        ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
    else { return }
    if window?.windowScene !== scene {
      window?.isHidden = true
      let cover = UIWindow(windowScene: scene)
      // Above alerts, so even a confirmation dialog is covered.
      cover.windowLevel = .alert + 1
      let host = UIHostingController(rootView: IOSPrivacyCover())
      host.view.backgroundColor = .systemBackground
      cover.rootViewController = host
      cover.accessibilityElementsHidden = true
      window = cover
    }
    window?.isHidden = false
  }

  func hide() {
    window?.isHidden = true
  }
}

extension IOSPendingAction {
  /// The screen that owns the sheet for this action.
  var section: AtlasSection {
    switch self {
    case .addWallet: .wallets
    case .connectExchange: .exchanges
    case .addManualHolding, .addCustomToken: .tokens
    case .runFirstScan: .portfolio
    }
  }
}
