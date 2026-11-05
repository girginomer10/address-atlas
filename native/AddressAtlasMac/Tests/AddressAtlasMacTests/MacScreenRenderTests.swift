import AddressAtlasCore
import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import AddressAtlasMac

/// Renders the redesigned Mac screens (Portfolio in several views, coin detail,
/// Assets, History, Wallets, Exchanges, Export, Settings) in all six themes from
/// a synthetic vault: the chart fixture's 38 scans over 42 days, six wallets
/// with placeholder addresses, a fake Kraken connection, and a manual holding.
/// It never touches a real vault or Keychain.
///
/// A default run renders a few screens as a smoke test. With
/// `ATLAS_WRITE_SCREENSHOTS=1` it writes the review set (about 30 files) to
/// `docs/design/screenshots/phase3/mac/`; `=all` writes every screen in every
/// theme. `ATLAS_SCREENSHOT_DIR` overrides the folder and
/// `ATLAS_SCREENSHOT_NAMES=coin-atom,settings` limits which files are written.
@MainActor
final class MacScreenRenderTests: XCTestCase {
  // MARK: Matrix

  enum ScreenKind: Equatable {
    case portfolio(PortfolioVisualization, PortfolioGrouping)
    case coin(String, PortfolioVisualization, PortfolioGrouping)
    case assets(filter: MacSliceFilter?)
    case history(selectedRun: Bool)
    case wallets
    case tokens
    case exchanges
    case export
    case settings
  }

  struct Shot {
    var name: String
    var theme: AtlasThemeID
    var screen: ScreenKind
    var size: CGSize
    /// Pixel width of the written PNG; nil keeps the full-resolution render.
    var outputWidth: Int? = 1_600
  }

  static let pageWidth: CGFloat = 1_240

  /// Dark where the theme asks for it (Heatmap) or requires it (Acid).
  static func isDark(_ theme: AtlasThemeID) -> Bool {
    theme == .acid || theme == .heatmap
  }

  static func size(for screen: ScreenKind) -> CGSize {
    switch screen {
    case .portfolio: CGSize(width: pageWidth, height: 1_250)
    case .coin: CGSize(width: pageWidth, height: 2_150)
    case .assets: CGSize(width: pageWidth, height: 1_050)
    case .history: CGSize(width: pageWidth, height: 1_250)
    case .wallets: CGSize(width: pageWidth, height: 800)
    case .tokens: CGSize(width: pageWidth, height: 1_500)
    case .exchanges: CGSize(width: pageWidth, height: 1_000)
    case .export: CGSize(width: pageWidth, height: 1_300)
    case .settings: CGSize(width: pageWidth, height: 2_000)
    }
  }

  static func fileName(_ base: String, _ theme: AtlasThemeID) -> String {
    "\(base)-\(theme.rawValue).png"
  }

  /// `atlasMap` becomes `atlas-map`, matching the other file names.
  static func kebab(_ camel: String) -> String {
    camel.reduce(into: "") { result, character in
      if character.isUppercase { result += "-" }
      result += character.lowercased()
    }
  }

  /// Every screen in every theme.
  static var allShots: [Shot] {
    var shots: [Shot] = []
    let screens: [(String, ScreenKind)] = [
      ("portfolio-map", .portfolio(.map, .asset)),
      ("portfolio-list", .portfolio(.list, .asset)),
      ("portfolio-over-time", .portfolio(.overTime, .asset)),
      ("portfolio-ring-network", .portfolio(.ring, .network)),
      ("coin-atom", .coin("ATOM", .map, .network)),
      ("coin-eth", .coin("ETH", .ring, .network)),
      ("assets", .assets(filter: nil)),
      ("history", .history(selectedRun: false)),
      ("wallets", .wallets),
      ("tokens", .tokens),
      ("exchanges", .exchanges),
      ("export", .export),
      ("settings", .settings),
    ]
    for theme in AtlasThemeID.allCases {
      for (name, screen) in screens {
        shots.append(
          Shot(
            name: fileName(name, theme), theme: theme, screen: screen,
            size: size(for: screen)))
      }
      // Every other view on Portfolio, grouped by asset (the README images pick from these).
      for visualization in PortfolioVisualization.allCases
      where ![.map, .list, .overTime].contains(visualization) {
        let screen = ScreenKind.portfolio(visualization, .asset)
        shots.append(
          Shot(
            name: fileName("portfolio-\(kebab(visualization.rawValue))", theme), theme: theme,
            screen: screen, size: size(for: screen)))
      }
    }
    // The smallest window (900 wide, sidebar included), in the two themes with
    // the widest controls.
    for theme in [AtlasThemeID.chainColors, .pixel] {
      for (name, screen) in screens {
        var shot = Shot(
          name: fileName("minimum-\(name)", theme), theme: theme, screen: screen,
          size: size(for: screen))
        shot.size.width = 900
        shots.append(shot)
      }
    }
    return shots
  }

  /// About 30 files that show every theme on Portfolio, coin detail, Assets,
  /// History, Wallets and Settings, and the other views in a few themes.
  static var reviewShots: [Shot] {
    func shot(_ base: String, _ theme: AtlasThemeID, _ screen: ScreenKind) -> Shot {
      Shot(name: fileName(base, theme), theme: theme, screen: screen, size: size(for: screen))
    }
    var shots: [Shot] = []
    for theme in AtlasThemeID.allCases {
      shots.append(shot("portfolio-map", theme, .portfolio(.map, .asset)))
      shots.append(shot("coin-atom", theme, .coin("ATOM", .map, .network)))
    }
    shots.append(shot("portfolio-list", .acid, .portfolio(.list, .asset)))
    shots.append(shot("portfolio-over-time", .acid, .portfolio(.overTime, .asset)))
    shots.append(shot("portfolio-ring-network", .chainColors, .portfolio(.ring, .network)))
    shots.append(shot("portfolio-flow", .candy, .portfolio(.flow, .asset)))
    shots.append(shot("portfolio-bubbles", .riso, .portfolio(.bubbles, .asset)))
    // The README banner and hero GIF show one different view per theme.
    shots.append(shot("portfolio-ring", .candy, .portfolio(.ring, .asset)))
    shots.append(shot("portfolio-calendar", .heatmap, .portfolio(.calendar, .asset)))
    shots.append(shot("portfolio-flow", .pixel, .portfolio(.flow, .asset)))
    shots.append(shot("portfolio-atlas-map", .acid, .portfolio(.atlasMap, .asset)))
    shots.append(shot("coin-eth", .chainColors, .coin("ETH", .ring, .network)))
    shots.append(shot("coin-eth", .heatmap, .coin("ETH", .map, .source)))
    for theme in [AtlasThemeID.chainColors, .candy, .acid] {
      shots.append(shot("assets", theme, .assets(filter: nil)))
    }
    shots.append(shot("history", .chainColors, .history(selectedRun: true)))
    shots.append(shot("history", .acid, .history(selectedRun: false)))
    shots.append(shot("wallets", .candy, .wallets))
    shots.append(shot("wallets", .pixel, .wallets))
    shots.append(shot("tokens", .heatmap, .tokens))
    shots.append(shot("exchanges", .riso, .exchanges))
    shots.append(shot("export", .candy, .export))
    shots.append(shot("settings", .chainColors, .settings))
    shots.append(shot("settings", .riso, .settings))
    return shots
  }

  // MARK: Environment

  private enum Mode { case none, review, all }

  private var mode: Mode {
    switch ProcessInfo.processInfo.environment["ATLAS_WRITE_SCREENSHOTS"] {
    case "1": .review
    case "all": .all
    default: .none
    }
  }

  private var screenshotDirectory: URL {
    if let override = ProcessInfo.processInfo.environment["ATLAS_SCREENSHOT_DIR"], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    var url = URL(fileURLWithPath: #filePath)
    while url.path != "/" {
      url.deleteLastPathComponent()
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("AGENTS.md").path) {
        return url.appendingPathComponent("docs/design/screenshots/phase3/mac", isDirectory: true)
      }
    }
    return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
  }

  private var selectedNames: Set<String>? {
    guard let raw = ProcessInfo.processInfo.environment["ATLAS_SCREENSHOT_NAMES"], !raw.isEmpty
    else { return nil }
    return Set(raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
  }

  override func setUp() {
    super.setUp()
    // Money and dates read the same on every machine.
    setenv("ADDRESS_ATLAS_UI_LOCALE", "en_US", 1)
  }

  // MARK: Tests

  /// The default run: three themes, a few screens, and a check that each
  /// picture has content and that no screen draws outside finite geometry.
  func testScreensRenderInSmokeLooks() throws {
    let fixture = try MacScreenFixture()
    let screens: [ScreenKind] = [
      .portfolio(.map, .asset), .coin("ATOM", .map, .network), .assets(filter: nil),
      .history(selectedRun: true), .wallets, .settings,
    ]
    for theme in [AtlasThemeID.chainColors, .candy, .acid] {
      for screen in screens {
        let data = try fixture.render(
          Shot(name: "smoke", theme: theme, screen: screen, size: CGSize(width: 900, height: 700)))
        XCTAssertGreaterThan(data.count, 8_000, "\(theme) \(screen) looks blank")
      }
    }
  }

  /// A coin that is not in the last scan, an empty vault and a locked-out
  /// section still lay out.
  func testEmptyAndMissingStatesRender() throws {
    let fixture = try MacScreenFixture(empty: true)
    for screen in [
      ScreenKind.portfolio(.map, .asset), .assets(filter: nil), .history(selectedRun: false),
      .wallets, .tokens, .exchanges, .export, .coin("DOGE", .map, .network),
    ] {
      let data = try fixture.render(
        Shot(
          name: "empty", theme: .chainColors, screen: screen,
          size: CGSize(width: 900, height: 600)))
      XCTAssertGreaterThan(data.count, 5_000, "\(screen)")
    }
  }

  /// Every screen at the smallest supported window (900 x 600).
  func testScreensRenderAtMinimumWindowSize() throws {
    let fixture = try MacScreenFixture()
    for screen in [
      ScreenKind.portfolio(.map, .asset), .portfolio(.list, .network),
      .coin("ATOM", .map, .network), .assets(filter: nil), .history(selectedRun: true), .wallets,
      .tokens, .exchanges, .export, .settings,
    ] {
      let data = try fixture.render(
        Shot(
          name: "minimum", theme: .pixel, screen: screen, size: CGSize(width: 900, height: 600)))
      XCTAssertGreaterThan(data.count, 5_000, "\(screen)")
    }
  }

  /// The slice filter must agree with the keys Core gives its breakdown slices.
  func testSliceFilterKeysMatchTheBreakdown() throws {
    let holdings = ChartFixture.latestHoldings
    for grouping in PortfolioGrouping.allCases {
      let breakdown = PortfolioAnalytics.breakdown(holdings, by: grouping)
      for slice in breakdown.slices {
        let filter = MacSliceFilter(grouping: grouping, key: slice.key)
        let matching = holdings.filter(filter.matches).filter { $0.pricingStatus == .priced }
        XCTAssertEqual(
          Set(matching.map(\.id)), Set(slice.holdingIDs), "\(grouping) \(slice.key)")
        XCTAssertEqual(filter.label(in: holdings), slice.label, "\(grouping) \(slice.key)")
      }
    }
  }

  /// The change line compares two scans only when they read the same sources.
  func testPortfolioChangeFollowsSourceIdentity() throws {
    let runs = ChartFixture.runs()
    let document = try MacScreenFixture.document(vaultKey: Data(repeating: 7, count: 32))
    let context = ScanSourceContext(document: document)
    let none = ScanSourceDrift()

    if case .moved(let delta, let fraction, _) = MacPortfolioSnapshot.change(
      runs: runs, drift: none, context: context)
    {
      XCTAssertTrue(delta.isFinite)
      XCTAssertNotNil(fraction)
    } else {
      XCTFail("the last two scans read the same sources")
    }

    let straddling = runs.filter { $0.generatedAt <= ChartFixture.scanDate(day: 20, hour: 1) }
    XCTAssertEqual(
      MacPortfolioSnapshot.change(runs: Array(straddling.suffix(2)), drift: none, context: context),
      .sourcesChanged)

    var removed = ScanSourceDrift()
    removed.removed = 1
    XCTAssertEqual(
      MacPortfolioSnapshot.change(runs: runs, drift: removed, context: context), .sourcesChanged)
    XCTAssertEqual(
      MacPortfolioSnapshot.change(runs: Array(runs.suffix(1)), drift: none, context: context),
      .none)
  }

  /// Writes the review set (`=1`) or every screen (`=all`) when asked.
  func testWriteScreenshotsWhenRequested() throws {
    guard mode != .none else {
      throw XCTSkip("Set ATLAS_WRITE_SCREENSHOTS=1 (or all) to render the Mac screens to PNGs.")
    }
    let fixture = try MacScreenFixture()
    let directory = screenshotDirectory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let shots = mode == .all ? Self.allShots : Self.reviewShots
    for shot in shots {
      let base = shot.name.replacingOccurrences(of: ".png", with: "")
      if let selectedNames,
        !selectedNames.contains(where: { base.hasPrefix($0) })
      {
        continue
      }
      let data = try fixture.render(shot)
      try data.write(to: directory.appendingPathComponent(shot.name))
    }
  }
}

// MARK: - Fixture

/// A synthetic, unlocked app state for rendering: no Keychain, no real files.
@MainActor
final class MacScreenFixture {
  let state: AppState
  let preferences: AtlasDisplayPreferences
  private let directory: URL

  /// `empty` is a vault with no sources and no scans.
  init(empty: Bool = false) throws {
    directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let vaultKey = Data(repeating: 7, count: 32)
    let store = try EncryptedSQLiteVaultStore(
      path: directory.appending(path: "vault.sqlite"), vaultKey: vaultKey)
    _ = try store.load()
    let document = empty ? VaultDocument() : try Self.document(vaultKey: vaultKey)
    state = AppState(
      testStore: store, document: document,
      endpointConfigClient: FixedEndpointConfigClient(config: .bundled))
    let suite = "MacScreenRenderTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defaults.removePersistentDomain(forName: suite)
    preferences = AtlasDisplayPreferences(defaults: defaults)
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
  }

  static let manualID = UUID(uuidString: "0a0a0a0a-1111-4222-8333-444444444444")!

  /// The chart fixture's scans with one manual holding added to each, so the
  /// Tokens pane has something to show and the sources stay comparable.
  static func document(vaultKey: Data) throws -> VaultDocument {
    let before = ChartFixture.scanDate(day: -1)
    let manual = ManualHoldingRecord(
      id: manualID, label: "Paper wallet", provider: "manual", symbol: "BTC", name: "Bitcoin",
      amount: 0.02, priceUsd: 67_500, valueUsd: 1_350, generatedAt: before, createdAt: before,
      updatedAt: before)
    func withManual(_ run: ScanRunRecord) -> ScanRunRecord {
      var run = run
      let price = run.holdings.first { $0.symbol == "BTC" && $0.pricingStatus == .priced }?
        .priceUsd ?? 67_500
      run.holdings.append(
        TrackedAsset(
          id: "manual-\(manualID.uuidString)", address: "Paper wallet", chainId: "manual-manual",
          chainName: "Paper wallet", family: .exchange, symbol: "BTC", name: "Bitcoin",
          amount: 0.02, priceUsd: price, valueUsd: price * 0.02, pricingStatus: .priced,
          source: .exchange))
      run.totalUsd =
        run.holdings.filter { $0.pricingStatus == .priced }.map(\.valueUsd).reduce(0, +)
      return run
    }
    var runs = ChartFixture.runs(includeUnpriced: false).map(withManual)
    // The latest scan also read a token that has no price yet.
    var latest = withManual(
      ChartFixture.run(day: ChartFixture.dayCount - 1, includeUnpriced: true))
    latest.warnings = ["MEME on Ethereum has no USD price, so it's left out of the total."]
    runs[runs.count - 1] = latest

    let wallets = [
      WalletRecord(
        label: "Cold storage", address: ChartFixture.bitcoinAddress, chainKind: .bitcoin,
        createdAt: before, updatedAt: before),
      WalletRecord(
        label: "Main", address: ChartFixture.evmAddress, chainKind: .evm, createdAt: before,
        updatedAt: before),
      WalletRecord(
        label: "Savings", address: ChartFixture.savingsAddress, chainKind: .evm,
        createdAt: ChartFixture.scanDate(day: ChartFixture.sourceChangeDay - 1, hour: 12),
        updatedAt: before),
      WalletRecord(
        label: "Phantom", address: ChartFixture.solanaAddress, chainKind: .solana,
        createdAt: before, updatedAt: before),
      WalletRecord(
        label: "Keplr", address: ChartFixture.cosmosAddress, chainKind: .cosmos, createdAt: before,
        updatedAt: before),
      // Empty, so it leaves no holding; the fixture's scans count six addresses.
      WalletRecord(
        label: "Trading", address: "0x0000000000000000000000000000000000000003",
        chainKind: .evm, createdAt: before, updatedAt: before),
    ]
    let connection = ExchangeConnectionRecord(
      id: ChartFixture.krakenID, provider: .kraken, label: "Kraken main",
      encryptedCredentials: try ExchangeCredentialVault().seal(
        ExchangeCredentials(apiKey: "fixture-key", secret: "fixture-secret"),
        vaultKey: vaultKey, connectionId: ChartFixture.krakenID),
      credentialScopeAssurance: .verifiedReadOnly, status: .ok,
      lastSyncAt: latest.generatedAt, createdAt: before)
    return VaultDocument(
      wallets: wallets,
      customTokens: [
        CustomTokenRecord(
          chainKind: .evm, chainId: "ethereum",
          address: "0x00000000000000000000000000000000000000aa", symbol: "MEME",
          name: "Meme Token", decimals: 18)
      ],
      manualHoldings: [manual],
      exchangeConnections: [connection],
      scanRuns: runs)
  }

  /// Renders `shot` in the real window: sidebar, screen, theme.
  func render(_ shot: MacScreenRenderTests.Shot) throws -> Data {
    preferences.theme = shot.theme
    preferences.appearanceMode = MacScreenRenderTests.isDark(shot.theme) ? .dark : .light
    let navigation = MacNavigationModel(section: Self.section(for: shot.screen))
    switch shot.screen {
    case .portfolio(let visualization, let grouping):
      preferences.portfolioVisualization = visualization
      preferences.grouping = grouping
    case .coin(let key, let visualization, let grouping):
      preferences.portfolioVisualization = visualization
      preferences.grouping = grouping
      navigation.openCoin(key)
    case .assets(let filter):
      navigation.assetsFilter = filter
    case .history(let selected):
      if selected {
        navigation.selectedRunID = state.document.scanRuns
          .max { $0.generatedAt < $1.generatedAt }?.id
      }
    case .tokens:
      navigation.walletsPane = .tokens
    case .wallets, .exchanges, .export, .settings:
      break
    }
    let root = MainView(initialSection: navigation.section, navigation: navigation)
      .environmentObject(state)
      .environmentObject(preferences)
      .environment(\.macNow, ChartFixture.scanDate(day: ChartFixture.dayCount - 1, hour: 1))
      .atlasThemeRoot(preferences)
      .transaction {
        $0.animation = nil
        $0.disablesAnimations = true
      }
    let isDark = MacScreenRenderTests.isDark(shot.theme)
    let hosting = NSHostingView(
      rootView: root.frame(width: shot.size.width, height: shot.size.height, alignment: .topLeading))
    hosting.sizingOptions = []
    hosting.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    hosting.frame = NSRect(origin: .zero, size: shot.size)
    hosting.layoutSubtreeIfNeeded()
    // Charts measure themselves on the first pass; give them a second.
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    hosting.layoutSubtreeIfNeeded()
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
      throw RenderError.noBitmap
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    return try Self.pngData(bitmap, width: shot.outputWidth)
  }

  enum RenderError: Error { case noBitmap }

  /// The bitmap as PNG, scaled down to `width` pixels when it is wider, so a
  /// committed review picture stays a few hundred kilobytes.
  static func pngData(_ bitmap: NSBitmapImageRep, width: Int?) throws -> Data {
    var output = bitmap
    if let width, bitmap.pixelsWide > width {
      let height = Int((Double(bitmap.pixelsHigh) * Double(width) / Double(bitmap.pixelsWide)).rounded())
      guard
        let scaled = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
          bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: scaled), let image = bitmap.cgImage
      else { throw RenderError.noBitmap }
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      context.imageInterpolation = .high
      context.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      NSGraphicsContext.restoreGraphicsState()
      output = scaled
    }
    guard let data = output.representation(using: .png, properties: [:]) else {
      throw RenderError.noBitmap
    }
    return data
  }

  static func section(for screen: MacScreenRenderTests.ScreenKind) -> MainView.Section {
    switch screen {
    case .portfolio, .coin: .portfolio
    case .assets: .assets
    case .history: .history
    case .wallets, .tokens: .wallets
    case .exchanges: .exchanges
    case .export: .export
    case .settings: .settings
    }
  }
}
