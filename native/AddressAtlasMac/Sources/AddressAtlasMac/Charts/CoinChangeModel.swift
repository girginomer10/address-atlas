import AddressAtlasCore
import Foundation

/// Why one coin's value changed since the previous comparable scan: how much
/// was the price and how much was coins arriving or leaving, with a plain
/// sentence for each. Pure and `Sendable`.
///
/// "Comparable" means the earlier scan read the same sources as the latest one
/// (`PortfolioAnalytics.runsShareSources`), so a wallet that was added is not
/// reported as a gain.
struct CoinChangeModel: Equatable, Sendable {
  /// What can be said about the coin.
  enum Outcome: Equatable, Sendable {
    /// Fewer than two saved scans.
    case needsTwoScans
    /// No earlier scan read the same sources as the latest one.
    case notComparable
    /// The coin is in neither scan.
    case noCoin
    case compared(Comparison)
  }

  struct Comparison: Equatable, Sendable {
    enum Status: String, Sendable {
      case unchanged
      case added
      case removed
      case changed
    }

    let status: Status
    let previousDate: Date
    let latestDate: Date
    let deltaUsd: Double
    let priceEffectUsd: Double
    let amountEffectUsd: Double
    let valuationGapUsd: Double
    let olderPriceUsd: Double?
    let newerPriceUsd: Double?
    let olderAmount: Double
    let newerAmount: Double
    /// The place the amount changed most, in the direction of the net change.
    let mainLocation: Location?
  }

  struct Location: Equatable, Sendable {
    let label: String
    /// This location's share of the change in its direction, 0...1.
    let share: Double
    /// Locations that changed in the direction of the net change.
    let count: Int
  }

  let coinKey: String
  let symbol: String
  let timeZone: TimeZone
  let outcome: Outcome

  static func make(
    runs: [ScanRunRecord],
    coinKey: String,
    context: ScanSourceContext?,
    timeZone: TimeZone
  ) -> CoinChangeModel {
    func model(_ symbol: String, _ outcome: Outcome) -> CoinChangeModel {
      CoinChangeModel(coinKey: coinKey, symbol: symbol, timeZone: timeZone, outcome: outcome)
    }
    guard let pair = HistoryRuns.latestPair(runs, context: context) else {
      return model(coinKey, .needsTwoScans)
    }
    let symbol =
      (pair.latest.holdings + pair.previous.holdings).first {
        CoinIdentity.key(for: $0) == coinKey
      }.map(CoinIdentity.displaySymbol(for:)) ?? coinKey
    guard pair.comparable else { return model(symbol, .notComparable) }

    let attribution = PortfolioAnalytics.attribution(
      from: pair.previous, to: pair.latest, context: context)
    guard let change = attribution.coins.first(where: { $0.id == coinKey }) else {
      // Unchanged, or not there at all.
      let present = (pair.latest.holdings + pair.previous.holdings).contains {
        CoinIdentity.key(for: $0) == coinKey
      }
      guard present else { return model(symbol, .noCoin) }
      let amount = pair.latest.holdings.filter { CoinIdentity.key(for: $0) == coinKey }
        .map(\.amount).reduce(0, +)
      return model(
        symbol,
        .compared(
          Comparison(
            status: .unchanged, previousDate: pair.previous.generatedAt,
            latestDate: pair.latest.generatedAt, deltaUsd: 0, priceEffectUsd: 0,
            amountEffectUsd: 0, valuationGapUsd: 0, olderPriceUsd: nil, newerPriceUsd: nil,
            olderAmount: amount, newerAmount: amount, mainLocation: nil)))
    }
    let status: Comparison.Status
    switch change.status {
    case .added: status = .added
    case .removed: status = .removed
    case .changed: status = .changed
    }
    return model(
      change.symbol,
      .compared(
        Comparison(
          status: status, previousDate: attribution.olderDate, latestDate: attribution.newerDate,
          deltaUsd: change.deltaUsd, priceEffectUsd: change.priceEffectUsd,
          amountEffectUsd: change.amountEffectUsd, valuationGapUsd: change.valuationGapUsd,
          olderPriceUsd: change.olderPriceUsd, newerPriceUsd: change.newerPriceUsd,
          olderAmount: change.olderAmount, newerAmount: change.newerAmount,
          mainLocation: mainLocation(of: change))))
  }

  private static func mainLocation(of change: CoinChange) -> Location? {
    let net = change.newerAmount - change.olderAmount
    guard net != 0 else { return nil }
    let sameDirection = change.locationChanges.filter {
      ($0.deltaAmount > 0) == (net > 0) && $0.deltaAmount != 0
    }
    // Wallets on one network read as one place: "on Base", not "on Main".
    var byNetwork: [String: Double] = [:]
    for location in sameDirection {
      byNetwork[location.networkLabel, default: 0] += abs(location.deltaAmount)
    }
    let ranked = byNetwork.sorted { lhs, rhs in
      if lhs.value != rhs.value { return lhs.value > rhs.value }
      return lhs.key < rhs.key
    }
    guard let top = ranked.first else { return nil }
    let total = ranked.map(\.value).reduce(0, +)
    return Location(
      label: top.key, share: total > 0 ? top.value / total : 1, count: ranked.count)
  }

  // MARK: Wording

  var comparison: Comparison? {
    if case .compared(let comparison) = outcome { return comparison }
    return nil
  }

  /// A message that stands in for the whole widget, or nil when there is a
  /// comparison to show.
  var message: String? {
    switch outcome {
    case .needsTwoScans: "Save another scan to see why this coin's value changes."
    case .notComparable:
      "Your sources changed since your earlier scans, so there is no like-for-like comparison."
    case .noCoin: "No \(symbol) in your last two scans."
    case .compared: nil
    }
  }

  /// "ETH changed +$410 since 3 Nov".
  var headline: String? {
    guard let comparison else { return nil }
    let since = "since \(HistoryChartFormat.day(comparison.previousDate, timeZone: timeZone))"
    switch comparison.status {
    case .unchanged: return "\(symbol) did not change \(since)"
    case .added: return "\(symbol) is new \(since): \(HistoryChartFormat.signedUsd(comparison.deltaUsd))"
    case .removed: return "\(symbol) is gone \(since): \(HistoryChartFormat.signedUsd(comparison.deltaUsd))"
    case .changed:
      if abs(comparison.deltaUsd) < 0.005 { return "\(symbol) is worth the same \(since)" }
      return "\(symbol) changed \(HistoryChartFormat.signedUsd(comparison.deltaUsd)) \(since)"
    }
  }

  /// "Price went from $3,107 to $3,200." Nil for a coin that was added or
  /// removed, where only the amount matters.
  var priceSentence: String? {
    guard let comparison, comparison.status == .changed || comparison.status == .unchanged else {
      return nil
    }
    switch (comparison.olderPriceUsd, comparison.newerPriceUsd) {
    case (let older?, let newer?):
      if abs(newer - older) <= 1e-9 * max(1, abs(older)) { return "Price did not change." }
      // Cents for cheap coins, whole dollars above $100, the same for both.
      let cents = max(abs(older), abs(newer)) < 100
      return
        "Price went from \(HistoryChartFormat.usd(older, cents: cents)) to \(HistoryChartFormat.usd(newer, cents: cents))."
    case (nil, nil):
      return comparison.status == .unchanged ? "Price did not change." : nil
    default:
      return "One of the two scans has no price for \(symbol), so its price move is not counted."
    }
  }

  /// "You hold 0.0094 ETH more, on Base."
  var amountSentence: String? {
    guard let comparison else { return nil }
    switch comparison.status {
    case .added: return "You now hold \(symbol). It was not in the earlier scan."
    case .removed: return "You no longer hold \(symbol)."
    case .unchanged: return "You did not receive or send any \(symbol)."
    case .changed:
      let delta = comparison.newerAmount - comparison.olderAmount
      guard abs(delta) > 1e-12 * max(1, abs(comparison.olderAmount)) else {
        return "You did not receive or send any \(symbol)."
      }
      let direction = delta > 0 ? "more" : "less"
      var sentence = "You hold \(HistoryChartFormat.amount(abs(delta))) \(symbol) \(direction)"
      if let location = comparison.mainLocation {
        if location.count == 1 || location.share >= 0.9 {
          sentence += ", on \(location.label)"
        } else if location.share >= 0.5 {
          sentence += ", mostly on \(location.label)"
        }
      }
      return sentence + "."
    }
  }

  var effects: [HistoryEffect] {
    guard let comparison else { return [] }
    return HistoryEffects.effects(
      price: comparison.priceEffectUsd, amount: comparison.amountEffectUsd,
      valuationGap: comparison.valuationGapUsd)
  }

  var spokenSummary: String {
    if let message { return message }
    var parts: [String] = []
    if let headline { parts.append(headline) }
    parts += effects.map { "\($0.title) \(HistoryChartFormat.signedUsd($0.valueUsd))" }
    if let priceSentence { parts.append(priceSentence) }
    if let amountSentence { parts.append(amountSentence) }
    return parts.joined(separator: ". ")
  }
}
