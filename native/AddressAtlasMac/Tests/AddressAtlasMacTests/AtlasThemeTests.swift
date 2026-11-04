import AppKit
import CoreText
import Foundation
import Observation
import SwiftUI
import XCTest

@testable import AddressAtlasMac

final class AtlasThemeTests: XCTestCase {
  private var savedSelection: (AtlasThemeID, AtlasAppearanceMode)?

  override func setUp() {
    super.setUp()
    savedSelection = (AtlasThemeRuntime.shared.theme, AtlasThemeRuntime.shared.appearanceMode)
  }

  override func tearDown() {
    if let savedSelection {
      AtlasThemeRuntime.shared.apply(theme: savedSelection.0, appearanceMode: savedSelection.1)
    }
    super.tearDown()
  }

  // MARK: Identity

  func testSixThemesHaveStablePersistedRawValues() {
    XCTAssertEqual(
      AtlasThemeID.allCases.map(\.rawValue),
      ["chainColors", "candy", "riso", "heatmap", "pixel", "acid"]
    )
    XCTAssertEqual(AtlasThemeID.default, .chainColors)
    XCTAssertEqual(AtlasThemeID.allCases.map(\.title).count, Set(AtlasThemeID.allCases.map(\.title)).count)
  }

  func testRisoIsLightOnlyAndAcidIsDarkOnlyOthersHaveBoth() {
    XCTAssertEqual(AtlasThemeID.riso.supportedAppearances, .lightOnly)
    XCTAssertEqual(AtlasThemeID.acid.supportedAppearances, .darkOnly)
    for theme in [AtlasThemeID.chainColors, .candy, .heatmap, .pixel] {
      XCTAssertEqual(theme.supportedAppearances, .lightAndDark)
    }
    for mode in AtlasAppearanceMode.allCases {
      XCTAssertEqual(AtlasThemeID.riso.forcedColorScheme(for: mode), .light)
      XCTAssertEqual(AtlasThemeID.acid.forcedColorScheme(for: mode), .dark)
    }
    XCTAssertNil(AtlasThemeID.candy.forcedColorScheme(for: .system))
    XCTAssertEqual(AtlasThemeID.candy.forcedColorScheme(for: .dark), .dark)
    XCTAssertEqual(AtlasThemeID.heatmap.forcedColorScheme(for: .light), .light)
  }

  func testSingleModeThemesResolveEveryAppearanceToTheirOnlyFamily() {
    for variant in [AtlasAppearanceVariant.light, .dark] {
      XCTAssertEqual(
        AtlasTheme.palette(for: .riso, appearance: variant).canvas,
        AtlasTheme.palette(for: .riso, appearance: .light).canvas
      )
      XCTAssertEqual(
        AtlasTheme.palette(for: .acid, appearance: variant).canvas,
        AtlasTheme.palette(for: .acid, appearance: .dark).canvas
      )
    }
    XCTAssertLessThan(AtlasTheme.palette(for: .acid, appearance: .light).canvas.relativeLuminance, 0.02)
    XCTAssertGreaterThan(AtlasTheme.palette(for: .riso, appearance: .dark).canvas.relativeLuminance, 0.5)
  }

  func testThemesWithBothAppearancesHaveDistinctLightAndDarkCanvases() {
    for theme in [AtlasThemeID.chainColors, .candy, .heatmap, .pixel] {
      let light = AtlasTheme.palette(for: theme, appearance: .light).canvas
      let dark = AtlasTheme.palette(for: theme, appearance: .dark).canvas
      XCTAssertGreaterThan(light.relativeLuminance, 0.5, "\(theme) light canvas")
      XCTAssertLessThan(dark.relativeLuminance, 0.05, "\(theme) dark canvas")
    }
  }

  func testIncreaseContrastUsesFullStrengthInkAndRules() {
    for theme in AtlasThemeID.allCases {
      for variant in [AtlasAppearanceVariant.highContrastLight, .highContrastDark] {
        let palette = AtlasTheme.palette(for: theme, appearance: variant)
        let usesDark: Bool
        switch theme.supportedAppearances {
        case .lightOnly: usesDark = false
        case .darkOnly: usesDark = true
        case .lightAndDark: usesDark = variant.isDark
        }
        let expected: AtlasRGB = usesDark ? .white : .black
        XCTAssertEqual(palette.ink, expected, "\(theme) \(variant)")
        XCTAssertEqual(palette.controlBoundary, expected, "\(theme) \(variant)")
        XCTAssertGreaterThanOrEqual(palette.rule.contrast(with: palette.canvas), 4.5)
      }
    }
  }

  // MARK: Theme brand fidelity

  func testThemesUseTheirSpecifiedSignatureColours() {
    XCTAssertEqual(AtlasTheme.palette(for: .candy, appearance: .light).canvas, 0xFFF7EA)
    XCTAssertEqual(AtlasTheme.palette(for: .candy, appearance: .light).selection, 0xC6F432)
    XCTAssertEqual(AtlasTheme.palette(for: .heatmap, appearance: .dark).canvas, 0x0D0E12)
    XCTAssertEqual(AtlasTheme.palette(for: .acid, appearance: .dark).canvas, 0x0A0B0A)
    XCTAssertEqual(AtlasTheme.palette(for: .acid, appearance: .dark).accent, 0xC8FF4D)
    XCTAssertEqual(AtlasTheme.palette(for: .riso, appearance: .light).selection, 0xFF4FA3)
    XCTAssertEqual(AtlasTheme.palette(for: .pixel, appearance: .light).canvas, 0xFDFCF6)
    let chain = AtlasThemeTokens(theme: .chainColors, variant: .light).chart
    XCTAssertEqual(chain.asset("BTC"), 0xF7931A)
    XCTAssertEqual(chain.asset("ETH"), 0x627EEA)
    XCTAssertEqual(chain.asset("SOL"), 0x9945FF)
    XCTAssertEqual(chain.asset("ATOM"), 0x2E3148)
    XCTAssertEqual(chain.asset("USDC"), 0x2775CA)
    XCTAssertEqual(chain.network("Base"), 0x0052FF)
    let heatmap = AtlasThemeTokens(theme: .heatmap, variant: .dark).chart
    XCTAssertEqual(heatmap.asset("BTC"), 0xFFAB4A)
    XCTAssertEqual(heatmap.asset("ETH"), 0x8FA2FF)
    XCTAssertEqual(heatmap.asset("SOL"), 0xC49BFF)
    XCTAssertEqual(heatmap.asset("ATOM"), 0x7EE0B5)
    XCTAssertEqual(heatmap.asset("USDC"), 0x7CC4FF)
  }

  func testShapeTokensMatchEachThemesCharacter() {
    let candy = AtlasThemeCatalog.definition(for: .candy).shape
    XCTAssertEqual(candy.cardBorderWidth, 2.5)
    XCTAssertEqual(candy.cardShadowOffset, CGSize(width: 5, height: 5))
    XCTAssertFalse(candy.usesSoftShadow)
    let pixel = AtlasThemeCatalog.definition(for: .pixel).shape
    XCTAssertEqual(pixel.cardBorderWidth, 3)
    XCTAssertEqual(pixel.radiusCard, 0)
    XCTAssertNotNil(pixel.cardShadowOffset)
    let chain = AtlasThemeCatalog.definition(for: .chainColors).shape
    XCTAssertTrue(chain.usesSoftShadow)
    XCTAssertNil(chain.cardShadowOffset)
    XCTAssertGreaterThanOrEqual(chain.radiusCard, 20)
    for theme in [AtlasThemeID.chainColors, .riso, .heatmap, .acid] {
      XCTAssertNil(AtlasThemeCatalog.definition(for: theme).shape.cardShadowOffset, "\(theme)")
    }
  }

  func testEachThemeMapsRolesToItsFonts() {
    func families(_ theme: AtlasThemeID) -> [AtlasFontFamily] {
      let typography = AtlasThemeCatalog.definition(for: theme).typography
      return AtlasFontRole.allCases.map { typography[$0].family }
    }
    XCTAssertEqual(AtlasThemeCatalog.definition(for: .chainColors).typography.display.family, .plusJakartaSans)
    XCTAssertEqual(AtlasThemeCatalog.definition(for: .candy).typography.display.family, .bricolageGrotesque)
    XCTAssertEqual(AtlasThemeCatalog.definition(for: .riso).typography.display.family, .spaceGrotesk)
    XCTAssertEqual(AtlasThemeCatalog.definition(for: .riso).typography.label.family, .spaceMono)
    XCTAssertEqual(AtlasThemeCatalog.definition(for: .heatmap).typography.display.family, .geist)
    XCTAssertEqual(AtlasThemeCatalog.definition(for: .pixel).typography.display.family, .pixelifySans)
    // Pixelify Sans draws "5" like "S", so Pixel figures use VT323.
    XCTAssertEqual(AtlasThemeCatalog.definition(for: .pixel).typography.number.family, .vt323)
    XCTAssertEqual(AtlasThemeCatalog.definition(for: .pixel).typography.label.family, .silkscreen)
    // Pixel type is for numbers and labels; long text uses a clean body face.
    XCTAssertEqual(AtlasThemeCatalog.definition(for: .pixel).typography.body.family, .geist)
    XCTAssertEqual(AtlasThemeCatalog.definition(for: .acid).typography.display.family, .geistMono)
    XCTAssertEqual(AtlasThemeCatalog.definition(for: .acid).typography.body.family, .geist)
    for theme in AtlasThemeID.allCases {
      XCTAssertEqual(families(theme).count, AtlasFontRole.allCases.count)
    }
  }

  // MARK: Fonts

  func testEveryBundledFontFamilyRegistersAndResolves() throws {
    let report = AtlasFonts.registerAll()

    XCTAssertEqual(report.missingFamilies, [], "Missing font families")
    XCTAssertNotNil(report.fontDirectory)
    for family in AtlasFontFamily.allCases {
      XCTAssertTrue(AtlasFonts.isAvailable(family), family.familyName)
      let font = CTFontCreateWithName(family.familyName as CFString, 16, nil)
      XCTAssertEqual(
        CTFontCopyFamilyName(font) as String,
        family.familyName,
        "CoreText must resolve \(family.familyName), not substitute a system font"
      )
    }
  }

  func testRegistrationIsIdempotent() {
    let first = AtlasFonts.registerAll()
    let second = AtlasFonts.registerAll()
    XCTAssertEqual(first, second)
  }

  func testEveryFontFamilyShipsItsFilesAndOFLLicence() throws {
    let report = AtlasFonts.registerAll()
    let directory = try XCTUnwrap(report.fontDirectory)
    for family in AtlasFontFamily.allCases {
      let familyDirectory = directory.appendingPathComponent(family.directoryName, isDirectory: true)
      for file in family.fileNames {
        XCTAssertTrue(
          FileManager.default.fileExists(atPath: familyDirectory.appendingPathComponent(file).path),
          "\(family.directoryName)/\(file)"
        )
      }
      let licence = familyDirectory.appendingPathComponent("OFL.txt")
      let text = try String(contentsOf: licence, encoding: .utf8)
      XCTAssertTrue(
        text.contains("SIL OPEN FONT LICENSE"),
        "\(family.directoryName) must ship its OFL licence"
      )
    }
  }

  func testThemedFontsUseTheThemeFamilyNotTheSystemFont() throws {
    _ = AtlasFonts.registerAll()
    for theme in AtlasThemeID.allCases {
      let typography = AtlasThemeCatalog.definition(for: theme).typography
      for role in AtlasFontRole.allCases {
        let family = typography[role].family
        let ctFont = CTFontCreateWithName(family.familyName as CFString, 14, nil)
        XCTAssertEqual(CTFontCopyFamilyName(ctFont) as String, family.familyName, "\(theme) \(role)")
      }
    }
  }

  // MARK: Switching

  @MainActor
  func testChangingThemeChangesResolvedStaticColours() throws {
    let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
    var seen: [AtlasThemeID: AtlasRGB] = [:]
    for theme in AtlasThemeID.allCases {
      AtlasThemeRuntime.shared.apply(theme: theme, appearanceMode: .system)
      XCTAssertEqual(AtlasTheme.current, theme)
      var resolved: NSColor?
      appearance.performAsCurrentDrawingAppearance {
        resolved = NSColor(AtlasTheme.canvas).usingColorSpace(.sRGB)
      }
      let color = try XCTUnwrap(resolved)
      let rgb = AtlasRGB(
        red: Double(color.redComponent), green: Double(color.greenComponent),
        blue: Double(color.blueComponent))
      let expected = AtlasTheme.palette(for: theme, appearance: .light).canvas
      XCTAssertEqual(rgb.red, expected.red, accuracy: 0.002, "\(theme)")
      XCTAssertEqual(rgb.green, expected.green, accuracy: 0.002, "\(theme)")
      XCTAssertEqual(rgb.blue, expected.blue, accuracy: 0.002, "\(theme)")
      seen[theme] = expected
    }
    XCTAssertGreaterThan(Set(seen.values).count, 4, "Themes must not share one canvas")
  }

  @MainActor
  func testRadiiAndShapeFollowTheSelectedTheme() {
    AtlasThemeRuntime.shared.apply(theme: .pixel, appearanceMode: .system)
    XCTAssertEqual(AtlasRadius.card, 0)
    XCTAssertEqual(AtlasTheme.shape.cardBorderWidth, 3)
    AtlasThemeRuntime.shared.apply(theme: .chainColors, appearanceMode: .system)
    XCTAssertEqual(AtlasRadius.card, 20)
    XCTAssertEqual(AtlasTheme.shape.cardBorderWidth, 1)
  }

  func testReadingATokenSubscribesObserversToThemeChanges() {
    AtlasThemeRuntime.shared.apply(theme: .chainColors, appearanceMode: .system)
    let fired = expectation(description: "theme change observed")
    withObservationTracking {
      _ = AtlasTheme.ink
    } onChange: {
      fired.fulfill()
    }
    AtlasThemeRuntime.shared.apply(theme: .candy, appearanceMode: .system)
    wait(for: [fired], timeout: 2)
  }

  func testApplyingTheSameThemeDoesNotNotifyObservers() {
    AtlasThemeRuntime.shared.apply(theme: .heatmap, appearanceMode: .dark)
    let notReached = expectation(description: "no change")
    notReached.isInverted = true
    withObservationTracking {
      _ = AtlasTheme.shape
      _ = AtlasThemeRuntime.shared.appearanceMode
    } onChange: {
      notReached.fulfill()
    }
    AtlasThemeRuntime.shared.apply(theme: .heatmap, appearanceMode: .dark)
    wait(for: [notReached], timeout: 0.3)
  }

  // MARK: Preferences

  @MainActor
  func testPreferencesDefaultsAndPersistence() throws {
    let suite = "AtlasThemeTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let preferences = AtlasDisplayPreferences(defaults: defaults)
    XCTAssertEqual(preferences.theme, .chainColors)
    XCTAssertEqual(preferences.appearanceMode, .system)
    XCTAssertEqual(preferences.portfolioVisualization, .map)
    XCTAssertEqual(preferences.portfolioGrouping, "asset")
    XCTAssertNil(preferences.forcedColorScheme)

    preferences.theme = .candy
    preferences.appearanceMode = .dark
    preferences.portfolioVisualization = .ringsInRings
    preferences.portfolioGrouping = "state"
    XCTAssertEqual(AtlasTheme.current, .candy)
    XCTAssertEqual(AtlasThemeRuntime.shared.appearanceMode, .dark)
    XCTAssertEqual(preferences.forcedColorScheme, .dark)

    XCTAssertEqual(defaults.string(forKey: AtlasDisplayPreferences.Key.theme), "candy")
    XCTAssertEqual(defaults.string(forKey: AtlasDisplayPreferences.Key.appearanceMode), "dark")
    XCTAssertEqual(
      defaults.string(forKey: AtlasDisplayPreferences.Key.portfolioVisualization),
      "ringsInRings"
    )
    XCTAssertEqual(defaults.string(forKey: AtlasDisplayPreferences.Key.portfolioGrouping), "state")

    let reloaded = AtlasDisplayPreferences(defaults: defaults)
    XCTAssertEqual(reloaded.theme, .candy)
    XCTAssertEqual(reloaded.appearanceMode, .dark)
    XCTAssertEqual(reloaded.portfolioVisualization, .ringsInRings)
    XCTAssertEqual(reloaded.portfolioGrouping, "state")
    XCTAssertEqual(AtlasTheme.current, .candy, "A new store applies the saved theme at once")
  }

  @MainActor
  func testPreferencesRejectInvalidStoredValues() throws {
    let suite = "AtlasThemeTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("neon", forKey: AtlasDisplayPreferences.Key.theme)
    defaults.set("sepia", forKey: AtlasDisplayPreferences.Key.appearanceMode)
    defaults.set("pie", forKey: AtlasDisplayPreferences.Key.portfolioVisualization)
    defaults.set("colour", forKey: AtlasDisplayPreferences.Key.portfolioGrouping)

    let preferences = AtlasDisplayPreferences(defaults: defaults)

    XCTAssertEqual(preferences.theme, .chainColors)
    XCTAssertEqual(preferences.appearanceMode, .system)
    XCTAssertEqual(preferences.portfolioVisualization, .map)
    XCTAssertEqual(preferences.portfolioGrouping, "asset")
    preferences.portfolioGrouping = "nonsense"
    XCTAssertEqual(preferences.portfolioGrouping, "asset")
    // Whatever is persisted is always one of the accepted grouping keys.
    XCTAssertTrue(
      AtlasDisplayPreferences.groupingValues.contains(
        defaults.string(forKey: AtlasDisplayPreferences.Key.portfolioGrouping) ?? ""
      )
    )
  }

  @MainActor
  func testPreferencesAreStoredOutsideTheVaultAndSingleModeThemesForceTheirScheme() throws {
    let suite = "AtlasThemeTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AtlasDisplayPreferences(defaults: defaults)
    preferences.appearanceMode = .dark
    preferences.theme = .riso
    XCTAssertEqual(preferences.forcedColorScheme, .light)
    preferences.theme = .acid
    preferences.appearanceMode = .light
    XCTAssertEqual(preferences.forcedColorScheme, .dark)
    // Display preferences are plain UserDefaults values, never vault content.
    XCTAssertEqual(defaults.string(forKey: AtlasDisplayPreferences.Key.theme), "acid")
  }

  func testPortfolioVisualizationListsEveryPlannedView() {
    XCTAssertEqual(
      PortfolioVisualization.allCases.map(\.rawValue),
      [
        "map", "ring", "strip", "grid", "bubbles", "ringsInRings", "flow", "list", "overTime",
        "whatChanged", "atlasMap", "slope", "concentration", "calendar",
      ]
    )
    XCTAssertEqual(
      AtlasDisplayPreferences.groupingValues,
      ["asset", "network", "source", "state", "kind"]
    )
  }

  // MARK: Chart colours

  func testUnknownSymbolsGetAStableColourFromTheCategoricalSet() {
    for theme in AtlasThemeID.allCases {
      let chart = AtlasThemeTokens(theme: theme, variant: .light).chart
      XCTAssertGreaterThanOrEqual(chart.categorical.count, 8, "\(theme)")
      for symbol in ["NEWCOIN", "zzz", "Q", "PEPE2", "x9"] {
        let first = chart.asset(symbol)
        XCTAssertEqual(first, chart.asset(symbol))
        XCTAssertEqual(first, chart.asset(" \(symbol.uppercased()) "))
        XCTAssertTrue(chart.categorical.contains(first), "\(theme) \(symbol)")
      }
    }
  }

  func testUnknownSymbolColoursSpreadAcrossTheCategoricalSet() {
    let chart = AtlasThemeTokens(theme: .heatmap, variant: .dark).chart
    let symbols = (0..<60).map { "TOKEN\($0)" }
    let used = Set(symbols.map { chart.asset($0) })
    XCTAssertGreaterThanOrEqual(used.count, 6)
  }

  func testWrappedAssetsShareTheirBaseColourAndNetworksNormalise() {
    let chart = AtlasThemeTokens(theme: .chainColors, variant: .light).chart
    XCTAssertEqual(chart.asset("WETH"), chart.asset("ETH"))
    XCTAssertEqual(chart.asset("wbtc"), chart.asset("BTC"))
    XCTAssertEqual(chart.network("Cosmos Hub"), chart.network("cosmoshub"))
    XCTAssertEqual(chart.network("cosmoshub"), chart.asset("ATOM"))
    XCTAssertEqual(chart.network("ethereum"), 0x627EEA)
  }

  func testCategoricalColoursAreDistinctInEveryTheme() {
    for theme in AtlasThemeID.allCases {
      let colours = AtlasThemeTokens(theme: theme, variant: .light).chart.categorical
      XCTAssertEqual(Set(colours).count, colours.count, "\(theme) repeats a series colour")
    }
  }

  func testHoldingStateAndKindColoursExistAndDifferInEveryTheme() {
    for theme in AtlasThemeID.allCases {
      let chart = AtlasThemeTokens(theme: theme, variant: .light).chart
      let states = AtlasHoldingState.allCases.map { chart.state($0) }
      XCTAssertEqual(Set(states).count, AtlasHoldingState.allCases.count, "\(theme) states")
      let kinds = AtlasAssetKind.allCases.map { chart.kind($0) }
      XCTAssertEqual(Set(kinds).count, AtlasAssetKind.allCases.count, "\(theme) kinds")
    }
  }

  func testChainColoursMarksStayVisibleOnTheDarkCanvas() {
    let dark = AtlasThemeTokens(theme: .chainColors, variant: .dark)
    for symbol in ["ATOM", "XRP", "ADA", "OSMO"] {
      XCTAssertGreaterThanOrEqual(
        dark.chart.asset(symbol).contrast(with: dark.palette.canvas),
        3,
        "\(symbol) mark on the dark canvas"
      )
    }
  }

  func testReadableInkChoosesTheStrongerOfBlackAndWhite() {
    let orange: AtlasRGB = 0xFFAB4A
    let navy: AtlasRGB = 0x2E3148
    XCTAssertEqual(orange.readableInk, .black)
    XCTAssertEqual(navy.readableInk, .white)
    let tokens = AtlasThemeTokens(theme: .heatmap, variant: .dark)
    for symbol in ["BTC", "ETH", "SOL", "ATOM", "USDC"] {
      let block = tokens.chart.asset(symbol)
      XCTAssertGreaterThanOrEqual(block.contrast(with: block.readableInk), 7, symbol)
    }
  }

  // MARK: Environment and layout

  @MainActor
  func testThemePickerAndSettingsLayOutAtMinimumWidthInEveryTheme() throws {
    let suite = "AtlasThemeTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AtlasDisplayPreferences(defaults: defaults)
    for theme in AtlasThemeID.allCases {
      preferences.theme = theme
      let host = NSHostingView(
        rootView: AtlasThemeSection()
          .padding(20)
          .environmentObject(preferences)
          .atlasThemeRoot(preferences)
      )
      host.frame = NSRect(x: 0, y: 0, width: 900 - 238, height: 600)
      host.layoutSubtreeIfNeeded()
      XCTAssertGreaterThan(host.fittingSize.height, 150, "\(theme)")
      XCTAssertLessThanOrEqual(host.fittingSize.width, 900 - 238 + 1, "\(theme)")
      XCTAssertTrue(host.fittingSize.width.isFinite && host.fittingSize.height.isFinite)
    }
  }

  @MainActor
  func testEveryThemeRendersTheThemePickerToANonBlankImage() throws {
    let suite = "AtlasThemeTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AtlasDisplayPreferences(defaults: defaults)
    var checksums: Set<Int> = []
    for theme in AtlasThemeID.allCases {
      preferences.theme = theme
      let host = NSHostingView(
        rootView: AtlasThemeSection()
          .padding(20)
          .frame(width: 640)
          .background(AtlasTheme.canvas)
          .environmentObject(preferences)
          .atlasThemeRoot(preferences)
      )
      host.appearance = NSAppearance(named: theme == .acid ? .darkAqua : .aqua)
      host.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      XCTAssertGreaterThan(data.count, 4_000, "\(theme)")
      checksums.insert(data.hashValue)
    }
    XCTAssertEqual(checksums.count, AtlasThemeID.allCases.count, "Each theme must look different")
  }

  /// The same live view hierarchy, never rebuilt, must repaint with the new
  /// theme's canvas and chrome as soon as the preference changes.
  @MainActor
  func testRunningViewHierarchyRestylesWhenThemeChangesWithoutRebuild() throws {
    let suite = "AtlasThemeTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AtlasDisplayPreferences(defaults: defaults)
    preferences.theme = .chainColors
    preferences.appearanceMode = .light

    /// Reads tokens inside `body`, as every screen does.
    struct Probe: View {
      var body: some View {
        Surface {
          Text("Total value").font(AtlasTheme.font(.display, .title))
        }
        .padding(24)
        .frame(width: 320, height: 160)
        .background(AtlasTheme.canvas)
      }
    }
    let host = NSHostingView(
      rootView: Probe()
        .environmentObject(preferences)
        .atlasThemeRoot(preferences)
    )
    host.appearance = NSAppearance(named: .aqua)
    host.frame = NSRect(x: 0, y: 0, width: 320, height: 160)
    host.layoutSubtreeIfNeeded()

    func cornerColour() throws -> NSColor {
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let pixel = try XCTUnwrap(bitmap.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
      return pixel
    }
    func assertCorner(_ colour: NSColor, equals expected: AtlasRGB, _ message: String) {
      XCTAssertEqual(Double(colour.redComponent), expected.red, accuracy: 0.02, message)
      XCTAssertEqual(Double(colour.greenComponent), expected.green, accuracy: 0.02, message)
      XCTAssertEqual(Double(colour.blueComponent), expected.blue, accuracy: 0.02, message)
    }

    assertCorner(
      try cornerColour(), equals: AtlasTheme.palette(for: .chainColors, appearance: .light).canvas,
      "chain colours canvas")
    preferences.theme = .candy
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    assertCorner(
      try cornerColour(), equals: AtlasTheme.palette(for: .candy, appearance: .light).canvas,
      "candy canvas after switching in place")
    preferences.theme = .riso
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    assertCorner(
      try cornerColour(), equals: AtlasTheme.palette(for: .riso, appearance: .light).canvas,
      "riso canvas after switching in place")
  }

  func testEnvironmentTokensDefaultFollowsTheSelectedTheme() {
    AtlasThemeRuntime.shared.apply(theme: .pixel, appearanceMode: .system)
    let tokens = EnvironmentValues().atlasTheme
    XCTAssertEqual(tokens.theme, .pixel)
    XCTAssertEqual(tokens.shape.radiusCard, 0)
  }

  func testTokensExposeAssetColoursFontsAndShapeToChartViews() {
    let tokens = AtlasThemeTokens(theme: .candy, variant: .light)
    XCTAssertEqual(tokens.chart.asset("BTC"), 0xFFD27A)
    XCTAssertEqual(tokens.palette.canvas, 0xFFF7EA)
    XCTAssertEqual(tokens.shape.cardBorderWidth, 2.5)
    XCTAssertEqual(tokens.typography.display.family, .bricolageGrotesque)
    _ = tokens.font(.number, size: 22, relativeTo: .title2)
    _ = tokens.font(.label, .caption)
    _ = tokens.assetColor(symbol: "BTC")
  }
}
