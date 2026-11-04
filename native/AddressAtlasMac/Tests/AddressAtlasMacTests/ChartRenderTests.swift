import AddressAtlasCore
import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import AddressAtlasMac

/// Renders every history chart and coin widget from the synthetic fixture
/// (`ChartFixture`) with `ImageRenderer`, in every theme and appearance, at the
/// full (640 x 400) and compact (320 x 200) sizes.
///
/// A default run renders a small matrix and checks that each picture has
/// content. With `ATLAS_WRITE_SCREENSHOTS=1` it renders the whole matrix and
/// writes PNGs into `docs/design/screenshots/phase2/` (or the folder named by
/// `ATLAS_SCREENSHOT_DIR`). `ATLAS_SCREENSHOT_VIEWS=flow,slope` limits which
/// views are written.
@MainActor
final class ChartRenderTests: XCTestCase {
  struct Entry {
    let name: String
    /// Coin widgets render one coin of the fixture.
    let coinKey: String?
    let make: (PortfolioChartInput, Date) -> AnyView
  }

  static let now = ChartFixture.scanDate(day: ChartFixture.dayCount - 1, hour: 1)

  static let entries: [Entry] = [
    Entry(name: "flow", coinKey: nil) { input, _ in AnyView(FlowChartView(input: input)) },
    Entry(name: "over-time", coinKey: nil) { input, _ in AnyView(OverTimeChartView(input: input)) },
    Entry(name: "what-changed", coinKey: nil) { input, _ in AnyView(WhatChangedChartView(input: input)) },
    Entry(name: "atlas-map", coinKey: nil) { input, _ in AnyView(AtlasMapChartView(input: input)) },
    Entry(name: "slope", coinKey: nil) { input, _ in AnyView(SlopeChartView(input: input)) },
    Entry(name: "concentration", coinKey: nil) { input, _ in AnyView(ConcentrationChartView(input: input)) },
    Entry(name: "calendar", coinKey: nil) { input, _ in AnyView(CalendarChartView(input: input)) },
    Entry(name: "coin-state-strip", coinKey: "ATOM") { input, _ in
      AnyView(CoinStateStripView(input: input))
    },
    Entry(name: "coin-unlock-timeline", coinKey: "ATOM") { input, now in
      AnyView(CoinUnlockTimelineView(input: input, now: now))
    },
    Entry(name: "coin-amount-history", coinKey: "ATOM") { input, _ in
      AnyView(CoinAmountHistoryView(input: input))
    },
    Entry(name: "coin-change", coinKey: "ETH") { input, _ in AnyView(CoinChangeView(input: input)) },
    Entry(name: "coin-custody", coinKey: "BTC") { input, _ in AnyView(CoinCustodyView(input: input)) },
  ]

  // MARK: Matrix

  struct Look: Hashable {
    let theme: AtlasThemeID
    let variant: AtlasAppearanceVariant

    var appearanceName: String { variant.isDark ? "dark" : "light" }
    var colorScheme: ColorScheme { variant.isDark ? .dark : .light }
  }

  static var allLooks: [Look] {
    AtlasThemeID.allCases.flatMap { theme -> [Look] in
      switch theme.supportedAppearances {
      case .lightOnly: [Look(theme: theme, variant: .light)]
      case .darkOnly: [Look(theme: theme, variant: .dark)]
      case .lightAndDark:
        [Look(theme: theme, variant: .light), Look(theme: theme, variant: .dark)]
      }
    }
  }

  /// Two contrasting looks for the default (non-screenshot) run.
  static var smokeLooks: [Look] {
    [
      Look(theme: .chainColors, variant: .light),
      Look(theme: .acid, variant: .dark),
    ]
  }

  static let fullSize = CGSize(width: 640, height: 400)
  static let compactSize = CGSize(width: 320, height: 200)

  private var writesScreenshots: Bool {
    ProcessInfo.processInfo.environment["ATLAS_WRITE_SCREENSHOTS"] == "1"
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

  private var selectedViews: Set<String>? {
    guard let raw = ProcessInfo.processInfo.environment["ATLAS_SCREENSHOT_VIEWS"], !raw.isEmpty else {
      return nil
    }
    return Set(raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
  }

  override func setUp() {
    super.setUp()
    // Money and dates read the same on every machine.
    setenv("ADDRESS_ATLAS_UI_LOCALE", "en_US", 1)
  }

  // MARK: Tests

  func testEveryViewRendersContentInSmokeLooks() throws {
    for entry in Self.entries {
      for look in Self.smokeLooks {
        for density in [PortfolioChartDensity.full, .compact] {
          let image = try render(entry, look: look, density: density)
          XCTAssertGreaterThan(
            Self.distinctColors(in: image), 3,
            "\(entry.name) \(look.theme.rawValue) \(density) looks blank")
        }
      }
    }
  }

  /// Renders the whole matrix; writes PNGs only when asked to.
  func testWriteScreenshotsWhenRequested() throws {
    guard writesScreenshots else {
      throw XCTSkip("Set ATLAS_WRITE_SCREENSHOTS=1 to render every theme and write PNGs.")
    }
    let directory = screenshotDirectory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for entry in Self.entries where selectedViews.map({ $0.contains(entry.name) }) ?? true {
      for look in Self.allLooks {
        for density in [PortfolioChartDensity.full, .compact] {
          let image = try render(entry, look: look, density: density)
          let name =
            "\(entry.name)-\(look.theme.rawValue)-\(look.appearanceName)-\(density == .full ? "full" : "compact").png"
          let data = try Self.pngData(image)
          try data.write(to: directory.appendingPathComponent(name))
        }
      }
    }
  }

  // MARK: Rendering

  enum RenderError: Error { case noImage }

  func render(
    _ entry: Entry, look: Look, density: PortfolioChartDensity,
    input customInput: PortfolioChartInput? = nil
  ) throws -> CGImage {
    let tokens = AtlasThemeTokens(theme: look.theme, variant: look.variant)
    let size = density == .full ? Self.fullSize : Self.compactSize
    let input =
      customInput
      ?? ChartFixture.input(coinKey: entry.coinKey, density: density)
    return try Self.renderImage(
      entry.make(input, Self.now), tokens: tokens, colorScheme: look.colorScheme, size: size)
  }

  /// A view inside a card on the theme's canvas, as a screen would show it.
  static func renderImage(
    _ view: AnyView, tokens: AtlasThemeTokens, colorScheme: ColorScheme, size: CGSize
  ) throws -> CGImage {
    let padding: CGFloat = size.width > 400 ? 16 : 10
    let card = RoundedRectangle(cornerRadius: tokens.shape.radiusCard, style: .continuous)
    let content =
      view
      .frame(width: size.width, height: size.height)
      .padding(padding)
      .background(tokens.color(.surface))
      .clipShape(card)
      .overlay(
        card.stroke(tokens.color(.outline), lineWidth: max(1, tokens.shape.cardBorderWidth))
      )
      .padding(12)
      .background(tokens.color(.canvas))
      .environment(\.atlasTheme, tokens)
      .environment(\.colorScheme, colorScheme)
      .environment(\.dynamicTypeSize, .large)
      .font(tokens.font(.body, .body))
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let image = renderer.cgImage else { throw RenderError.noImage }
    return image
  }

  static func pngData(_ image: CGImage) throws -> Data {
    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      throw RenderError.noImage
    }
    return data
  }

  /// Number of distinct colours among a sparse grid of pixels.
  static func distinctColors(in image: CGImage) -> Int {
    let representation = NSBitmapImageRep(cgImage: image)
    var seen = Set<UInt32>()
    let stepX = max(1, representation.pixelsWide / 60)
    let stepY = max(1, representation.pixelsHigh / 40)
    for x in stride(from: 0, to: representation.pixelsWide, by: stepX) {
      for y in stride(from: 0, to: representation.pixelsHigh, by: stepY) {
        guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
          continue
        }
        let r = UInt32(color.redComponent * 255)
        let g = UInt32(color.greenComponent * 255)
        let b = UInt32(color.blueComponent * 255)
        seen.insert(r << 16 | g << 8 | b)
      }
    }
    return seen.count
  }
}
