import SwiftUI

/// "Theme" settings for Mac and iOS: a grid of the six themes, each showing a
/// small live preview in its own canvas, font and asset colours, and the
/// light/dark control. Reads and writes `AtlasDisplayPreferences`, so a tap
/// restyles the running app.
struct AtlasThemeSection: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Theme")
        .font(AtlasTheme.font(.display, .headline, weight: .bold))
        .foregroundStyle(AtlasTheme.ink)
        .accessibilityAddTraits(.isHeader)
      AtlasThemePicker()
    }
  }
}

struct AtlasThemePicker: View {
  @EnvironmentObject private var preferences: AtlasDisplayPreferences
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let columns = [GridItem(.adaptive(minimum: 148, maximum: 240), spacing: 12)]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
        ForEach(AtlasThemeID.allCases) { theme in
          AtlasThemeCard(theme: theme, isSelected: preferences.theme == theme) {
            withAnimation(AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion)) {
              preferences.theme = theme
            }
          }
        }
      }
      appearanceControl
    }
  }

  private var appearanceControl: some View {
    let support = preferences.theme.supportedAppearances
    return VStack(alignment: .leading, spacing: 8) {
      FieldLabel("Appearance")
      Picker("Appearance", selection: $preferences.appearanceMode) {
        ForEach(AtlasAppearanceMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .disabled(support != .lightAndDark)
      .accessibilityLabel("Appearance")
      if support != .lightAndDark {
        Text(
          "\(preferences.theme.title) is \(support == .lightOnly ? "light" : "dark") only."
        )
        .font(AtlasTheme.font(.body, .caption))
        .foregroundStyle(AtlasTheme.ink3)
      }
    }
  }
}

/// One theme as a tappable card with a live preview.
struct AtlasThemeCard: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast
  var theme: AtlasThemeID
  var isSelected: Bool
  var action: () -> Void

  private var supportSummary: String {
    switch theme.supportedAppearances {
    case .lightAndDark: "Light and dark"
    case .lightOnly: "Light only"
    case .darkOnly: "Dark only"
    }
  }

  var body: some View {
    let tokens = AtlasThemeTokens(
      theme: theme,
      variant: AtlasAppearanceVariant(colorScheme: colorScheme, contrast: contrast)
    )
    Button(action: action) {
      VStack(alignment: .leading, spacing: 8) {
        AtlasThemePreview(tokens: tokens)
        HStack(spacing: 6) {
          Text(theme.title)
            .font(AtlasTheme.font(.body, .callout, weight: .semibold))
            .foregroundStyle(isSelected ? AtlasTheme.onSelection : AtlasTheme.ink)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
          Spacer(minLength: 0)
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(AtlasTheme.onSelection)
              .accessibilityHidden(true)
          }
        }
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(AtlasThemeCardButtonStyle(isSelected: isSelected))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(theme.title) theme")
    .accessibilityValue(isSelected ? "Selected, \(supportSummary)" : supportSummary)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}

/// The card frame: outlined, with a heavier accent outline when selected and a
/// 3 pt focus ring for keyboard navigation.
private struct AtlasThemeCardButtonStyle: ButtonStyle {
  @Environment(\.isFocused) private var isFocused
  var isSelected: Bool

  func makeBody(configuration: Configuration) -> some View {
    let shape = AtlasTheme.shape
    let radius = shape.radiusCard
    configuration.label
      .atlasChrome(
        fill: isSelected
          ? AtlasTheme.selection
          : (configuration.isPressed ? AtlasTheme.surfaceMuted : AtlasTheme.surface),
        border: isSelected ? AtlasTheme.accent : AtlasTheme.outline,
        level: .card,
        radius: radius,
        borderWidth: isSelected ? max(3, shape.cardBorderWidth) : max(1, shape.cardBorderWidth),
        showsShadow: false
      )
      .overlay {
        if isFocused {
          RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
            .stroke(AtlasTheme.focusRing, lineWidth: 3)
            .padding(-3)
            .accessibilityHidden(true)
        }
      }
  }
}

/// Canvas, a total in the theme's display font, and a few asset swatches.
/// Uses the card's own theme tokens, not the running theme, so each card shows
/// what choosing it would look like.
struct AtlasThemePreview: View {
  var tokens: AtlasThemeTokens

  private static let sampleSymbols = ["BTC", "ETH", "SOL", "ATOM", "USDC"]

  var body: some View {
    let shape = tokens.shape
    let palette = tokens.palette
    let radius = min(shape.radiusSmall + 2, 14)
    VStack(alignment: .leading, spacing: 8) {
      Text("$49,210")
        .font(tokens.font(.display, size: 22, relativeTo: .title2))
        .tracking(tokens.typography.display.tracking * 22)
        .foregroundStyle(palette.ink.color)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
      HStack(spacing: 5) {
        ForEach(Self.sampleSymbols.prefix(4), id: \.self) { symbol in
          swatch(symbol: symbol)
        }
      }
      Text("Total value")
        .font(tokens.font(.label, size: 10, relativeTo: .caption2))
        .foregroundStyle(palette.ink3.color)
        .lineLimit(1)
    }
    .padding(10)
    .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
    .background(palette.canvas.color)
    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .stroke(
          palette.outline.color,
          lineWidth: shape.hasBoldBorders ? 2 : 1
        )
    }
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private func swatch(symbol: String) -> some View {
    let color = tokens.chart.asset(symbol)
    let shape = tokens.shape
    let outline = tokens.palette.outline.color
    if shape.pillControls {
      Circle()
        .fill(color.color)
        .frame(width: 16, height: 16)
    } else {
      RoundedRectangle(cornerRadius: min(shape.radiusSmall, 4), style: .continuous)
        .fill(color.color)
        .overlay {
          RoundedRectangle(cornerRadius: min(shape.radiusSmall, 4), style: .continuous)
            .stroke(outline, lineWidth: shape.hasBoldBorders ? 1.5 : 1)
        }
        .frame(width: 16, height: 16)
    }
  }
}
