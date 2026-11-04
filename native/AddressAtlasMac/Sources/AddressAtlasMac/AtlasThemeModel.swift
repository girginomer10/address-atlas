#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif
import SwiftUI

// MARK: - Colour value

/// An sRGB colour that is cheap to compare, hash, and contrast-check. Palettes
/// are stored as `AtlasRGB`; SwiftUI colours are derived from them.
struct AtlasRGB: Equatable, Hashable, Sendable, ExpressibleByIntegerLiteral {
  let red: Double
  let green: Double
  let blue: Double

  static let black = AtlasRGB(red: 0, green: 0, blue: 0)
  static let white = AtlasRGB(red: 1, green: 1, blue: 1)

  init(red: Double, green: Double, blue: Double) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  /// `0xRRGGBB`, so palettes read like the design CSS.
  init(integerLiteral value: UInt32) {
    self.init(
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255
    )
  }

  var color: Color {
    Color(red: red, green: green, blue: blue)
  }

  #if canImport(AppKit)
    var nsColor: NSColor {
      NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
  #else
    var uiColor: UIColor {
      UIColor(red: red, green: green, blue: blue, alpha: 1)
    }
  #endif

  /// WCAG relative luminance.
  var relativeLuminance: Double {
    func linearized(_ component: Double) -> Double {
      component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linearized(red) + 0.7152 * linearized(green) + 0.0722 * linearized(blue)
  }

  /// WCAG contrast ratio, 1 to 21.
  func contrast(with other: AtlasRGB) -> Double {
    let first = relativeLuminance
    let second = other.relativeLuminance
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)
  }

  /// Linear mix in sRGB: `amount` 0 is `self`, 1 is `other`.
  func mixed(with other: AtlasRGB, amount: Double) -> AtlasRGB {
    let t = min(max(amount, 0), 1)
    return AtlasRGB(
      red: red + (other.red - red) * t,
      green: green + (other.green - green) * t,
      blue: blue + (other.blue - blue) * t
    )
  }

  /// Black or white, whichever reads better on this colour.
  var readableInk: AtlasRGB {
    contrast(with: .black) >= contrast(with: .white) ? .black : .white
  }

  /// Moves this colour toward `target` in 5% steps until it reaches `minimum`
  /// contrast on every background (or arrives at `target`).
  func ensuringContrast(
    against backgrounds: [AtlasRGB],
    minimum: Double,
    toward target: AtlasRGB
  ) -> AtlasRGB {
    var amount = 0.0
    while amount < 1 {
      let candidate = mixed(with: target, amount: amount)
      if backgrounds.allSatisfy({ candidate.contrast(with: $0) >= minimum }) {
        return candidate
      }
      amount += 0.05
    }
    return target
  }
}

// MARK: - Theme identity and appearance

/// The six user-selectable themes. Raw values are persisted; do not rename.
enum AtlasThemeID: String, CaseIterable, Identifiable, Codable, Sendable {
  case chainColors
  case candy
  case riso
  case heatmap
  case pixel
  case acid

  static let `default`: AtlasThemeID = .chainColors

  var id: String { rawValue }

  var title: String {
    switch self {
    case .chainColors: "Chain colours"
    case .candy: "Candy brutal"
    case .riso: "Riso zine"
    case .heatmap: "Heatmap"
    case .pixel: "Pixel"
    case .acid: "Acid"
    }
  }

  var supportedAppearances: AtlasThemeAppearanceSupport {
    switch self {
    case .riso: .lightOnly
    case .acid: .darkOnly
    case .chainColors, .candy, .heatmap, .pixel: .lightAndDark
    }
  }

  /// Colour scheme the theme requires, or the user's choice when it has both.
  func forcedColorScheme(for mode: AtlasAppearanceMode) -> ColorScheme? {
    switch supportedAppearances {
    case .lightOnly: .light
    case .darkOnly: .dark
    case .lightAndDark: mode.colorScheme
    }
  }
}

enum AtlasThemeAppearanceSupport: Equatable, Sendable {
  case lightAndDark
  case lightOnly
  case darkOnly
}

/// The user's light/dark choice. Single-mode themes ignore it.
enum AtlasAppearanceMode: String, CaseIterable, Identifiable, Codable, Sendable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

enum AtlasAppearanceVariant: CaseIterable, Equatable, Hashable, Sendable {
  case light
  case dark
  case highContrastLight
  case highContrastDark

  init(colorScheme: ColorScheme, contrast: ColorSchemeContrast) {
    switch (colorScheme, contrast) {
    case (.light, .standard): self = .light
    case (.dark, .standard): self = .dark
    case (.light, .increased): self = .highContrastLight
    case (.dark, .increased): self = .highContrastDark
    @unknown default: self = colorScheme == .dark ? .dark : .light
    }
  }

  #if canImport(AppKit)
    init(appearance: NSAppearance, increaseContrast: Bool) {
      let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      self.init(isDark: isDark, increaseContrast: increaseContrast)
    }
  #else
    init(traitCollection: UITraitCollection) {
      self.init(
        isDark: traitCollection.userInterfaceStyle == .dark,
        increaseContrast: traitCollection.accessibilityContrast == .high
      )
    }
  #endif

  init(isDark: Bool, increaseContrast: Bool) {
    switch (isDark, increaseContrast) {
    case (false, false): self = .light
    case (true, false): self = .dark
    case (false, true): self = .highContrastLight
    case (true, true): self = .highContrastDark
    }
  }

  var isDark: Bool { self == .dark || self == .highContrastDark }
  var isHighContrast: Bool { self == .highContrastLight || self == .highContrastDark }
}

// MARK: - Palette

/// Semantic colour roles every theme defines. `AtlasTheme.color(_:)` resolves a
/// role for the current theme and appearance.
enum AtlasColorRole: String, CaseIterable, Sendable {
  case canvas, surface, surfaceMuted
  case ink, ink2, ink3
  case rule, ruleSoft, outline
  case controlBoundary, controlBoundaryDisabled, focusRing
  case accent, onAccent
  case selection, onSelection
  case accentSoft, gainSoft, warningSoft, lossSoft
  case gain, loss, warning
  case shadow, onPastel
}

/// Colours for one theme in one light/dark appearance.
///
/// `accent` doubles as text, icon and fill colour, so it meets 4.5:1 on
/// `canvas` and `surface`; `onAccent` is the label colour on an accent fill.
/// `selection` is the fill for the selected navigation item, chip or segment.
struct AtlasPalette: Equatable, Sendable {
  let canvas: AtlasRGB
  let surface: AtlasRGB
  let surfaceMuted: AtlasRGB
  let ink: AtlasRGB
  let ink2: AtlasRGB
  let ink3: AtlasRGB
  /// Dividers and table rules that must stay visible.
  let rule: AtlasRGB
  /// Quiet separators inside a card.
  let ruleSoft: AtlasRGB
  /// Border colour of cards and panels.
  let outline: AtlasRGB
  let controlBoundary: AtlasRGB
  let focusRing: AtlasRGB
  let accent: AtlasRGB
  let onAccent: AtlasRGB
  let selection: AtlasRGB
  let onSelection: AtlasRGB
  /// Tinted callout fills; body ink stays readable on all four.
  let accentSoft: AtlasRGB
  let gainSoft: AtlasRGB
  let warningSoft: AtlasRGB
  let lossSoft: AtlasRGB
  let gain: AtlasRGB
  let loss: AtlasRGB
  let warning: AtlasRGB
  /// Colour of a hard offset shadow, where the theme has one.
  let shadow: AtlasRGB
  /// Ink for text placed on pastel or brand blocks; dark in every appearance.
  let onPastel: AtlasRGB

  var controlBoundaryDisabled: AtlasRGB {
    controlBoundary.mixed(with: canvas, amount: 0.45)
  }

  // Names used before themes existed.
  var paper: AtlasRGB { canvas }
  var paper2: AtlasRGB { surface }
  var paper3: AtlasRGB { surfaceMuted }

  subscript(role: AtlasColorRole) -> AtlasRGB {
    switch role {
    case .canvas: canvas
    case .surface: surface
    case .surfaceMuted: surfaceMuted
    case .ink: ink
    case .ink2: ink2
    case .ink3: ink3
    case .rule: rule
    case .ruleSoft: ruleSoft
    case .outline: outline
    case .controlBoundary: controlBoundary
    case .controlBoundaryDisabled: controlBoundaryDisabled
    case .focusRing: focusRing
    case .accent: accent
    case .onAccent: onAccent
    case .selection: selection
    case .onSelection: onSelection
    case .accentSoft: accentSoft
    case .gainSoft: gainSoft
    case .warningSoft: warningSoft
    case .lossSoft: lossSoft
    case .gain: gain
    case .loss: loss
    case .warning: warning
    case .shadow: shadow
    case .onPastel: onPastel
    }
  }

  /// Increase Contrast version: black or white ink, stronger rules and
  /// boundaries, and semantic colours pushed to 7:1 on every surface.
  func highContrast(isDark: Bool) -> AtlasPalette {
    let extreme: AtlasRGB = isDark ? .white : .black
    let opposite: AtlasRGB = isDark ? .black : .white
    let hcCanvas = canvas.mixed(with: opposite, amount: 0.6)
    let hcSurface = surface.mixed(with: opposite, amount: 0.4)
    let hcMuted = surfaceMuted.mixed(with: opposite, amount: 0.3)
    let grounds = [hcCanvas, hcSurface]
    let allGrounds = [hcCanvas, hcSurface, hcMuted]
    func strengthened(_ color: AtlasRGB, minimum: Double = 7) -> AtlasRGB {
      color.ensuringContrast(against: allGrounds, minimum: minimum, toward: extreme)
    }
    let hcAccent = accent.ensuringContrast(against: allGrounds, minimum: 7, toward: extreme)
    return AtlasPalette(
      canvas: hcCanvas,
      surface: hcSurface,
      surfaceMuted: hcMuted,
      ink: extreme,
      ink2: extreme.mixed(with: hcCanvas, amount: 0.10),
      ink3: extreme.mixed(with: hcCanvas, amount: 0.22),
      rule: extreme.mixed(with: hcCanvas, amount: 0.30),
      ruleSoft: extreme.mixed(with: hcCanvas, amount: 0.52),
      outline: extreme,
      controlBoundary: extreme,
      focusRing: focusRing.ensuringContrast(against: grounds, minimum: 4.5, toward: extreme),
      accent: hcAccent,
      onAccent: hcAccent.readableInk,
      selection: selection,
      onSelection: selection.readableInk,
      accentSoft: accentSoft,
      gainSoft: gainSoft,
      warningSoft: warningSoft,
      lossSoft: lossSoft,
      gain: strengthened(gain),
      loss: strengthened(loss),
      warning: strengthened(warning),
      shadow: extreme,
      onPastel: .black
    )
  }
}

// MARK: - Shape

/// How a card's fill is chosen. `.pastel` themes tint hero cards from the
/// theme's pastel set; `.plain` themes use one surface colour.
enum AtlasCardFillStyle: Equatable, Sendable {
  case plain
  case pastel
}

/// Corner radii, borders and shadows for one theme.
struct AtlasShape: Equatable, Sendable {
  var radiusSmall: CGFloat
  var radiusControl: CGFloat
  var radiusCard: CGFloat
  var radiusLarge: CGFloat
  /// Border width of cards and panels; 0 draws only a hairline.
  var cardBorderWidth: CGFloat
  /// Border width of text fields and secondary buttons.
  var controlBorderWidth: CGFloat
  /// Hard offset shadow of cards (no blur), or nil.
  var cardShadowOffset: CGSize?
  /// Hard offset shadow of buttons and selected items, or nil.
  var controlShadowOffset: CGSize?
  /// Soft diffuse card shadow, used instead of a hard one.
  var usesSoftShadow: Bool
  /// Buttons and chips are capsules.
  var pillControls: Bool
  var cardFill: AtlasCardFillStyle
  /// Draws a faint vertical gradient on the canvas.
  var canvasGradient: Bool

  var hasHardShadows: Bool { cardShadowOffset != nil || controlShadowOffset != nil }
  var hasBoldBorders: Bool { cardBorderWidth >= 2 }
}

// MARK: - Typography

enum AtlasFontRole: CaseIterable, Sendable {
  /// The portfolio total and page titles.
  case display
  /// Figures in lists and tiles; tabular.
  case number
  /// Running text and controls.
  case body
  /// Small captions, eyebrows and table headers.
  case label
  /// Addresses, hashes and recovery codes.
  case mono
}

struct AtlasFontSpec: Equatable, Sendable {
  var family: AtlasFontFamily
  var weight: Font.Weight
  /// Letter spacing as a fraction of the point size.
  var tracking: CGFloat = 0
}

struct AtlasTypography: Equatable, Sendable {
  var display: AtlasFontSpec
  var number: AtlasFontSpec
  var body: AtlasFontSpec
  var label: AtlasFontSpec
  var mono: AtlasFontSpec

  subscript(role: AtlasFontRole) -> AtlasFontSpec {
    switch role {
    case .display: display
    case .number: number
    case .body: body
    case .label: label
    case .mono: mono
    }
  }
}

// MARK: - Charts

/// How a holding is held. The grouping "state" in the portfolio views.
enum AtlasHoldingState: String, CaseIterable, Identifiable, Sendable {
  case liquid
  case staked
  case unbonding
  case rewards
  case onExchange

  var id: String { rawValue }

  var title: String {
    switch self {
    case .liquid: "Liquid"
    case .staked: "Staked"
    case .unbonding: "Unbonding"
    case .rewards: "Rewards"
    case .onExchange: "On exchange"
    }
  }
}

/// The grouping "kind" (shown as "Type") in the portfolio views.
enum AtlasAssetKind: String, CaseIterable, Identifiable, Sendable {
  case native
  case stablecoin
  case token
  case exchange
  case manual

  var id: String { rawValue }

  var title: String {
    switch self {
    case .native: "Native"
    case .stablecoin: "Stablecoin"
    case .token: "Token"
    case .exchange: "Exchange"
    case .manual: "Manual"
    }
  }
}

/// Series colours for charts, in one theme.
struct AtlasChartPalette: Equatable, Sendable {
  /// Colour by upper-case symbol.
  var assets: [String: AtlasRGB]
  /// Colour by normalised network key (see `normalizedNetworkKey`).
  var networks: [String: AtlasRGB]
  /// Series colours for anything without a fixed colour. At least eight.
  var categorical: [AtlasRGB]
  var states: [AtlasHoldingState: AtlasRGB]
  var kinds: [AtlasAssetKind: AtlasRGB]
  /// Fill colours for tinted hero cards (Candy pink, lime, sky, peach).
  var pastels: [AtlasRGB]
  /// Overlapping marks should blend with multiply (Riso overprint).
  var blendsWithMultiply: Bool

  /// Wrapped and derivative symbols share their base asset's colour.
  static let symbolAliases: [String: String] = [
    "WETH": "ETH", "STETH": "ETH", "WSTETH": "ETH", "CBETH": "ETH", "RETH": "ETH",
    "WBTC": "BTC", "CBBTC": "BTC", "TBTC": "BTC",
    "MATIC": "POL",
    "USDC.E": "USDC", "USDBC": "USDC",
    "XDAI": "DAI", "SDAI": "DAI",
  ]

  static func normalizedSymbol(_ symbol: String) -> String {
    let key = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return symbolAliases[key] ?? key
  }

  /// Lower-case alphanumerics only, so "Cosmos Hub", "cosmoshub" and
  /// "COSMOS-HUB" are the same network.
  static func normalizedNetworkKey(_ identifier: String) -> String {
    String(identifier.lowercased().filter { $0.isLetter || $0.isNumber })
  }

  /// Deterministic 64-bit FNV-1a hash; stable across launches and platforms.
  static func stableHash(_ text: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
  }

  func categorical(at index: Int) -> AtlasRGB {
    categorical[((index % categorical.count) + categorical.count) % categorical.count]
  }

  /// A fixed colour for known symbols, otherwise a stable pick from
  /// `categorical` so an unknown token keeps its colour on every screen.
  func asset(_ symbol: String) -> AtlasRGB {
    let key = Self.normalizedSymbol(symbol)
    if let color = assets[key] { return color }
    return categorical(at: Int(Self.stableHash(key) % UInt64(categorical.count)))
  }

  func network(_ identifier: String) -> AtlasRGB {
    let key = Self.normalizedNetworkKey(identifier)
    if let color = networks[key] { return color }
    return categorical(at: Int(Self.stableHash(key) % UInt64(categorical.count)))
  }

  func state(_ state: AtlasHoldingState) -> AtlasRGB {
    states[state] ?? categorical(at: AtlasHoldingState.allCases.firstIndex(of: state) ?? 0)
  }

  func kind(_ kind: AtlasAssetKind) -> AtlasRGB {
    kinds[kind] ?? categorical(at: AtlasAssetKind.allCases.firstIndex(of: kind) ?? 0)
  }

  func pastel(at index: Int) -> AtlasRGB {
    pastels.isEmpty
      ? categorical(at: index)
      : pastels[((index % pastels.count) + pastels.count) % pastels.count]
  }
}

// MARK: - Definition and resolved tokens

/// Everything one theme defines. Palettes for all four appearance variants are
/// resolved once, so colour lookups at draw time are dictionary reads.
struct AtlasThemeDefinition: Sendable {
  let id: AtlasThemeID
  let shape: AtlasShape
  let typography: AtlasTypography
  private let palettes: [AtlasAppearanceVariant: AtlasPalette]
  private let lightChart: AtlasChartPalette
  private let darkChart: AtlasChartPalette

  init(
    id: AtlasThemeID,
    light: AtlasPalette?,
    dark: AtlasPalette?,
    shape: AtlasShape,
    typography: AtlasTypography,
    lightChart: AtlasChartPalette,
    darkChart: AtlasChartPalette
  ) {
    precondition(light != nil || dark != nil, "A theme needs at least one palette")
    self.id = id
    self.shape = shape
    self.typography = typography
    self.lightChart = lightChart
    self.darkChart = darkChart
    var resolved: [AtlasAppearanceVariant: AtlasPalette] = [:]
    for variant in AtlasAppearanceVariant.allCases {
      let useDark: Bool
      switch id.supportedAppearances {
      case .lightOnly: useDark = false
      case .darkOnly: useDark = true
      case .lightAndDark: useDark = variant.isDark
      }
      guard let base = useDark ? dark : light else {
        preconditionFailure("\(id) is missing its \(useDark ? "dark" : "light") palette")
      }
      resolved[variant] = variant.isHighContrast ? base.highContrast(isDark: useDark) : base
    }
    palettes = resolved
  }

  func palette(for variant: AtlasAppearanceVariant) -> AtlasPalette {
    guard let palette = palettes[variant] else {
      preconditionFailure("Palette table is complete for every variant")
    }
    return palette
  }

  func chart(for variant: AtlasAppearanceVariant) -> AtlasChartPalette {
    let useDark: Bool
    switch id.supportedAppearances {
    case .lightOnly: useDark = false
    case .darkOnly: useDark = true
    case .lightAndDark: useDark = variant.isDark
    }
    return useDark ? darkChart : lightChart
  }
}

/// The current theme, resolved for one appearance. Read it from SwiftUI with
/// `@Environment(\.atlasTheme)` when a view needs concrete values (chart
/// colours, a readable ink on a block, fonts, shape).
struct AtlasThemeTokens: Equatable, Sendable {
  let theme: AtlasThemeID
  let variant: AtlasAppearanceVariant
  let palette: AtlasPalette
  let shape: AtlasShape
  let typography: AtlasTypography
  let chart: AtlasChartPalette

  init(theme: AtlasThemeID, variant: AtlasAppearanceVariant) {
    let definition = AtlasThemeCatalog.definition(for: theme)
    self.theme = theme
    self.variant = variant
    palette = definition.palette(for: variant)
    shape = definition.shape
    typography = definition.typography
    chart = definition.chart(for: variant)
  }

  func color(_ role: AtlasColorRole) -> Color {
    palette[role].color
  }

  /// Series colour for an asset symbol; unknown symbols get a stable colour.
  func assetColor(symbol: String) -> Color {
    chart.asset(symbol).color
  }

  func networkColor(_ identifier: String) -> Color {
    chart.network(identifier).color
  }

  func stateColor(_ state: AtlasHoldingState) -> Color {
    chart.state(state).color
  }

  func kindColor(_ kind: AtlasAssetKind) -> Color {
    chart.kind(kind).color
  }

  /// Black or white ink for text on a block of `background`.
  func ink(on background: AtlasRGB) -> Color {
    background.readableInk.color
  }

  /// Themed font. The size scales with Dynamic Type relative to `textStyle` on
  /// iOS; on macOS it is fixed.
  func font(
    _ role: AtlasFontRole,
    size: CGFloat,
    relativeTo textStyle: Font.TextStyle = .body,
    weight: Font.Weight? = nil
  ) -> Font {
    AtlasThemeFonts.font(
      spec: typography[role],
      role: role,
      size: size,
      relativeTo: textStyle,
      weight: weight
    )
  }

  /// Themed font at the size a system text style would have.
  func font(_ role: AtlasFontRole, _ textStyle: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
    font(role, size: AtlasThemeFonts.pointSize(for: textStyle), relativeTo: textStyle, weight: weight)
  }
}

enum AtlasThemeFonts {
  /// Point sizes of the system text styles on this platform, so themed text
  /// replaces `.callout` or `.caption` at the same size.
  static func pointSize(for style: Font.TextStyle) -> CGFloat {
    #if os(macOS)
      switch style {
      case .largeTitle: 26
      case .title: 22
      case .title2: 17
      case .title3: 15
      case .headline: 13
      case .body: 13
      case .callout: 12
      case .subheadline: 11
      case .footnote: 10
      case .caption: 10
      case .caption2: 10
      @unknown default: 13
      }
    #else
      switch style {
      case .largeTitle: 34
      case .title: 28
      case .title2: 22
      case .title3: 20
      case .headline: 17
      case .body: 17
      case .callout: 16
      case .subheadline: 15
      case .footnote: 13
      case .caption: 12
      case .caption2: 11
      @unknown default: 17
      }
    #endif
  }

  static func font(
    spec: AtlasFontSpec,
    role: AtlasFontRole,
    size: CGFloat,
    relativeTo textStyle: Font.TextStyle,
    weight: Font.Weight?
  ) -> Font {
    let resolvedWeight = weight ?? spec.weight
    var font: Font
    if AtlasFonts.isAvailable(spec.family) {
      font = Font.custom(spec.family.familyName, size: size, relativeTo: textStyle)
        .weight(resolvedWeight)
    } else {
      font = Font.system(textStyle, design: spec.family.fallbackDesign).weight(resolvedWeight)
    }
    if role == .number { font = font.monospacedDigit() }
    return font
  }
}
