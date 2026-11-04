import AddressAtlasCore
import Foundation

// MARK: - Formatting and wording
//
// Every number and sentence the part-C1 chart views print goes through here, so
// the seven views agree on rounding, locale, and wording. Values come from
// `PortfolioAnalytics` in US dollars; the display currency is fixed to USD in
// the app today (Settings shows it as the one, current option), so the code
// lives in one constant that a future currency preference can replace.

enum ChartKitFormat {
  /// ISO code of the currency analytics values are expressed in.
  static let currencyCode = "USD"

  enum Money {
    /// `$27,980`
    case whole
    /// `$27,979.82`
    case cents
    /// `$28K`, for places too small for the whole figure.
    case compact
  }

  static func usd(_ value: Double, _ style: Money = .whole) -> String {
    let safe = value.isFinite ? value : 0
    let locale = AtlasFormatting.locale
    switch style {
    case .whole:
      return safe.formatted(
        .currency(code: currencyCode).precision(.fractionLength(0)).locale(locale))
    case .cents:
      return safe.formatted(
        .currency(code: currencyCode).precision(.fractionLength(2)).locale(locale))
    case .compact:
      // Currency styles only gained compact notation in macOS 15 and iOS 18,
      // so the symbol and the compact number are put together here. This is
      // the last-resort form for tiny places; the symbol leads in every locale.
      let symbolFormatter = NumberFormatter()
      symbolFormatter.locale = locale
      symbolFormatter.numberStyle = .currency
      symbolFormatter.currencyCode = currencyCode
      let symbol = symbolFormatter.currencySymbol ?? currencyCode
      let number = safe.formatted(
        .number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
      return symbol + number
    }
  }

  /// The whole percent a share rounds to, or nil when it rounds to nothing.
  static func wholePercent(_ share: Double) -> Int? {
    guard share.isFinite, share > 0 else { return nil }
    let rounded = Int((min(share, 1) * 100).rounded())
    return rounded == 0 ? nil : rounded
  }

  /// `57%`, `<1%` for a share that rounds to nothing, `0%` for none.
  static func percent(_ share: Double) -> String {
    let locale = AtlasFormatting.locale
    guard share.isFinite, share > 0 else {
      return 0.0.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
    guard let whole = wholePercent(share) else {
      let tiny = 0.01.formatted(.percent.precision(.fractionLength(0)).locale(locale))
      return "<" + tiny
    }
    return (Double(whole) / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
  }

  /// `57 percent` or `less than 1 percent`, for VoiceOver.
  static func spokenPercent(_ share: Double) -> String {
    guard share.isFinite, share > 0 else { return "0 percent" }
    guard let whole = wholePercent(share) else { return "less than 1 percent" }
    return "\(whole) percent"
  }

  /// `Bitcoin, 57 percent, $27,980`
  static func spokenSlice(name: String, share: Double, valueUsd: Double) -> String {
    "\(name), \(spokenPercent(share)), \(usd(valueUsd))"
  }

  // MARK: Plain sentences

  static let emptyTitle = "No priced holdings yet"

  /// "3 holdings have no price and aren't in the total."
  static func unpricedNote(count: Int) -> String {
    count == 1
      ? "1 holding has no price and isn't in the total."
      : "\(count) holdings have no price and aren't in the total."
  }

  /// Shorter form for a place that cannot fit the sentence.
  static func unpricedShort(count: Int) -> String {
    "\(count) unpriced"
  }

  /// "5 assets", "1 network".
  static func count(_ number: Int, of grouping: PortfolioGrouping) -> String {
    let (singular, plural): (String, String) =
      switch grouping {
      case .asset: ("asset", "assets")
      case .network: ("network", "networks")
      case .source: ("wallet or exchange", "wallets and exchanges")
      case .state: ("state", "states")
      case .kind: ("type", "types")
      }
    return "\(number) \(number == 1 ? singular : plural)"
  }

  /// "by asset", for summaries.
  static func groupingPhrase(_ grouping: PortfolioGrouping) -> String {
    switch grouping {
    case .asset: "by asset"
    case .network: "by network"
    case .source: "by wallet or exchange"
    case .state: "by state"
    case .kind: "by type"
    }
  }

  static func holdings(_ number: Int) -> String {
    number == 1 ? "1 holding" : "\(number) holdings"
  }
}
