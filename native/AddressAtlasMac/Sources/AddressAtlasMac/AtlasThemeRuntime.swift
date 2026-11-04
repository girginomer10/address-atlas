#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif
import Observation
import SwiftUI
import os

// MARK: - Runtime selection

/// The theme the whole process is drawing with.
///
/// The static `AtlasTheme.*` colours, fonts and shape tokens read from here.
/// The runtime conforms to `Observable` by hand (thread-safe, readable from
/// any context), so any SwiftUI `body` that touches a token is re-evaluated
/// when the theme changes. No screen needs to be rebuilt or relaunched.
final class AtlasThemeRuntime: Observable, @unchecked Sendable {
  static let shared = AtlasThemeRuntime()

  private struct Selection: Equatable, Sendable {
    var theme: AtlasThemeID = .default
    var appearanceMode: AtlasAppearanceMode = .system
  }

  private let registrar = ObservationRegistrar()
  private let selection = OSAllocatedUnfairLock(initialState: Selection())

  private init() {
    // Fonts must be registered before the first themed `Font` is built.
    AtlasFonts.registerAll()
  }

  var theme: AtlasThemeID {
    registrar.access(self, keyPath: \.theme)
    return selection.withLock { $0.theme }
  }

  var appearanceMode: AtlasAppearanceMode {
    registrar.access(self, keyPath: \.appearanceMode)
    return selection.withLock { $0.appearanceMode }
  }

  /// Switches the process-wide theme. Called by `AtlasDisplayPreferences`.
  func apply(theme: AtlasThemeID, appearanceMode: AtlasAppearanceMode) {
    if selection.withLock({ $0.theme }) != theme {
      registrar.withMutation(of: self, keyPath: \.theme) {
        selection.withLock { $0.theme = theme }
      }
    }
    if selection.withLock({ $0.appearanceMode }) != appearanceMode {
      registrar.withMutation(of: self, keyPath: \.appearanceMode) {
        selection.withLock { $0.appearanceMode = appearanceMode }
      }
    }
  }
}

// MARK: - Static token API

/// Design tokens for the current theme.
///
/// Colours are dynamic: they resolve from the current theme and the view's
/// appearance (light, dark, Increase Contrast) when drawn. Reading any token
/// inside a SwiftUI `body` subscribes that view to theme changes.
enum AtlasTheme {
  /// The selected theme. Reading it inside `body` subscribes the view.
  static var current: AtlasThemeID { AtlasThemeRuntime.shared.theme }

  static var definition: AtlasThemeDefinition { AtlasThemeCatalog.definition(for: current) }
  static var shape: AtlasShape { definition.shape }
  static var typography: AtlasTypography { definition.typography }

  static func palette(for appearance: AtlasAppearanceVariant) -> AtlasPalette {
    definition.palette(for: appearance)
  }

  static func palette(
    for theme: AtlasThemeID,
    appearance: AtlasAppearanceVariant
  ) -> AtlasPalette {
    AtlasThemeCatalog.definition(for: theme).palette(for: appearance)
  }

  /// Concrete tokens of the current theme for one appearance.
  static func tokens(for appearance: AtlasAppearanceVariant) -> AtlasThemeTokens {
    AtlasThemeTokens(theme: current, variant: appearance)
  }

  /// The dynamic colour of `role` in the current theme.
  static func color(_ role: AtlasColorRole) -> Color {
    AtlasDynamicColors.color(role, theme: current)
  }

  static var paper: Color { color(.canvas) }
  static var paper2: Color { color(.surface) }
  static var paper3: Color { color(.surfaceMuted) }
  static var canvas: Color { color(.canvas) }
  static var surface: Color { color(.surface) }
  static var surfaceMuted: Color { color(.surfaceMuted) }
  static var ink: Color { color(.ink) }
  static var ink2: Color { color(.ink2) }
  static var ink3: Color { color(.ink3) }
  static var rule: Color { color(.rule) }
  static var ruleSoft: Color { color(.ruleSoft) }
  static var outline: Color { color(.outline) }
  static var controlBoundary: Color { color(.controlBoundary) }
  static var focusRing: Color { color(.focusRing) }
  /// Interactive colour: links, icons, primary fills. Reads on canvas and surface.
  static var accent: Color { color(.accent) }
  /// Label colour on an `accent` fill.
  static var onAccent: Color { color(.onAccent) }
  /// Fill of the selected navigation item, chip or segment.
  static var selection: Color { color(.selection) }
  static var onSelection: Color { color(.onSelection) }
  static var accentSoft: Color { color(.accentSoft) }
  static var gainSoft: Color { color(.gainSoft) }
  static var warningSoft: Color { color(.warningSoft) }
  static var lossSoft: Color { color(.lossSoft) }
  static var gain: Color { color(.gain) }
  static var loss: Color { color(.loss) }
  /// Dark enough for normal-size warning text on each supported surface.
  static var warning: Color { color(.warning) }
  static var shadow: Color { color(.shadow) }
  /// Ink for text on pastel or brand-colour blocks; dark in every appearance.
  static var onPastel: Color { color(.onPastel) }

  // MARK: Fonts

  /// Themed font at an explicit size, scaled with Dynamic Type relative to
  /// `textStyle` on iOS.
  static func font(
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

  /// Themed font at the size a system text style has on this platform.
  static func font(_ role: AtlasFontRole, _ textStyle: Font.TextStyle, weight: Font.Weight? = nil)
    -> Font
  {
    font(
      role, size: AtlasThemeFonts.pointSize(for: textStyle), relativeTo: textStyle, weight: weight)
  }

  /// Letter spacing, in points, for `role` at `size`.
  static func tracking(_ role: AtlasFontRole, size: CGFloat) -> CGFloat {
    typography[role].tracking * size
  }

  // MARK: Chart colours

  /// A dynamic series colour for an asset symbol in the current theme. Unknown
  /// symbols get a stable colour from the theme's categorical set.
  static func assetColor(symbol: String) -> Color {
    AtlasDynamicColors.chartColor(theme: current) { $0.asset(symbol) }
  }

  static func networkColor(_ identifier: String) -> Color {
    AtlasDynamicColors.chartColor(theme: current) { $0.network(identifier) }
  }

  static func stateColor(_ state: AtlasHoldingState) -> Color {
    AtlasDynamicColors.chartColor(theme: current) { $0.state(state) }
  }

  static func kindColor(_ kind: AtlasAssetKind) -> Color {
    AtlasDynamicColors.chartColor(theme: current) { $0.kind(kind) }
  }
}

/// Corner radii of the current theme, as the earlier static scale.
enum AtlasRadius {
  static var small: CGFloat { AtlasTheme.shape.radiusSmall }
  static var control: CGFloat { AtlasTheme.shape.radiusControl }
  static var card: CGFloat { AtlasTheme.shape.radiusCard }
  static var large: CGFloat { AtlasTheme.shape.radiusLarge }
}

enum AtlasMotion {
  static let quick = Animation.easeOut(duration: 0.16)
  static let standard = Animation.spring(response: 0.34, dampingFraction: 0.86)

  static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : animation
  }
}

// MARK: - Dynamic colour tables

private enum AtlasDynamicColors {
  /// One dynamic `Color` per theme and role, built once.
  private static let table: [AtlasThemeID: [AtlasColorRole: Color]] = {
    var themes: [AtlasThemeID: [AtlasColorRole: Color]] = [:]
    for id in AtlasThemeID.allCases {
      let definition = AtlasThemeCatalog.definition(for: id)
      var roles: [AtlasColorRole: Color] = [:]
      for role in AtlasColorRole.allCases {
        roles[role] = dynamicColor(name: "AddressAtlas.\(id.rawValue).\(role.rawValue)") {
          definition.palette(for: $0)[role]
        }
      }
      themes[id] = roles
    }
    return themes
  }()

  static func color(_ role: AtlasColorRole, theme: AtlasThemeID) -> Color {
    guard let color = table[theme]?[role] else {
      preconditionFailure("Missing dynamic colour \(role) for \(theme)")
    }
    return color
  }

  static func chartColor(
    theme: AtlasThemeID,
    _ pick: @escaping @Sendable (AtlasChartPalette) -> AtlasRGB
  ) -> Color {
    let definition = AtlasThemeCatalog.definition(for: theme)
    return dynamicColor(name: nil) { pick(definition.chart(for: $0)) }
  }

  private static func dynamicColor(
    name: String?,
    resolve: @escaping @Sendable (AtlasAppearanceVariant) -> AtlasRGB
  ) -> Color {
    #if canImport(AppKit)
      let provider: (NSAppearance) -> NSColor = { appearance in
        resolve(
          AtlasAppearanceVariant(
            appearance: appearance,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
          )
        ).nsColor
      }
      if let name {
        return Color(nsColor: NSColor(name: NSColor.Name(name), dynamicProvider: provider))
      }
      return Color(nsColor: NSColor(name: nil, dynamicProvider: provider))
    #else
      return Color(
        uiColor: UIColor { traitCollection in
          resolve(AtlasAppearanceVariant(traitCollection: traitCollection)).uiColor
        })
    #endif
  }
}

// MARK: - Environment and root

private struct AtlasThemeTokensKey: EnvironmentKey {
  /// Outside a themed root the tokens still follow the selected theme, in the
  /// light appearance.
  static var defaultValue: AtlasThemeTokens {
    AtlasThemeTokens(theme: AtlasThemeRuntime.shared.theme, variant: .light)
  }
}

extension EnvironmentValues {
  /// The selected theme resolved for this view's appearance: palette, chart
  /// colours, shape and typography. Set by `atlasThemeRoot`.
  var atlasTheme: AtlasThemeTokens {
    get { self[AtlasThemeTokensKey.self] }
    set { self[AtlasThemeTokensKey.self] = newValue }
  }
}

extension View {
  /// Applies the user's theme to a window or scene root: the light/dark
  /// override (single-mode themes force their own), `\.atlasTheme`, the
  /// default body font, and the accent tint.
  func atlasThemeRoot(_ preferences: AtlasDisplayPreferences) -> some View {
    modifier(AtlasThemeRootModifier(preferences: preferences))
  }
}

private struct AtlasThemeRootModifier: ViewModifier {
  @ObservedObject var preferences: AtlasDisplayPreferences

  func body(content: Content) -> some View {
    content
      .modifier(AtlasThemeEnvironmentModifier())
      .preferredColorScheme(preferences.theme.forcedColorScheme(for: preferences.appearanceMode))
  }
}

private struct AtlasThemeEnvironmentModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    let tokens = AtlasThemeTokens(
      theme: AtlasThemeRuntime.shared.theme,
      variant: AtlasAppearanceVariant(colorScheme: colorScheme, contrast: contrast)
    )
    content
      .environment(\.atlasTheme, tokens)
      .font(tokens.font(.body, .body))
      .tint(AtlasTheme.accent)
  }
}

// MARK: - Shape-aware chrome

/// Fill, border and shadow of a card or control, drawn from the current
/// theme's shape: soft shadow (Chain colours), hard offset shadow (Candy,
/// Pixel), or flat. Increase Contrast thickens borders and drops soft shadows.
struct AtlasChrome: ViewModifier {
  enum Level {
    case card
    case control
  }

  @Environment(\.colorSchemeContrast) private var contrast
  var fill: Color
  var border: Color
  var level: Level = .card
  var radius: CGFloat?
  var borderWidth: CGFloat?
  /// A pressed control sinks onto its hard shadow instead of dimming.
  var isPressed = false
  var showsShadow = true

  func body(content: Content) -> some View {
    let shape = AtlasTheme.shape
    let resolvedRadius =
      radius
      ?? (level == .card
        ? shape.radiusCard : (shape.pillControls ? 999 : shape.radiusControl))
    let baseWidth =
      borderWidth ?? (level == .card ? shape.cardBorderWidth : shape.controlBorderWidth)
    let width = contrast == .increased ? max(baseWidth, 2) : baseWidth
    let hardOffset = level == .card ? shape.cardShadowOffset : shape.controlShadowOffset
    let outline = RoundedRectangle(cornerRadius: resolvedRadius, style: .continuous)
    let press = (isPressed && hardOffset != nil) ? hardOffset : nil

    content
      .background(fill)
      .clipShape(outline)
      .overlay {
        if width > 0 {
          outline.stroke(border, lineWidth: width)
        }
      }
      .background(alignment: .topLeading) {
        if showsShadow, let hardOffset {
          outline
            .fill(AtlasTheme.shadow)
            .offset(
              x: press == nil ? hardOffset.width : 0,
              y: press == nil ? hardOffset.height : 0
            )
            .accessibilityHidden(true)
        }
      }
      .offset(x: press?.width ?? 0, y: press?.height ?? 0)
      .shadow(
        color: showsShadow && shape.usesSoftShadow && contrast != .increased
          ? .black.opacity(level == .card ? 0.07 : 0.10) : .clear,
        radius: level == .card ? 12 : 6,
        y: level == .card ? 4 : 2
      )
  }
}

extension View {
  func atlasChrome(
    fill: Color,
    border: Color,
    level: AtlasChrome.Level = .card,
    radius: CGFloat? = nil,
    borderWidth: CGFloat? = nil,
    isPressed: Bool = false,
    showsShadow: Bool = true
  ) -> some View {
    modifier(
      AtlasChrome(
        fill: fill,
        border: border,
        level: level,
        radius: radius,
        borderWidth: borderWidth,
        isPressed: isPressed,
        showsShadow: showsShadow
      )
    )
  }
}
