import AddressAtlasCore
import AppKit
import SwiftUI
import XCTest

@testable import AddressAtlasMac

/// Renders the seven part-C1 views in every theme and appearance, at the full
/// and compact sizes, from the synthetic fixture. Every render is checked for
/// real content; screenshots are written only on request:
///
///     ATLAS_WRITE_SCREENSHOTS=1 swift test --filter ChartKitRenderTests
///
/// writes a review set to `docs/design/screenshots/phase2/`, and `=all` writes
/// every combination (to `ATLAS_SCREENSHOT_DIR` when set, so a scratch folder
/// can take the full set).
@MainActor
final class ChartKitRenderTests: XCTestCase {
  struct Variant: Hashable {
    var theme: AtlasThemeID
    var dark: Bool
    var name: String { "\(theme.rawValue)-\(dark ? "dark" : "light")" }
  }

  struct ChartCase {
    var name: String
    var make: (PortfolioChartInput) -> AnyView
    /// The same view started with a slice hovered or picked.
    var makeInteracting: (PortfolioChartInput, ChartKitInteractionState) -> AnyView
  }

  static let fullSize = CGSize(width: 640, height: 400)
  static let compactSize = CGSize(width: 320, height: 200)

  static let charts: [ChartCase] = [
    ChartCase(
      name: "map", make: { AnyView(MapChartView(input: $0)) },
      makeInteracting: { AnyView(MapChartView(input: $0, initialInteraction: $1)) }),
    ChartCase(
      name: "ring", make: { AnyView(RingChartView(input: $0)) },
      makeInteracting: { AnyView(RingChartView(input: $0, initialInteraction: $1)) }),
    ChartCase(
      name: "strip", make: { AnyView(StripChartView(input: $0)) },
      makeInteracting: { AnyView(StripChartView(input: $0, initialInteraction: $1)) }),
    ChartCase(
      name: "grid", make: { AnyView(GridChartView(input: $0)) },
      makeInteracting: { AnyView(GridChartView(input: $0, initialInteraction: $1)) }),
    ChartCase(
      name: "bubbles", make: { AnyView(BubblesChartView(input: $0)) },
      makeInteracting: { AnyView(BubblesChartView(input: $0, initialInteraction: $1)) }),
    ChartCase(
      name: "ringsInRings", make: { AnyView(RingsInRingsChartView(input: $0)) },
      makeInteracting: { AnyView(RingsInRingsChartView(input: $0, initialInteraction: $1)) }),
    ChartCase(
      name: "list", make: { AnyView(ListChartView(input: $0)) },
      makeInteracting: { AnyView(ListChartView(input: $0, initialInteraction: $1)) }),
  ]

  override func setUp() {
    super.setUp()
    // Screenshots and assertions use US English whatever the machine's region
    // is; `AtlasFormatting.locale` honours this override in debug builds.
    setenv("ADDRESS_ATLAS_UI_LOCALE", "en_US", 1)
  }

  override func tearDown() {
    unsetenv("ADDRESS_ATLAS_UI_LOCALE")
    super.tearDown()
  }

  static var variants: [Variant] {
    AtlasThemeID.allCases.flatMap { theme -> [Variant] in
      switch theme.supportedAppearances {
      case .lightAndDark: [Variant(theme: theme, dark: false), Variant(theme: theme, dark: true)]
      case .lightOnly: [Variant(theme: theme, dark: false)]
      case .darkOnly: [Variant(theme: theme, dark: true)]
      }
    }
  }

  /// The files committed under `docs/design/screenshots/phase2/` for review.
  static let reviewSet: Set<String> = [
    "map-chainColors-light-full.png",
    "map-candy-light-full.png",
    "map-pixel-dark-full.png",
    "map-riso-light-compact.png",
    "ring-heatmap-dark-full.png",
    "ring-acid-dark-compact.png",
    "strip-candy-light-full.png",
    "strip-chainColors-dark-compact.png",
    "grid-pixel-light-full.png",
    "bubbles-riso-light-full.png",
    "bubbles-acid-dark-full.png",
    "ringsInRings-chainColors-light-full.png",
    "ringsInRings-candy-light-compact.png",
    "list-heatmap-dark-full.png",
    "list-chainColors-light-compact.png",
    "map-heatmap-dark-full-state.png",
    "hover-map-candy-light-full.png",
    "hover-ringsInRingsPart-chainColors-light-full.png",
    "edge-crowded-map-candy-light-full.png",
  ]

  // MARK: Rendering

  func renderPNG(
    _ view: some View, size: CGSize, variant: Variant, scale: CGFloat = 2
  ) throws -> Data {
    let tokens = AtlasThemeTokens(theme: variant.theme, variant: variant.dark ? .dark : .light)
    let padding: CGFloat = 16
    let root = view
      .environment(\.atlasTheme, tokens)
      .environment(\.colorScheme, variant.dark ? .dark : .light)
      .frame(width: size.width, height: size.height)
      .padding(padding)
      .background(tokens.color(.surface))
      .frame(width: size.width + padding * 2, height: size.height + padding * 2)
    let renderer = ImageRenderer(content: root)
    renderer.scale = scale
    let image = try XCTUnwrap(renderer.nsImage)
    let tiff = try XCTUnwrap(image.tiffRepresentation)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
  }

  private var screenshotMode: String? {
    ProcessInfo.processInfo.environment["ATLAS_WRITE_SCREENSHOTS"]
  }

  private var screenshotDirectory: URL {
    if let override = ProcessInfo.processInfo.environment["ATLAS_SCREENSHOT_DIR"], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    // .../native/AddressAtlasMac/Tests/AddressAtlasMacTests/<this file>
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return root.appendingPathComponent("docs/design/screenshots/phase2", isDirectory: true)
  }

  private func record(_ data: Data, fileName: String) throws {
    guard let mode = screenshotMode, !mode.isEmpty, mode != "0" else { return }
    guard mode == "all" || Self.reviewSet.contains(fileName) else { return }
    let directory = screenshotDirectory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
  }

  // MARK: Tests

  func testEveryViewRendersInEveryThemeAtBothSizes() throws {
    let holdings = ChartKitFixtures.portfolio()
    var checksums: [String: Set<Int>] = [:]
    for chart in Self.charts {
      for variant in Self.variants {
        for (label, size, density) in [
          ("full", Self.fullSize, PortfolioChartDensity.full),
          ("compact", Self.compactSize, .compact),
        ] {
          let input = PortfolioChartInput(holdings: holdings, density: density)
          let data = try renderPNG(chart.make(input), size: size, variant: variant)
          XCTAssertGreaterThan(data.count, 3_000, "\(chart.name) \(variant.name) \(label)")
          checksums["\(chart.name)-\(label)", default: []].insert(data.hashValue)
          try record(data, fileName: "\(chart.name)-\(variant.name)-\(label).png")
        }
      }
    }
    for (key, values) in checksums {
      XCTAssertGreaterThanOrEqual(values.count, 5, "\(key) must look different across themes")
    }
  }

  func testEveryGroupingRendersInEveryView() throws {
    let holdings = ChartKitFixtures.portfolio()
    for chart in Self.charts {
      for grouping in PortfolioGrouping.allCases {
        for density in [PortfolioChartDensity.full, .compact] {
          let input = PortfolioChartInput(holdings: holdings, grouping: grouping, density: density)
          let size = density == .full ? Self.fullSize : Self.compactSize
          let data = try renderPNG(
            chart.make(input), size: size, variant: Variant(theme: .heatmap, dark: true))
          XCTAssertGreaterThan(data.count, 3_000, "\(chart.name) \(grouping) \(density)")
          try record(
            data,
            fileName:
              "\(chart.name)-heatmap-dark-\(density == .full ? "full" : "compact")-\(grouping.rawValue).png"
          )
        }
      }
    }
  }

  /// Inputs that stress a layout: nothing to draw, one slice, forty slices, a
  /// single coin's own screen, names too long for any label.
  func testEdgeCasesRenderEveryViewWithoutBlanksOrCrashes() throws {
    let longName = ChartKitFixtures.wallet(
      "LONG", name: "A token with a very long name indeed", amount: 100, price: 50,
      source: .erc20, family: .evm, chainId: "ethereum", chainName: "Ethereum",
      address: "0x0000000000000000000000000000000000000002",
      label: "Hardware wallet kept in the safe deposit box downtown")
    let single = [ChartKitFixtures.portfolio()[0]]
    let cases: [(name: String, holdings: [TrackedAsset], grouping: PortfolioGrouping, coin: String?)] = [
      ("empty", [], .asset, nil),
      ("unpricedOnly", ChartKitFixtures.portfolio().filter { $0.symbol == "ZKT" }, .asset, nil),
      ("single", single, .asset, nil),
      ("crowded", ChartKitFixtures.crowdedPortfolio(), .asset, nil),
      ("crowdedNetwork", ChartKitFixtures.crowdedPortfolio(), .network, nil),
      ("longNames", ChartKitFixtures.portfolio() + [longName], .source, nil),
      ("ethCoin", ChartKitFixtures.ethOnly(), .network, "ETH"),
      ("ethCoinState", ChartKitFixtures.ethOnly(), .state, "ETH"),
      (
        "atomState", ChartKitFixtures.portfolio().filter { $0.symbol == "ATOM" }, .state, "ATOM"
      ),
    ]
    for edge in cases {
      for chart in Self.charts {
        for (label, size, density) in [
          ("full", Self.fullSize, PortfolioChartDensity.full),
          ("compact", Self.compactSize, .compact),
        ] {
          let input = PortfolioChartInput(
            holdings: edge.holdings, grouping: edge.grouping, coinKey: edge.coin, density: density)
          let data = try renderPNG(
            chart.make(input), size: size, variant: Variant(theme: .candy, dark: false))
          XCTAssertGreaterThan(data.count, 1_500, "\(chart.name) \(edge.name) \(label)")
          try record(data, fileName: "edge-\(edge.name)-\(chart.name)-candy-light-\(label).png")
        }
      }
    }
  }

  /// A hovered slice stands out and the others recede, in every view and theme;
  /// the picture differs from the resting one.
  func testHoveredAndPickedSlicesRenderInEveryView() throws {
    let holdings = ChartKitFixtures.portfolio()
    for chart in Self.charts {
      for variant in [
        Variant(theme: .candy, dark: false), Variant(theme: .heatmap, dark: true),
        Variant(theme: .riso, dark: false),
      ] {
        let input = PortfolioChartInput(holdings: holdings)
        let resting = try renderPNG(chart.make(input), size: Self.fullSize, variant: variant)
        let hovered = try renderPNG(
          chart.makeInteracting(input, ChartKitInteractionState(hoveredID: "ETH")),
          size: Self.fullSize, variant: variant)
        let picked = try renderPNG(
          chart.makeInteracting(input, ChartKitInteractionState(selectedID: "ETH")),
          size: Self.fullSize, variant: variant)
        XCTAssertNotEqual(resting, hovered, "\(chart.name) \(variant.name) hover")
        XCTAssertEqual(hovered, picked, "\(chart.name) \(variant.name) picked looks like hover")
        try record(hovered, fileName: "hover-\(chart.name)-\(variant.name)-full.png")
      }
    }
    // A part of a slice in the two-level views.
    let nested = try renderPNG(
      RingsInRingsChartView(
        input: PortfolioChartInput(holdings: holdings),
        initialInteraction: ChartKitInteractionState(hoveredID: "ATOM>staked")),
      size: Self.fullSize, variant: Variant(theme: .chainColors, dark: false))
    try record(nested, fileName: "hover-ringsInRingsPart-chainColors-light-full.png")
  }

  func testIncreaseContrastRendersEveryView() throws {
    let holdings = ChartKitFixtures.portfolio()
    for chart in Self.charts {
      let input = PortfolioChartInput(holdings: holdings)
      let tokens = AtlasThemeTokens(theme: .chainColors, variant: .highContrastLight)
      let view = chart.make(input)
        .environment(\.atlasTheme, tokens)
        .frame(width: 640, height: 400)
        .background(tokens.color(.surface))
      let renderer = ImageRenderer(content: view)
      renderer.scale = 2
      XCTAssertNotNil(renderer.nsImage, chart.name)
    }
  }
}
