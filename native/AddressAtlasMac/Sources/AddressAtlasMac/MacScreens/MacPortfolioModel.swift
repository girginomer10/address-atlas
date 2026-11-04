import AddressAtlasCore
import Foundation

/// What the Portfolio, Assets and coin screens show of the latest scan, worked
/// out once per render from `AppState`. Numbers come from `PortfolioAnalytics`
/// and the state layer; nothing here is a second copy of their rules.
struct MacPortfolioSnapshot {
  enum Change: Equatable {
    /// Fewer than two scans, or totals that cannot be compared.
    case none
    /// The value moved between two scans that read the same sources.
    case moved(delta: Double, fraction: Double?, since: Date)
    /// The scans read different wallets, exchanges or manual holdings, so the
    /// difference is not a market move.
    case sourcesChanged
  }

  /// The latest scan, if any.
  let latest: ScanRunRecord?
  /// Holdings of the latest scan whose wallet, exchange or manual entry is
  /// still saved. A removed source stops counting at once; the stored scan is
  /// untouched (History still shows it).
  let current: [TrackedAsset]
  /// `current` with the dust preference applied: what charts and lists show.
  let visible: [TrackedAsset]
  /// Priced value of `current`. Dust is a visibility choice and never lowers it.
  let total: Double
  let unpriced: [TrackedAsset]
  let hiddenDustCount: Int
  let hiddenDustValueUsd: Double
  let drift: ScanSourceDrift
  let change: Change
  let walletCount: Int
  let exchangeCount: Int
  let manualCount: Int

  @MainActor
  init(state: AppState) {
    let latest = state.latestScan
    let savedKeys = state.savedScanSourceKeys
    let current = (latest?.holdings ?? []).filter {
      AppState.holdingSourceIsSaved($0, savedKeys: savedKeys)
    }
    self.latest = latest
    self.current = current
    visible = state.chartHoldings
    total = AppState.validatedPortfolioTotal(current) ?? 0
    unpriced = current.filter { $0.pricingStatus != .priced }
    let preferences = state.document.preferences
    if preferences.hideDust {
      let threshold = preferences.dustThreshold.isFinite ? max(0, preferences.dustThreshold) : 0
      let dust = current.filter {
        $0.pricingStatus == .priced && (!$0.valueUsd.isFinite || $0.valueUsd < threshold)
      }
      hiddenDustCount = dust.count
      hiddenDustValueUsd =
        AppState.validatedPortfolioTotal(dust.filter { $0.valueUsd.isFinite && $0.valueUsd >= 0 })
        ?? 0
    } else {
      hiddenDustCount = 0
      hiddenDustValueUsd = 0
    }
    let drift = state.latestScanSourceDrift
    self.drift = drift
    walletCount = state.document.wallets.count
    exchangeCount = state.document.exchangeConnections.count
    manualCount = state.document.manualHoldings.filter(\.enabled).count
    change = Self.change(
      runs: state.document.scanRuns, drift: drift,
      context: ScanSourceContext(document: state.document))
  }

  /// Change against the scan before the latest one. The total is compared only
  /// when both scans read the same sources; otherwise the difference would
  /// credit a new wallet to the market.
  static func change(
    runs: [ScanRunRecord], drift: ScanSourceDrift, context: ScanSourceContext?
  ) -> Change {
    let ordered = runs.sorted { $0.generatedAt > $1.generatedAt }
    guard ordered.count > 1 else { return .none }
    let latest = ordered[0]
    let previous = ordered[1]
    // The headline already left out a removed source; a delta between the two
    // stored scans would not describe it.
    guard drift.removed == 0,
      PortfolioAnalytics.runsShareSources(previous, latest, context: context)
    else { return .sourcesChanged }
    let older = PortfolioAnalytics.totalValueUsd(previous.holdings)
    let newer = PortfolioAnalytics.totalValueUsd(latest.holdings)
    let delta = newer - older
    guard delta.isFinite else { return .none }
    return .moved(
      delta: delta, fraction: older > 0 ? delta / older : nil, since: previous.generatedAt)
  }

  var hasScan: Bool { latest != nil }

  /// "3 wallets, 1 exchange" (empty counts are left out).
  var sourcesText: String {
    var parts: [String] = []
    if walletCount > 0 { parts.append(MacFormat.count(walletCount, "wallet")) }
    if exchangeCount > 0 { parts.append(MacFormat.count(exchangeCount, "exchange")) }
    if manualCount > 0 { parts.append(MacFormat.count(manualCount, "manual holding")) }
    return parts.joined(separator: ", ")
  }

  /// One plain sentence about holdings that have no price, or nil.
  var unpricedSentence: String? { Self.unpricedSentence(unpriced) }

  static func unpricedSentence(_ holdings: [TrackedAsset]) -> String? {
    guard !holdings.isEmpty else { return nil }
    let named = holdings.sorted {
      $0.symbol == $1.symbol ? $0.id < $1.id : $0.symbol < $1.symbol
    }
    if named.count == 1, let only = named.first {
      return "\(only.symbol) on \(location(of: only)) has no price, so it\u{2019}s left out of the total."
    }
    let shown = named.prefix(3).map { "\($0.symbol) on \(location(of: $0))" }
    let more = named.count > shown.count ? ", and \(named.count - shown.count) more" : ""
    return
      "\(named.count) holdings have no price, so they\u{2019}re left out of the total: \(shown.joined(separator: ", "))\(more)."
  }

  static func location(of asset: TrackedAsset) -> String {
    asset.exchangeProvider?.label ?? asset.chainName
  }

  /// "Sources changed since the last scan (1 added, 1 removed)."
  var driftSentence: String? {
    guard drift.hasChanges else { return nil }
    var parts: [String] = []
    if drift.added > 0 { parts.append("\(drift.added) added") }
    if drift.removed > 0 { parts.append("\(drift.removed) removed") }
    if drift.edited > 0 { parts.append("\(drift.edited) edited") }
    return "Sources changed since the last scan (\(parts.joined(separator: ", "))). Scan to update."
  }

  /// "3 small balances hidden, worth $12.40."
  var dustSentence: String? {
    guard hiddenDustCount > 0 else { return nil }
    let noun = hiddenDustCount == 1 ? "small balance" : "small balances"
    return "\(hiddenDustCount) \(noun) hidden, worth \(money(hiddenDustValueUsd))."
  }
}

// MARK: - Coin rows

/// One coin in a list: what it is, where it is, and what it is worth.
struct MacCoinRow: Identifiable, Equatable {
  var id: String { summary.id }
  let summary: CoinSummary
  let name: String
  /// "Ethereum, Base, Kraken" and any staked, unbonding or reward amounts.
  let whereText: String
  /// Of the priced value shown in the list, 0...1.
  let share: Double

  var isPriced: Bool { summary.pricedAmount > 0 }

  static func rows(for holdings: [TrackedAsset]) -> [MacCoinRow] {
    let summaries = PortfolioAnalytics.coinSummaries(holdings)
    let total = summaries.map(\.valueUsd).reduce(0, +)
    var names: [String: String] = [:]
    for asset in holdings.sorted(by: { $0.valueUsd > $1.valueUsd }) {
      let key = CoinIdentity.key(for: asset)
      let name = asset.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if names[key] == nil, !name.isEmpty { names[key] = name }
    }
    return summaries.map { summary in
      MacCoinRow(
        summary: summary,
        name: names[summary.id] ?? summary.symbol,
        whereText: whereText(for: summary),
        share: total > 0 ? summary.valueUsd / total : 0
      )
    }
  }

  static func whereText(for summary: CoinSummary) -> String {
    var networks: [String] = []
    for location in summary.locations where !networks.contains(location.networkLabel) {
      networks.append(location.networkLabel)
    }
    var text = networks.prefix(3).joined(separator: ", ")
    if networks.count > 3 { text += " +\(networks.count - 3)" }
    let extras = summary.states.compactMap { breakdown -> String? in
      switch breakdown.state {
      case .staked, .unbonding, .rewards:
        return "\(MacFormat.amount(breakdown.amount)) \(breakdown.state.displayName.lowercased())"
      case .liquid, .onExchange:
        return nil
      }
    }
    if !extras.isEmpty { text += (text.isEmpty ? "" : " \u{00B7} ") + extras.joined(separator: ", ") }
    return text
  }

  /// "ETH, Ether, Ethereum and Base, 4.1 ETH, $13,120.00" for VoiceOver.
  var spokenText: String {
    let value = isPriced ? money(summary.valueUsd) : "no price"
    return "\(summary.symbol), \(name), \(whereText), \(MacFormat.amount(summary.totalAmount)) \(summary.symbol), \(value)"
  }
}
