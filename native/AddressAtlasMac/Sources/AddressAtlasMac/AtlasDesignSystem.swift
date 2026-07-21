import AddressAtlasCore
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct AtlasRGB: Equatable, Sendable {
  let red: Double
  let green: Double
  let blue: Double

  var color: Color {
    Color(red: red, green: green, blue: blue)
  }

  var nsColor: NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
  }
}

enum AtlasAppearanceVariant: CaseIterable, Equatable, Sendable {
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

  init(appearance: NSAppearance, increaseContrast: Bool) {
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    switch (isDark, increaseContrast) {
    case (false, false): self = .light
    case (true, false): self = .dark
    case (false, true): self = .highContrastLight
    case (true, true): self = .highContrastDark
    }
  }
}

struct AtlasPalette: Equatable, Sendable {
  let paper: AtlasRGB
  let paper2: AtlasRGB
  let paper3: AtlasRGB
  let ink: AtlasRGB
  let ink2: AtlasRGB
  let ink3: AtlasRGB
  let rule: AtlasRGB
  let ruleSoft: AtlasRGB
  let controlBoundary: AtlasRGB
  let controlBoundaryDisabled: AtlasRGB
  let focusRing: AtlasRGB
  let accent: AtlasRGB
  let gain: AtlasRGB
  let loss: AtlasRGB
  let warning: AtlasRGB
}

enum AtlasTheme {
  static let lightPalette = AtlasPalette(
    paper: AtlasRGB(red: 0.965, green: 0.969, blue: 0.976),
    paper2: AtlasRGB(red: 1, green: 1, blue: 1),
    paper3: AtlasRGB(red: 0.90, green: 0.916, blue: 0.945),
    ink: AtlasRGB(red: 0.09, green: 0.105, blue: 0.14),
    ink2: AtlasRGB(red: 0.27, green: 0.30, blue: 0.36),
    ink3: AtlasRGB(red: 0.36, green: 0.39, blue: 0.45),
    rule: AtlasRGB(red: 0.72, green: 0.75, blue: 0.80),
    ruleSoft: AtlasRGB(red: 0.84, green: 0.86, blue: 0.90),
    controlBoundary: AtlasRGB(red: 0.37, green: 0.40, blue: 0.46),
    controlBoundaryDisabled: AtlasRGB(red: 0.50, green: 0.53, blue: 0.59),
    focusRing: AtlasRGB(red: 0.20, green: 0.39, blue: 0.88),
    accent: AtlasRGB(red: 0.20, green: 0.39, blue: 0.88),
    gain: AtlasRGB(red: 0.08, green: 0.48, blue: 0.30),
    loss: AtlasRGB(red: 0.76, green: 0.14, blue: 0.19),
    warning: AtlasRGB(red: 0.57, green: 0.30, blue: 0.02)
  )

  static let darkPalette = AtlasPalette(
    paper: AtlasRGB(red: 0.055, green: 0.063, blue: 0.078),
    paper2: AtlasRGB(red: 0.085, green: 0.096, blue: 0.12),
    paper3: AtlasRGB(red: 0.13, green: 0.145, blue: 0.175),
    ink: AtlasRGB(red: 0.95, green: 0.96, blue: 0.98),
    ink2: AtlasRGB(red: 0.79, green: 0.81, blue: 0.85),
    ink3: AtlasRGB(red: 0.68, green: 0.71, blue: 0.77),
    rule: AtlasRGB(red: 0.31, green: 0.34, blue: 0.40),
    ruleSoft: AtlasRGB(red: 0.21, green: 0.23, blue: 0.28),
    controlBoundary: AtlasRGB(red: 0.46, green: 0.50, blue: 0.58),
    controlBoundaryDisabled: AtlasRGB(red: 0.36, green: 0.39, blue: 0.45),
    focusRing: AtlasRGB(red: 0.43, green: 0.61, blue: 1.0),
    accent: AtlasRGB(red: 0.43, green: 0.61, blue: 1.0),
    gain: AtlasRGB(red: 0.30, green: 0.82, blue: 0.54),
    loss: AtlasRGB(red: 1.0, green: 0.43, blue: 0.47),
    warning: AtlasRGB(red: 0.97, green: 0.67, blue: 0.25)
  )

  static let highContrastLightPalette = AtlasPalette(
    paper: AtlasRGB(red: 1, green: 1, blue: 1),
    paper2: AtlasRGB(red: 0.96, green: 0.96, blue: 0.96),
    paper3: AtlasRGB(red: 0.90, green: 0.90, blue: 0.90),
    ink: AtlasRGB(red: 0, green: 0, blue: 0),
    ink2: AtlasRGB(red: 0.12, green: 0.12, blue: 0.12),
    ink3: AtlasRGB(red: 0.22, green: 0.22, blue: 0.22),
    rule: AtlasRGB(red: 0.18, green: 0.18, blue: 0.18),
    ruleSoft: AtlasRGB(red: 0.35, green: 0.35, blue: 0.35),
    controlBoundary: AtlasRGB(red: 0, green: 0, blue: 0),
    controlBoundaryDisabled: AtlasRGB(red: 0.18, green: 0.18, blue: 0.18),
    focusRing: AtlasRGB(red: 0, green: 0.20, blue: 0.65),
    accent: AtlasRGB(red: 0, green: 0.20, blue: 0.65),
    gain: AtlasRGB(red: 0, green: 0.34, blue: 0.10),
    loss: AtlasRGB(red: 0.68, green: 0, blue: 0),
    warning: AtlasRGB(red: 0.45, green: 0.20, blue: 0)
  )

  static let highContrastDarkPalette = AtlasPalette(
    paper: AtlasRGB(red: 0, green: 0, blue: 0),
    paper2: AtlasRGB(red: 0.04, green: 0.04, blue: 0.04),
    paper3: AtlasRGB(red: 0.10, green: 0.10, blue: 0.10),
    ink: AtlasRGB(red: 1, green: 1, blue: 1),
    ink2: AtlasRGB(red: 0.90, green: 0.90, blue: 0.90),
    ink3: AtlasRGB(red: 0.78, green: 0.78, blue: 0.78),
    rule: AtlasRGB(red: 0.82, green: 0.82, blue: 0.82),
    ruleSoft: AtlasRGB(red: 0.62, green: 0.62, blue: 0.62),
    controlBoundary: AtlasRGB(red: 1, green: 1, blue: 1),
    controlBoundaryDisabled: AtlasRGB(red: 0.82, green: 0.82, blue: 0.82),
    focusRing: AtlasRGB(red: 0.50, green: 0.80, blue: 1),
    accent: AtlasRGB(red: 0.50, green: 0.80, blue: 1),
    gain: AtlasRGB(red: 0.52, green: 1, blue: 0.62),
    loss: AtlasRGB(red: 1, green: 0.52, blue: 0.48),
    warning: AtlasRGB(red: 1, green: 0.78, blue: 0.32)
  )

  static let paperRGB = lightPalette.paper
  static let paper2RGB = lightPalette.paper2
  static let ink3RGB = lightPalette.ink3
  static let warningRGB = lightPalette.warning

  static let paper = dynamicColor("paper", \.paper)
  static let paper2 = dynamicColor("paper2", \.paper2)
  static let paper3 = dynamicColor("paper3", \.paper3)
  static let ink = dynamicColor("ink", \.ink)
  static let ink2 = dynamicColor("ink2", \.ink2)
  static let ink3 = dynamicColor("ink3", \.ink3)
  static let rule = dynamicColor("rule", \.rule)
  static let ruleSoft = dynamicColor("ruleSoft", \.ruleSoft)
  static let accent = dynamicColor("accent", \.accent)
  static let gain = dynamicColor("gain", \.gain)
  static let loss = dynamicColor("loss", \.loss)
  /// Dark enough for normal-size warning text on each supported surface.
  static let warning = dynamicColor("warning", \.warning)

  static let canvas = paper
  static let surface = paper2
  static let surfaceMuted = paper3

  static func palette(for appearance: AtlasAppearanceVariant) -> AtlasPalette {
    switch appearance {
    case .light: lightPalette
    case .dark: darkPalette
    case .highContrastLight: highContrastLightPalette
    case .highContrastDark: highContrastDarkPalette
    }
  }

  private static func dynamicColor(
    _ name: String,
    _ keyPath: KeyPath<AtlasPalette, AtlasRGB>
  ) -> Color {
    Color(
      nsColor: NSColor(name: NSColor.Name("AddressAtlas.\(name)")) { appearance in
        palette(
          for: AtlasAppearanceVariant(
            appearance: appearance,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
          ))[keyPath: keyPath].nsColor
      })
  }
}

enum AtlasRadius {
  static let small: CGFloat = 8
  static let control: CGFloat = 10
  static let card: CGFloat = 14
  static let large: CGFloat = 20
}

enum AtlasMotion {
  static let quick = Animation.easeOut(duration: 0.16)
  static let standard = Animation.spring(response: 0.34, dampingFraction: 0.86)

  static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : animation
  }
}

struct Page<Content: View>: View {
  @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 42
  var eyebrow: String
  var title: String
  var subtitle: String
  var statTitle: String
  var statValue: String
  var content: Content

  init(
    eyebrow: String,
    title: String,
    subtitle: String,
    statTitle: String,
    statValue: String,
    @ViewBuilder content: () -> Content
  ) {
    self.eyebrow = eyebrow
    self.title = title
    self.subtitle = subtitle
    self.statTitle = statTitle
    self.statValue = statValue
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      StatusLine(presentation: .pinned)

      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 32) {
              heading(lineLimit: 1)
              Spacer()
              headerStat
                .frame(minWidth: 180, alignment: .trailing)
            }
            .frame(minWidth: 720)

            VStack(alignment: .leading, spacing: 16) {
              heading(lineLimit: 2)
              headerStat
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(.bottom, 6)

          content
        }
        .padding(.horizontal, 32)
        .padding(.top, 30)
        .padding(.bottom, 44)
        .frame(maxWidth: 1280, alignment: .leading)
      }
      .scrollContentBackground(.hidden)
    }
    .background(
      LinearGradient(
        colors: [AtlasTheme.canvas, AtlasTheme.surfaceMuted.opacity(0.22)],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  private func heading(lineLimit: Int) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(eyebrow)
        .font(.caption.weight(.semibold))
        .foregroundStyle(AtlasTheme.accent)
      Text(title)
        .font(.system(size: titleSize, weight: .bold, design: .rounded))
        .tracking(-1.1)
        .lineLimit(lineLimit)
        .minimumScaleFactor(0.7)
      Text(subtitle)
        .font(.body)
        .foregroundStyle(AtlasTheme.ink2)
        .lineSpacing(2)
        .frame(maxWidth: 680, alignment: .leading)
    }
  }

  private var headerStat: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(statTitle)
        .font(.caption.weight(.medium))
        .foregroundStyle(AtlasTheme.ink3)
      Text(statValue)
        .font(.callout.monospacedDigit().weight(.semibold))
        .foregroundStyle(AtlasTheme.ink)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(AtlasTheme.surface)
    .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
        .stroke(AtlasTheme.ruleSoft, lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
  }
}

enum AtlasSurfaceStyle {
  case standard
  case subtle
  case accent
  case warning
  case danger
}

struct Surface<Content: View>: View {
  @Environment(\.colorSchemeContrast) private var contrast
  var padding: CGFloat
  var style: AtlasSurfaceStyle
  var content: Content

  init(
    padding: CGFloat = 20,
    style: AtlasSurfaceStyle = .standard,
    @ViewBuilder content: () -> Content
  ) {
    self.padding = padding
    self.style = style
    self.content = content()
  }

  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(background)
      .foregroundStyle(AtlasTheme.ink)
      .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous)
          .stroke(border, lineWidth: contrast == .increased ? 2 : 1)
      }
      .shadow(
        color: contrast == .increased ? .clear : .black.opacity(style == .standard ? 0.07 : 0.035),
        radius: style == .standard ? 12 : 6,
        y: style == .standard ? 4 : 2
      )
  }

  private var background: Color {
    switch style {
    case .standard: AtlasTheme.surface
    case .subtle: AtlasTheme.surfaceMuted.opacity(0.48)
    case .accent: AtlasTheme.accent.opacity(0.09)
    case .warning: AtlasTheme.warning.opacity(0.09)
    case .danger: AtlasTheme.loss.opacity(0.08)
    }
  }

  private var border: Color {
    switch style {
    case .standard, .subtle: AtlasTheme.ruleSoft
    case .accent: AtlasTheme.accent.opacity(0.30)
    case .warning: AtlasTheme.warning.opacity(0.34)
    case .danger: AtlasTheme.loss.opacity(0.34)
    }
  }
}

/// Keeps dense control groups horizontal when their intrinsic content fits,
/// then exposes the same controls as a readable vertical stack in a narrow
/// window or at larger accessibility text sizes.
struct AdaptiveStack<Content: View>: View {
  var horizontalSpacing: CGFloat
  var verticalSpacing: CGFloat
  @ViewBuilder var content: () -> Content

  init(
    horizontalSpacing: CGFloat = 10,
    verticalSpacing: CGFloat = 10,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.horizontalSpacing = horizontalSpacing
    self.verticalSpacing = verticalSpacing
    self.content = content
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: horizontalSpacing) {
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: verticalSpacing) {
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct SectionHeader: View {
  var title: String
  var meta: String

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 14) {
        headerTitle
        Spacer(minLength: 16)
        headerMeta
      }
      VStack(alignment: .leading, spacing: 3) {
        headerTitle
        headerMeta
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var headerTitle: some View {
    Text(title)
      .font(.headline.weight(.semibold))
      .foregroundStyle(AtlasTheme.ink)
      .accessibilityAddTraits(.isHeader)
  }

  private var headerMeta: some View {
    Text(meta)
      .font(.caption)
      .foregroundStyle(AtlasTheme.ink3)
  }
}

struct AtlasLabel: View {
  var text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(.caption.weight(.semibold))
      .foregroundStyle(AtlasTheme.ink3)
  }
}

struct Badge: View {
  var text: String
  var color: Color

  init(_ text: String, color: Color = AtlasTheme.ink3) {
    self.text = text
    self.color = color
  }

  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .frame(minHeight: 24)
      .background(color.opacity(0.11))
      .clipShape(Capsule())
      .overlay(Capsule().stroke(color.opacity(0.28), lineWidth: 1))
  }
}

struct TableHeader: View {
  var text: String
  var alignment: Alignment
  var width: CGFloat?

  init(_ text: String, alignment: Alignment = .leading, width: CGFloat? = nil) {
    self.text = text
    self.alignment = alignment
    self.width = width
  }

  var body: some View {
    Text(text)
      .font(.caption.weight(.semibold))
      .foregroundStyle(AtlasTheme.ink3)
      .frame(width: width, alignment: alignment)
      .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
  }
}

struct KeyValueGrid: View {
  var rows: [(String, String)]

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
        HStack(alignment: .firstTextBaseline, spacing: 16) {
          Text(row.0)
            .font(.callout.weight(.medium))
            .foregroundStyle(AtlasTheme.ink3)
            .frame(width: 160, alignment: .leading)
          Text(row.1)
            .font(.callout)
            .foregroundStyle(AtlasTheme.ink2)
            .textSelection(.enabled)
          Spacer()
        }
        .padding(.vertical, 11)
        if index != rows.count - 1 {
          Divider().overlay(AtlasTheme.ruleSoft)
        }
      }
    }
  }
}

struct EmptyState: View {
  var title: String
  var systemImage: String
  var copy: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.title3.weight(.semibold))
        .foregroundStyle(AtlasTheme.accent)
        .frame(width: 46, height: 46)
        .background(AtlasTheme.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
      Text(title)
        .font(.title3.weight(.semibold))
      Text(copy)
        .font(.callout)
        .foregroundStyle(AtlasTheme.ink3)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(40)
    .background(AtlasTheme.surfaceMuted.opacity(0.38))
    .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous)
        .stroke(AtlasTheme.ruleSoft, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
    }
  }
}

struct BrandLockup: View {
  var body: some View {
    HStack(spacing: 11) {
      ZStack {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .fill(
            LinearGradient(
              colors: [AtlasTheme.accent, AtlasTheme.accent.opacity(0.72)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ))
        Image(systemName: "map.fill")
          .font(.body.weight(.semibold))
          .foregroundStyle(AtlasTheme.paper)
      }
      .frame(width: 38, height: 38)
      .shadow(color: AtlasTheme.accent.opacity(0.22), radius: 8, y: 3)

      VStack(alignment: .leading, spacing: 2) {
        Text("Address Atlas")
          .font(.headline.weight(.semibold))
        Text("Private portfolio map")
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

struct SidebarTrustLine: View {
  var title: String
  var copy: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "checkmark.circle.fill")
        .font(.callout)
        .foregroundStyle(AtlasTheme.gain)
        .padding(.top, 1)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout.weight(.medium))
        Text(copy)
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

struct FieldLabel: View {
  var title: String
  var detail: String?

  init(_ title: String, detail: String? = nil) {
    self.title = title
    self.detail = detail
  }

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
        .font(.callout.weight(.medium))
        .foregroundStyle(AtlasTheme.ink2)
      if let detail {
        Text(detail)
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
      }
    }
  }
}

enum AtlasCalloutTone {
  case info
  case success
  case warning
  case danger

  var icon: String {
    switch self {
    case .info: "info.circle.fill"
    case .success: "checkmark.shield.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .danger: "exclamationmark.octagon.fill"
    }
  }

  var color: Color {
    switch self {
    case .info: AtlasTheme.accent
    case .success: AtlasTheme.gain
    case .warning: AtlasTheme.warning
    case .danger: AtlasTheme.loss
    }
  }
}

struct InfoCallout: View {
  var title: String
  var copy: String
  var tone: AtlasCalloutTone = .info

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: tone.icon)
        .font(.body)
        .foregroundStyle(tone.color)
        .padding(.top, 1)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.callout.weight(.semibold))
        Text(copy)
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink2)
          .lineSpacing(2)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tone.color.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
        .stroke(tone.color.opacity(0.22), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
  }
}

struct PanelHeader: View {
  var title: String
  var subtitle: String
  var systemImage: String
  var tint: Color = AtlasTheme.accent

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.body.weight(.semibold))
        .foregroundStyle(tint)
        .frame(width: 36, height: 36)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline.weight(.semibold))
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink3)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}

struct PrivacyCard: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 9) {
        Image(systemName: "lock.shield.fill")
          .foregroundStyle(AtlasTheme.gain)
          .frame(width: 28, height: 28)
          .background(AtlasTheme.gain.opacity(0.10))
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        VStack(alignment: .leading, spacing: 1) {
          Text("Private by design")
            .font(.callout.weight(.semibold))
          Text("Encrypted on this Mac")
            .font(.caption)
            .foregroundStyle(AtlasTheme.ink3)
        }
      }
      Text("Credentials and portfolio data stay encrypted before storage or sync.")
        .font(.caption)
        .foregroundStyle(AtlasTheme.ink3)
        .lineSpacing(2)
    }
    .padding(14)
    .background(AtlasTheme.surfaceMuted.opacity(0.44))
    .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous)
        .stroke(AtlasTheme.ruleSoft, lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
  }
}

/// Posts dynamic status changes through AppKit's application-level
/// announcement channel. A process-wide active-message registry prevents a
/// newly installed SwiftUI page from repeating the same still-visible status,
/// while a fresh publication of that status remains announceable after clear.
@MainActor
final class AtlasAccessibilityAnnouncer {
  enum Kind: Hashable {
    case operatorMessage
    case guidance
    case notice
    case error

    var prefix: String {
      switch self {
      case .operatorMessage: "Sync server message"
      case .guidance: "Action required"
      case .notice: "Status"
      case .error: "Error"
      }
    }

    var priority: NSAccessibilityPriorityLevel {
      switch self {
      case .operatorMessage, .notice: .medium
      case .guidance, .error: .high
      }
    }
  }

  typealias Clock = @MainActor () -> TimeInterval
  typealias Poster = @MainActor (String, NSAccessibilityPriorityLevel) -> Void

  static let shared = AtlasAccessibilityAnnouncer()

  private struct RecentAnnouncement {
    var message: String
    var postedAt: TimeInterval
  }

  private let duplicateCoalescingInterval: TimeInterval
  private let now: Clock
  private let poster: Poster
  private var activeMessages: [Kind: String] = [:]
  private var recentAnnouncements: [Kind: RecentAnnouncement] = [:]

  init(
    duplicateCoalescingInterval: TimeInterval = 0.75,
    now: @escaping Clock = { ProcessInfo.processInfo.systemUptime },
    poster: @escaping Poster = AtlasAccessibilityAnnouncer.postToAppKit
  ) {
    self.duplicateCoalescingInterval = duplicateCoalescingInterval
    self.now = now
    self.poster = poster
  }

  /// Use for a view's initial snapshot. Recreated pages do not repeat a status
  /// that the same application process already announced and still presents.
  func announceVisible(_ message: String, kind: Kind) {
    guard let spokenMessage = normalizedSpokenMessage(message, kind: kind) else {
      clear(kind)
      return
    }
    guard activeMessages[kind] != spokenMessage else { return }
    activeMessages[kind] = spokenMessage
    post(spokenMessage, kind: kind)
  }

  /// Use for a Published state event. Two simultaneously installed views are
  /// coalesced, but the same legitimate result can be announced again later.
  func announceEvent(_ message: String, kind: Kind) {
    guard let spokenMessage = normalizedSpokenMessage(message, kind: kind) else {
      clear(kind)
      return
    }
    let wasAlreadyActive = activeMessages[kind] == spokenMessage
    activeMessages[kind] = spokenMessage
    if wasAlreadyActive,
      let recent = recentAnnouncements[kind],
      recent.message == spokenMessage,
      now() - recent.postedAt < duplicateCoalescingInterval
    {
      return
    }
    post(spokenMessage, kind: kind)
  }

  func clear(_ kind: Kind) {
    activeMessages.removeValue(forKey: kind)
  }

  private func normalizedSpokenMessage(_ message: String, kind: Kind) -> String? {
    let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    return "\(kind.prefix): \(normalized)"
  }

  private func post(_ message: String, kind: Kind) {
    recentAnnouncements[kind] = RecentAnnouncement(message: message, postedAt: now())
    poster(message, kind.priority)
  }

  private static func postToAppKit(
    _ message: String,
    priority: NSAccessibilityPriorityLevel
  ) {
    NSAccessibility.post(
      element: NSApplication.shared,
      notification: .announcementRequested,
      userInfo: [
        .announcement: message,
        .priority: priority.rawValue,
      ]
    )
  }
}

struct StatusLine: View {
  enum Presentation {
    case inline
    case pinned
  }

  @EnvironmentObject private var state: AppState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var presentation: Presentation = .inline

  private var hasVisibleContent: Bool {
    state.operatorMessage != nil || state.persistentOperationGuidance != nil
      || !state.notice.isEmpty || !state.error.isEmpty || !state.isAppVersionSupported
  }

  @ViewBuilder
  var body: some View {
    Group {
      if hasVisibleContent {
        VStack(alignment: .leading, spacing: 8) {
          if let operatorMessage = state.operatorMessage {
            HStack(spacing: 8) {
              Image(systemName: "info.circle")
              Text(operatorMessage)
            }
            .foregroundStyle(AtlasTheme.accent)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sync server message: \(operatorMessage)")
          }
          if let persistentGuidance = state.persistentOperationGuidance {
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: "exclamationmark.shield")
              Text(persistentGuidance)
            }
            .foregroundStyle(AtlasTheme.warning)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Action required: \(persistentGuidance)")
          }
          if !state.notice.isEmpty {
            HStack(spacing: 8) {
              Image(systemName: "checkmark.circle")
              Text(state.notice)
            }
            .foregroundStyle(AtlasTheme.gain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Status: \(state.notice)")
          }
          if !state.error.isEmpty {
            HStack(spacing: 8) {
              Image(systemName: "exclamationmark.triangle")
              Text(state.error)
            }
            .foregroundStyle(AtlasTheme.loss)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Error: \(state.error)")
          }
          if !state.isAppVersionSupported {
            Link(destination: state.safeUpdateDownloadURL) {
              Label(
                "Download the latest signed Address Atlas release",
                systemImage: "arrow.down.circle"
              )
            }
            .accessibilityHint(
              "Opens the hard-pinned Address Atlas releases page in your browser")
          }
        }
        .font(.callout)
        .padding(.horizontal, presentation == .pinned ? 16 : 0)
        .padding(.vertical, presentation == .pinned ? 13 : 0)
        .frame(maxWidth: presentation == .pinned ? .infinity : nil, alignment: .leading)
        .background {
          if presentation == .pinned {
            RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
              .fill(AtlasTheme.surface)
          }
        }
        .overlay {
          if presentation == .pinned {
            RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
              .stroke(AtlasTheme.ruleSoft, lineWidth: 1)
          }
        }
        .padding(.horizontal, presentation == .pinned ? 24 : 0)
        .padding(.top, presentation == .pinned ? 12 : 0)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(100)
      }
    }
    .onAppear(perform: announceVisibleMessages)
    .onReceive(state.$notice.dropFirst()) { message in
      AtlasAccessibilityAnnouncer.shared.announceEvent(message, kind: .notice)
    }
    .onReceive(state.$error.dropFirst()) { message in
      AtlasAccessibilityAnnouncer.shared.announceEvent(message, kind: .error)
    }
    .onChange(of: state.operatorMessage) { _, message in
      announceEvent(message, kind: .operatorMessage)
    }
    .onChange(of: state.persistentOperationGuidance) { _, message in
      announceEvent(message, kind: .guidance)
    }
    .animation(
      AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
      value: hasVisibleContent
    )
  }

  private func announceVisibleMessages() {
    announceVisible(state.operatorMessage, kind: .operatorMessage)
    announceVisible(state.persistentOperationGuidance, kind: .guidance)
    announceVisible(state.notice, kind: .notice)
    announceVisible(state.error, kind: .error)
  }

  private func announceVisible(
    _ message: String?,
    kind: AtlasAccessibilityAnnouncer.Kind
  ) {
    if let message {
      AtlasAccessibilityAnnouncer.shared.announceVisible(message, kind: kind)
    } else {
      AtlasAccessibilityAnnouncer.shared.clear(kind)
    }
  }

  private func announceEvent(
    _ message: String?,
    kind: AtlasAccessibilityAnnouncer.Kind
  ) {
    if let message {
      AtlasAccessibilityAnnouncer.shared.announceEvent(message, kind: kind)
    } else {
      AtlasAccessibilityAnnouncer.shared.clear(kind)
    }
  }
}

enum AtlasControlKind: Equatable, Sendable {
  case textField
  case secondaryButton
}

struct AtlasControlVisualState: Equatable, Sendable {
  var isEnabled: Bool
  var isPressed: Bool
  var isFocused: Bool
}

struct AtlasControlStyleTokens: Equatable, Sendable {
  let foreground: AtlasRGB
  let background: AtlasRGB
  let boundary: AtlasRGB
  let focusRing: AtlasRGB
  let boundaryWidth: Double
  let focusRingWidth: Double
  let focusRingOutset: Double
}

enum AtlasControlStyleResolver {
  static func tokens(
    for kind: AtlasControlKind,
    appearance: AtlasAppearanceVariant,
    state: AtlasControlVisualState
  ) -> AtlasControlStyleTokens {
    let palette = AtlasTheme.palette(for: appearance)
    let foreground: AtlasRGB
    let boundary: AtlasRGB

    if state.isEnabled {
      foreground = kind == .secondaryButton && state.isPressed ? palette.accent : palette.ink
      boundary =
        kind == .secondaryButton && state.isPressed
        ? palette.accent
        : palette.controlBoundary
    } else {
      foreground = palette.ink3
      boundary = palette.controlBoundaryDisabled
    }

    return AtlasControlStyleTokens(
      foreground: foreground,
      background: state.isEnabled ? palette.paper2 : palette.paper3,
      boundary: boundary,
      focusRing: palette.focusRing,
      boundaryWidth: appearance == .highContrastLight || appearance == .highContrastDark ? 2 : 1.5,
      focusRingWidth: state.isEnabled && state.isFocused ? 3 : 0,
      focusRingOutset: 3
    )
  }
}

private struct AtlasControlOutline: View {
  let tokens: AtlasControlStyleTokens

  var body: some View {
    RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
      .stroke(tokens.boundary.color, lineWidth: tokens.boundaryWidth)
      .overlay {
        if tokens.focusRingWidth > 0 {
          RoundedRectangle(cornerRadius: AtlasRadius.control + 2, style: .continuous)
            .stroke(tokens.focusRing.color, lineWidth: tokens.focusRingWidth)
            .padding(-tokens.focusRingOutset)
            .accessibilityHidden(true)
        }
      }
      .accessibilityHidden(true)
  }
}

struct AtlasTextFieldStyle: TextFieldStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  func _body(configuration: TextField<Self._Label>) -> some View {
    let tokens = AtlasControlStyleResolver.tokens(
      for: .textField,
      appearance: AtlasAppearanceVariant(
        colorScheme: colorScheme,
        contrast: colorSchemeContrast
      ),
      state: AtlasControlVisualState(
        isEnabled: isEnabled,
        isPressed: false,
        isFocused: isFocused
      )
    )

    configuration
      .textFieldStyle(.plain)
      .foregroundStyle(tokens.foreground.color)
      .padding(.horizontal, 13)
      .padding(.vertical, 10)
      .frame(minHeight: 42)
      .background(tokens.background.color)
      .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
      .overlay(AtlasControlOutline(tokens: tokens))
  }
}

struct AtlasPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.semibold))
      .foregroundStyle(isEnabled ? AtlasTheme.paper : AtlasTheme.ink3)
      .padding(.horizontal, 16)
      .frame(minHeight: 42)
      .background(
        isEnabled
          ? AtlasTheme.accent.opacity(configuration.isPressed ? 0.82 : 1)
          : AtlasTheme.surfaceMuted
      )
      .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
          .stroke(isEnabled ? AtlasTheme.accent.opacity(0.25) : AtlasTheme.ruleSoft, lineWidth: 1)
          .overlay {
            if isEnabled && isFocused {
              RoundedRectangle(cornerRadius: AtlasRadius.control + 2, style: .continuous)
                .stroke(AtlasTheme.accent, lineWidth: 3)
                .padding(-3)
                .accessibilityHidden(true)
            }
          }
      }
      .shadow(
        color: isEnabled
          ? AtlasTheme.accent.opacity(configuration.isPressed ? 0.08 : 0.18) : .clear,
        radius: configuration.isPressed ? 2 : 7,
        y: configuration.isPressed ? 1 : 3
      )
      .contentShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
      .scaleEffect(configuration.isPressed && isEnabled ? 0.985 : 1)
      .opacity(isEnabled ? 1 : 0.72)
      .animation(
        AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
        value: configuration.isPressed
      )
  }
}

struct AtlasSecondaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    let tokens = AtlasControlStyleResolver.tokens(
      for: .secondaryButton,
      appearance: AtlasAppearanceVariant(
        colorScheme: colorScheme,
        contrast: colorSchemeContrast
      ),
      state: AtlasControlVisualState(
        isEnabled: isEnabled,
        isPressed: configuration.isPressed,
        isFocused: isFocused
      )
    )

    configuration.label
      .font(.callout.weight(.medium))
      .foregroundStyle(tokens.foreground.color)
      .padding(.horizontal, 14)
      .frame(minHeight: 40)
      .background(tokens.background.color)
      .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
      .overlay(AtlasControlOutline(tokens: tokens))
      .contentShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
      .scaleEffect(configuration.isPressed && isEnabled ? 0.985 : 1)
      .animation(
        AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
        value: configuration.isPressed
      )
  }
}

struct SidebarButtonStyle: ButtonStyle {
  @Environment(\.isFocused) private var isFocused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var active: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(active ? .semibold : .medium))
      .foregroundStyle(active ? AtlasTheme.paper : AtlasTheme.ink2)
      .background(
        active
          ? AtlasTheme.accent
          : (configuration.isPressed ? AtlasTheme.surfaceMuted.opacity(0.75) : Color.clear)
      )
      .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
      .overlay {
        if isFocused {
          RoundedRectangle(cornerRadius: AtlasRadius.control + 2, style: .continuous)
            .stroke(AtlasTheme.accent, lineWidth: 3)
            .padding(-3)
            .accessibilityHidden(true)
        }
      }
      .shadow(color: active ? AtlasTheme.accent.opacity(0.16) : .clear, radius: 6, y: 2)
      .scaleEffect(configuration.isPressed ? 0.99 : 1)
      .animation(
        AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
        value: configuration.isPressed
      )
  }
}

struct IconButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout)
      .foregroundStyle(
        isEnabled
          ? (configuration.isPressed
            ? (configuration.role == .destructive ? AtlasTheme.loss : AtlasTheme.accent)
            : AtlasTheme.ink3)
          : AtlasTheme.rule
      )
      .frame(width: 34, height: 34)
      .background(
        configuration.isPressed
          ? (configuration.role == .destructive
            ? AtlasTheme.loss.opacity(0.09) : AtlasTheme.accent.opacity(0.09))
          : Color.clear
      )
      .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous))
      .overlay {
        if isFocused {
          RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous)
            .stroke(AtlasTheme.accent, lineWidth: 3)
            .accessibilityHidden(true)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous))
      .opacity(isEnabled ? 1 : 0.55)
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .animation(
        AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
        value: configuration.isPressed
      )
  }
}

enum AtlasAccessibility {
  static func walletIdentity(_ wallet: WalletRecord) -> String {
    "\(wallet.label), \(wallet.chainKind.rawValue), address \(wallet.address)"
  }

  static func tokenIdentity(_ token: CustomTokenRecord) -> String {
    "\(token.symbol), \(token.chainId), address \(token.address)"
  }

  static func manualHoldingIdentity(_ holding: ManualHoldingRecord) -> String {
    "\(holding.symbol), \(holding.label), record ID \(holding.id.uuidString.lowercased())"
  }

  static func exchangeIdentity(_ connection: ExchangeConnectionRecord) -> String {
    "\(connection.label), \(connection.provider.label), record ID \(connection.id.uuidString.lowercased())"
  }

  static func snapshotIdentity(_ run: ScanRunRecord) -> String {
    "\(run.generatedAt.formatted(date: .abbreviated, time: .shortened)), record ID \(run.id.uuidString.lowercased())"
  }

  static func assetRowIdentity(_ asset: TrackedAsset) -> String {
    let valuation =
      switch asset.pricingStatus {
      case .priced: "known value \(money(asset.valueUsd))"
      case .unpriced: "unpriced, USD value unknown"
      case .valuationUnavailable: "price known, USD value unavailable"
      }
    return
      "\(asset.symbol), \(asset.name), \(asset.chainName), source \(asset.source.rawValue), amount \(asset.canonicalAmount), \(valuation)"
  }
}

func money(_ value: Double) -> String {
  value.formatted(.currency(code: "USD"))
}
