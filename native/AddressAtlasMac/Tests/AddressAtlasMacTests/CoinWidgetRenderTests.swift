import AddressAtlasCore
import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import AddressAtlasMac

/// Renders the coin widgets in the states the shared fixture does not reach:
/// undated (Solana) unbonding, nothing unbonding, an unlock date that has
/// passed, scans that are not comparable, a single scan, an unpriced coin and
/// a manual holding. A default run checks that each picture has content; with
/// `ATLAS_WRITE_SCREENSHOTS=1` it writes PNGs (`coin-edge-<state>-<widget>-...`)
/// next to the main harness's, into `ATLAS_SCREENSHOT_DIR` (or
/// `docs/design/screenshots/phase2/`).
@MainActor
final class CoinWidgetRenderTests: XCTestCase {
  private static let utc = TimeZone(identifier: "UTC") ?? .current
  private var utc: TimeZone { Self.utc }
  private let now = ChartFixture.scanDate(day: ChartFixture.dayCount - 1, hour: 1)

  override func setUp() {
    super.setUp()
    setenv("ADDRESS_ATLAS_UI_LOCALE", "en_US", 1)
  }

  struct Scenario {
    let name: String
    let make: (PortfolioChartDensity) -> AnyView
  }

  private static func makeInput(
    holdings: [TrackedAsset], runs: [ScanRunRecord] = [], coinKey: String,
    density: PortfolioChartDensity
  ) -> PortfolioChartInput {
    PortfolioChartInput(
      holdings: holdings, runs: runs, coinKey: coinKey, timeZone: Self.utc, density: density)
  }

  private func solanaRuns() -> [ScanRunRecord] {
    func sol(_ amount: Double, _ source: AssetSource) -> TrackedAsset {
      TrackedAsset(
        id: "\(ChartFixture.solanaAddress)-solana-SOL-\(source.rawValue)",
        address: ChartFixture.solanaAddress, chainId: "solana", chainName: "Solana",
        family: .solana, symbol: "SOL", name: "Solana SOL", amount: amount, priceUsd: 140,
        valueUsd: amount * 140, pricingStatus: .priced, source: source, walletLabel: "Phantom")
    }
    func run(_ day: Int, _ holdings: [TrackedAsset]) -> ScanRunRecord {
      ScanRunRecord(
        id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", 5_000 + day))!,
        generatedAt: ChartFixture.scanDate(day: 30 + day, hour: 3),
        totalUsd: holdings.map(\.valueUsd).reduce(0, +), inputCount: 1, holdings: holdings)
    }
    return [
      run(0, [sol(12.5, .native), sol(30, .staked)]),
      run(3, [sol(12.5, .native), sol(30, .staked)]),
      run(5, [sol(12.5, .native), sol(18, .staked), sol(12, .unbonding)]),
      run(8, [sol(12.5, .native), sol(18, .staked), sol(12, .unbonding)]),
      run(11, [sol(12.5, .native), sol(18, .staked), sol(12, .unbonding)]),
    ]
  }

  private func scenarios() -> [Scenario] {
    let fixtureRuns = ChartFixture.runs()
    let atomHoldings = fixtureRuns.last?.holdings ?? []
    let solana = solanaRuns()
    let solanaHoldings = solana.last?.holdings ?? []

    // Scans that read different sources, so nothing is comparable.
    let differentSources = [
      CoinWidgetTestRuns.run(day: 0, .init(liquid: 5, staked: 300)),
      CoinWidgetTestRuns.run(day: 1, .init(liquid: 5, staked: 300, extraWallet: true)),
    ]

    let manualHoldings = [
      TrackedAsset(
        id: "w", address: ChartFixture.bitcoinAddress, chainId: "bitcoin", chainName: "Bitcoin",
        family: .bitcoin, symbol: "BTC", name: "BTC", amount: 0.3, priceUsd: 60_000,
        valueUsd: 18_000, pricingStatus: .priced, source: .native, walletLabel: "Cold storage"),
      TrackedAsset(
        id: "k", address: "Kraken", chainId: "kraken", chainName: "Kraken", family: .exchange,
        symbol: "BTC", name: "BTC", amount: 0.05, priceUsd: 60_000, valueUsd: 3_000,
        pricingStatus: .priced, source: .exchange, walletLabel: "Kraken",
        exchangeId: ChartFixture.krakenID, exchangeProvider: .kraken),
      TrackedAsset(
        id: "manual-11111111-2222-4333-8444-555555555555", address: "Hardware wallet",
        chainId: "manual-Manual", chainName: "Ledger", family: .exchange, symbol: "BTC",
        name: "BTC", amount: 0.1, priceUsd: 60_000, valueUsd: 6_000, pricingStatus: .priced,
        source: .exchange),
    ]
    let unpricedHoldings = [
      TrackedAsset(
        id: "x", address: ChartFixture.evmAddress, chainId: "ethereum", chainName: "Ethereum",
        family: .evm, symbol: "MEME", name: "Meme", amount: 1_000_000, priceUsd: 0, valueUsd: 0,
        pricingStatus: .unpriced, source: .erc20, walletLabel: "Main"),
      TrackedAsset(
        id: "y", address: ChartFixture.evmAddress, chainId: "ethereum", chainName: "Ethereum",
        family: .evm, symbol: "MEME", name: "Meme", amount: 250_000, priceUsd: 0, valueUsd: 0,
        pricingStatus: .unpriced, source: .erc20, walletLabel: "Main"),
    ]

    func atom(_ density: PortfolioChartDensity) -> PortfolioChartInput {
      Self.makeInput(holdings: atomHoldings, runs: fixtureRuns, coinKey: "ATOM", density: density)
    }
    let afterUnlock = ChartFixture.unlockDate.addingTimeInterval(2 * 86_400)

    return [
      Scenario(name: "solana-undated-unbonding-timeline") { density in
        AnyView(
          CoinUnlockTimelineView(
            input: Self.makeInput(holdings: solanaHoldings, runs: solana, coinKey: "SOL", density: density),
            now: self.now))
      },
      Scenario(name: "solana-undated-unbonding-strip") { density in
        AnyView(
          CoinStateStripView(
            input: Self.makeInput(holdings: solanaHoldings, runs: solana, coinKey: "SOL", density: density)))
      },
      Scenario(name: "solana-amount-history") { density in
        AnyView(
          CoinAmountHistoryView(
            input: Self.makeInput(holdings: solanaHoldings, runs: solana, coinKey: "SOL", density: density)))
      },
      Scenario(name: "nothing-unbonding-timeline") { density in
        AnyView(
          CoinUnlockTimelineView(
            input: Self.makeInput(
              holdings: atomHoldings, runs: fixtureRuns, coinKey: "ETH", density: density),
            now: self.now))
      },
      Scenario(name: "unlock-date-passed-timeline") { density in
        AnyView(CoinUnlockTimelineView(input: atom(density), now: afterUnlock))
      },
      Scenario(name: "no-comparable-scan-change") { density in
        AnyView(
          CoinChangeView(
            input: Self.makeInput(
              holdings: differentSources.last?.holdings ?? [], runs: differentSources,
              coinKey: "ATOM", density: density)))
      },
      Scenario(name: "no-comparable-scan-amount-history") { density in
        AnyView(
          CoinAmountHistoryView(
            input: Self.makeInput(
              holdings: differentSources.last?.holdings ?? [], runs: differentSources,
              coinKey: "ATOM", density: density)))
      },
      Scenario(name: "one-scan-change") { density in
        AnyView(
          CoinChangeView(
            input: Self.makeInput(
              holdings: atomHoldings, runs: Array(fixtureRuns.suffix(1)), coinKey: "ATOM",
              density: density)))
      },
      Scenario(name: "one-scan-amount-history") { density in
        AnyView(
          CoinAmountHistoryView(
            input: Self.makeInput(
              holdings: atomHoldings, runs: Array(fixtureRuns.suffix(1)), coinKey: "ATOM",
              density: density)))
      },
      Scenario(name: "coin-not-held-strip") { density in
        AnyView(
          CoinStateStripView(
            input: Self.makeInput(holdings: atomHoldings, runs: fixtureRuns, coinKey: "XRP", density: density)))
      },
      Scenario(name: "unpriced-strip") { density in
        AnyView(
          CoinStateStripView(
            input: Self.makeInput(holdings: unpricedHoldings, coinKey: "MEME", density: density)))
      },
      Scenario(name: "manual-holding-custody") { density in
        AnyView(
          CoinCustodyView(input: Self.makeInput(holdings: manualHoldings, coinKey: "BTC", density: density)))
      },
      Scenario(name: "summary-only-strip") { density in
        AnyView(
          CoinStateStripView(
            summary: PortfolioAnalytics.coinSummary(atomHoldings, coin: "ATOM")!,
            density: density))
      },
      Scenario(name: "summary-only-custody") { density in
        AnyView(
          CoinCustodyView(
            summary: PortfolioAnalytics.coinSummary(atomHoldings, coin: "BTC")
              ?? PortfolioAnalytics.coinSummary(manualHoldings, coin: "BTC")!,
            density: density))
      },
      // Large accessibility text: rows stack and sentences wrap.
      Scenario(name: "accessibility-size-strip") { density in
        AnyView(
          CoinStateStripView(input: atom(density)).environment(\.dynamicTypeSize, .accessibility3))
      },
      Scenario(name: "accessibility-size-change") { density in
        AnyView(
          CoinChangeView(
            input: Self.makeInput(
              holdings: atomHoldings, runs: fixtureRuns, coinKey: "ETH", density: density)
          ).environment(\.dynamicTypeSize, .accessibility3))
      },
      Scenario(name: "accessibility-size-custody") { density in
        AnyView(
          CoinCustodyView(
            input: Self.makeInput(
              holdings: manualHoldings, runs: [], coinKey: "BTC", density: density)
          ).environment(\.dynamicTypeSize, .accessibility3))
      },
      Scenario(name: "accessibility-size-timeline") { density in
        AnyView(
          CoinUnlockTimelineView(input: atom(density), now: self.now)
            .environment(\.dynamicTypeSize, .accessibility3))
      },
      Scenario(name: "summary-only-timeline") { density in
        AnyView(
          CoinUnlockTimelineView(
            summary: PortfolioAnalytics.coinSummary(atomHoldings, coin: "ATOM")!, now: self.now,
            timeZone: self.utc, density: density))
      },
    ]
  }

  // MARK: Tests

  func testEdgeStatesRenderContent() throws {
    let looks: [ChartRenderTests.Look] = [
      .init(theme: .chainColors, variant: .light), .init(theme: .acid, variant: .dark),
    ]
    for scenario in scenarios() {
      for look in looks {
        for density in [PortfolioChartDensity.full, .compact] {
          let image = try render(scenario, look: look, density: density)
          XCTAssertGreaterThan(
            ChartRenderTests.distinctColors(in: image), 3,
            "\(scenario.name) \(look.theme.rawValue) \(density) looks blank")
        }
      }
    }
  }

  func testWriteEdgeStateScreenshotsWhenRequested() throws {
    guard ProcessInfo.processInfo.environment["ATLAS_WRITE_SCREENSHOTS"] == "1" else {
      throw XCTSkip("Set ATLAS_WRITE_SCREENSHOTS=1 to write the edge-state PNGs.")
    }
    let directory = screenshotDirectory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let looks: [ChartRenderTests.Look] = [
      .init(theme: .chainColors, variant: .light), .init(theme: .candy, variant: .dark),
      .init(theme: .acid, variant: .dark),
    ]
    for scenario in scenarios() {
      for look in looks {
        for density in [PortfolioChartDensity.full, .compact] {
          let image = try render(scenario, look: look, density: density)
          let name =
            "coin-edge-\(scenario.name)-\(look.theme.rawValue)-\(look.appearanceName)-\(density == .full ? "full" : "compact").png"
          try ChartRenderTests.pngData(image).write(to: directory.appendingPathComponent(name))
        }
      }
    }
  }

  // MARK: Rendering

  private func render(
    _ scenario: Scenario, look: ChartRenderTests.Look, density: PortfolioChartDensity
  ) throws -> CGImage {
    let tokens = AtlasThemeTokens(theme: look.theme, variant: look.variant)
    let size = density == .full ? ChartRenderTests.fullSize : ChartRenderTests.compactSize
    return try ChartRenderTests.renderImage(
      scenario.make(density), tokens: tokens, colorScheme: look.colorScheme, size: size)
  }

  private var screenshotDirectory: URL {
    if let override = ProcessInfo.processInfo.environment["ATLAS_SCREENSHOT_DIR"], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    var url = URL(fileURLWithPath: #filePath)
    while url.path != "/" {
      url.deleteLastPathComponent()
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("AGENTS.md").path) {
        return url.appendingPathComponent("docs/design/screenshots/phase2", isDirectory: true)
      }
    }
    return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
  }
}
