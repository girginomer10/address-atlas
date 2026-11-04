import SwiftUI

// The shared button styles and `Badge` draw pill controls (Chain colours,
// Heatmap) through `atlasChrome` as a `.continuous` rounded rectangle whose
// radius is as large as the control is tall. Rendered by AppKit, that outline
// grows a straight bar outside each end. The Mac screens use the three types
// below and `MacChrome`, which draw a pill as a circular-corner capsule.

/// `atlasChrome` with a pill that is a circular-corner capsule. Everything else
/// (fill, border, hard or soft shadow, pressed offset, Increase Contrast) is the
/// same as `AtlasChrome`.
struct MacChrome: ViewModifier {
  @Environment(\.colorSchemeContrast) private var contrast
  var fill: Color
  var border: Color
  var isPill: Bool
  /// Corner radius when the control is not a pill.
  var radius: CGFloat
  var borderWidth: CGFloat
  var isPressed = false
  var showsShadow = true

  func body(content: Content) -> some View {
    if isPill {
      chrome(content, outline: Capsule(style: .circular))
    } else {
      chrome(content, outline: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
  }

  private func chrome<Outline: Shape>(_ content: Content, outline: Outline) -> some View {
    let shape = AtlasTheme.shape
    let width = contrast == .increased ? max(borderWidth, 2) : borderWidth
    let hardOffset = shape.controlShadowOffset
    let press = (isPressed && hardOffset != nil) ? hardOffset : nil
    return
      content
      .background(fill)
      .clipShape(outline)
      .overlay {
        if width > 0 { outline.stroke(border, lineWidth: width) }
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
          ? .black.opacity(0.10) : .clear,
        radius: 6,
        y: 2
      )
  }
}

extension View {
  func macChrome(
    fill: Color, border: Color, isPill: Bool, radius: CGFloat, borderWidth: CGFloat,
    isPressed: Bool = false, showsShadow: Bool = true
  ) -> some View {
    modifier(
      MacChrome(
        fill: fill, border: border, isPill: isPill, radius: radius, borderWidth: borderWidth,
        isPressed: isPressed, showsShadow: showsShadow))
  }
}

/// The 3 pt keyboard-focus ring drawn outside a control.
private struct MacFocusRing: View {
  var color: Color
  var width: CGFloat
  var radius: CGFloat

  var body: some View {
    if width > 0 {
      RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
        .stroke(color, lineWidth: width)
        .padding(-3)
        .accessibilityHidden(true)
    }
  }
}

/// Fills the control in the accent colour. Same look as `AtlasPrimaryButtonStyle`.
struct MacPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.atlasTheme) private var tokens

  func makeBody(configuration: Configuration) -> some View {
    let shape = AtlasTheme.shape
    let height: CGFloat = 42
    let radius: CGFloat = shape.pillControls ? height / 2 : shape.radiusControl
    let pressed = configuration.isPressed && isEnabled
    // An accent fill in the shadow's own colour (Candy's black button) would
    // only grow a smudge; it keeps its border and loses the offset.
    let hidesShadow = tokens.palette.accent == tokens.palette.shadow
    configuration.label
      .font(AtlasTheme.font(.body, .callout, weight: .semibold))
      .foregroundStyle(isEnabled ? AtlasTheme.onAccent : AtlasTheme.ink3)
      .padding(.horizontal, 16)
      .frame(minHeight: height)
      .macChrome(
        fill: isEnabled
          ? AtlasTheme.accent.opacity(pressed && !shape.hasHardShadows ? 0.82 : 1)
          : AtlasTheme.surfaceMuted,
        border: isEnabled
          ? (shape.hasBoldBorders ? AtlasTheme.outline : AtlasTheme.accent.opacity(0.25))
          : AtlasTheme.ruleSoft,
        isPill: shape.pillControls,
        radius: radius,
        borderWidth: shape.hasBoldBorders ? shape.controlBorderWidth : 1,
        isPressed: pressed && !hidesShadow,
        showsShadow: isEnabled && !hidesShadow
      )
      .overlay {
        MacFocusRing(
          color: AtlasTheme.focusRing, width: isEnabled && isFocused ? 3 : 0, radius: radius)
      }
      .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .scaleEffect(pressed && (!shape.hasHardShadows || hidesShadow) ? 0.985 : 1)
      .opacity(isEnabled ? 1 : 0.72)
      .animation(
        AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
        value: configuration.isPressed
      )
  }
}

/// An outlined control. Same look as `AtlasSecondaryButtonStyle`.
struct MacSecondaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    let shape = AtlasTheme.shape
    let tokens = AtlasControlStyleResolver.tokens(
      for: .secondaryButton,
      appearance: AtlasAppearanceVariant(colorScheme: colorScheme, contrast: colorSchemeContrast),
      state: AtlasControlVisualState(
        isEnabled: isEnabled, isPressed: configuration.isPressed, isFocused: isFocused)
    )
    let height: CGFloat = 40
    let radius: CGFloat = shape.pillControls ? height / 2 : shape.radiusControl
    let pressed = configuration.isPressed && isEnabled
    configuration.label
      .font(AtlasTheme.font(.body, .callout, weight: .medium))
      .foregroundStyle(tokens.foreground.color)
      .padding(.horizontal, 14)
      .frame(minHeight: height)
      .macChrome(
        fill: tokens.background.color,
        border: tokens.boundary.color,
        isPill: shape.pillControls,
        radius: radius,
        borderWidth: tokens.boundaryWidth,
        isPressed: pressed,
        showsShadow: isEnabled
      )
      .overlay {
        MacFocusRing(color: tokens.focusRing.color, width: tokens.focusRingWidth, radius: radius)
      }
      .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .scaleEffect(pressed && !shape.hasHardShadows ? 0.985 : 1)
      .animation(
        AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
        value: configuration.isPressed
      )
  }
}

/// A short status or tag in a tone colour. Same look as `Badge`.
struct MacBadge: View {
  var text: String
  var color: Color

  init(_ text: String, color: Color = AtlasTheme.ink3) {
    self.text = text
    self.color = color
  }

  var body: some View {
    let shape = AtlasTheme.shape
    let height: CGFloat = 24
    Text(text)
      .font(AtlasTheme.font(.label, .caption2, weight: .semibold))
      .foregroundStyle(color)
      .lineLimit(1)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .frame(minHeight: height)
      .macChrome(
        fill: shape.hasBoldBorders ? AtlasTheme.surface : color.opacity(0.11),
        border: shape.hasBoldBorders ? AtlasTheme.outline : color.opacity(0.28),
        isPill: shape.pillControls,
        radius: shape.radiusSmall,
        borderWidth: shape.hasBoldBorders ? min(shape.controlBorderWidth, 2) : 1,
        showsShadow: false
      )
  }
}
