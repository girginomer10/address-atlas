import AddressAtlasCore
import Foundation

/// Who holds the keys to one coin: your own wallets, exchanges, or entries you
/// typed in by hand (whose custody is unknown). From a coin summary alone.
struct CoinCustodyModel: Equatable, Sendable {
  enum Side: String, CaseIterable, Sendable {
    case wallet
    case exchange
    case manual

    var title: String {
      switch self {
      case .wallet: "In your wallets"
      case .exchange: "On exchanges"
      case .manual: "Entered by hand"
      }
    }

    var shortTitle: String {
      switch self {
      case .wallet: "Wallets"
      case .exchange: "Exchanges"
      case .manual: "By hand"
      }
    }
  }

  /// One wallet, exchange connection or manual holding on a side.
  struct Source: Identifiable, Equatable, Sendable {
    /// `CoinLocation.sourceID`, usable as `.slice(grouping: .source, key:)`.
    let id: String
    let label: String
    let amount: Double
    let valueUsd: Double
  }

  struct Part: Identifiable, Equatable, Sendable {
    var id: String { side.rawValue }
    let side: Side
    let amount: Double
    let valueUsd: Double
    /// Of the coin's total amount, 0...1.
    let fraction: Double
    /// Largest first.
    let sources: [Source]
  }

  let symbol: String
  let totalAmount: Double
  let priced: Bool
  /// Sides that hold an amount, in wallet, exchange, manual order.
  let parts: [Part]
  /// Wallet amount over total amount; nil when the coin has no amount.
  let selfCustodyShare: Double?

  init(summary: CoinSummary) {
    symbol = summary.symbol
    let custody = summary.custody
    totalAmount = custody.totalAmount
    priced = summary.priceUsd != nil
    selfCustodyShare = custody.selfCustodyShare

    var sourcesBySide: [Side: [String: Source]] = [:]
    for location in summary.locations {
      let side = Self.side(of: location)
      var bySource = sourcesBySide[side] ?? [:]
      let existing = bySource[location.sourceID]
      bySource[location.sourceID] = Source(
        id: location.sourceID, label: location.sourceLabel,
        amount: (existing?.amount ?? 0) + location.amount,
        valueUsd: (existing?.valueUsd ?? 0) + location.valueUsd)
      sourcesBySide[side] = bySource
    }
    func part(_ side: Side, amount: Double, value: Double) -> Part? {
      guard amount > 0 else { return nil }
      let sources = (sourcesBySide[side] ?? [:]).values.sorted { lhs, rhs in
        if lhs.valueUsd != rhs.valueUsd { return lhs.valueUsd > rhs.valueUsd }
        if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
        if lhs.label != rhs.label { return lhs.label < rhs.label }
        return lhs.id < rhs.id
      }
      return Part(
        side: side, amount: amount, valueUsd: value,
        fraction: custody.totalAmount > 0 ? amount / custody.totalAmount : 0, sources: sources)
    }
    parts = [
      part(.wallet, amount: custody.walletAmount, value: custody.walletValueUsd),
      part(.exchange, amount: custody.exchangeAmount, value: custody.exchangeValueUsd),
      part(.manual, amount: custody.manualAmount, value: custody.manualValueUsd),
    ].compactMap { $0 }
  }

  /// A manual holding has a `manual:` source; anything in the exchange state is
  /// on an exchange; the rest sits in a wallet the user scanned.
  static func side(of location: CoinLocation) -> Side {
    if location.sourceID.hasPrefix("manual:") { return .manual }
    if location.sourceID.hasPrefix("exchange:") || location.states.contains(.onExchange) {
      return .exchange
    }
    return .wallet
  }

  func part(_ side: Side) -> Part? { parts.first { $0.side == side } }

  var walletAmount: Double { part(.wallet)?.amount ?? 0 }
  var exchangeAmount: Double { part(.exchange)?.amount ?? 0 }
  var manualAmount: Double { part(.manual)?.amount ?? 0 }

  /// "88%", or "0%" when none of it is in your wallets.
  var headline: String {
    guard let share = selfCustodyShare else { return "\u{2014}" }
    return HistoryChartFormat.percent(share)
  }

  /// "0.362 of 0.412 BTC is in your own wallets".
  var sentence: String {
    guard selfCustodyShare != nil else { return "There is no \(symbol) amount to split." }
    let total = HistoryChartFormat.amount(totalAmount)
    if walletAmount <= 0 { return "None of your \(total) \(symbol) is in your own wallets" }
    if walletAmount >= totalAmount - 1e-12 { return "All \(total) \(symbol) is in your own wallets" }
    return "\(HistoryChartFormat.amount(walletAmount)) of \(total) \(symbol) is in your own wallets"
  }

  /// Explains the part of the total that is not counted as self-custody
  /// because nobody can say who holds it.
  var manualNote: String? {
    guard manualAmount > 0 else { return nil }
    return
      "\(HistoryChartFormat.amount(manualAmount)) \(symbol) was entered by hand, so who holds the keys is not known."
  }

  func amountText(_ amount: Double) -> String {
    "\(HistoryChartFormat.amount(amount)) \(symbol)"
  }

  func valueText(_ valueUsd: Double) -> String {
    CoinWidgetResolver.valueText(valueUsd, priced: priced)
  }

  var spokenSummary: String {
    var sentences = ["\(symbol) custody. \(headline) self-custody. \(sentence)."]
    for part in parts {
      sentences.append("\(part.side.title): \(amountText(part.amount)).")
    }
    if let manualNote { sentences.append(manualNote) }
    return sentences.joined(separator: " ")
  }
}
