import AddressAtlasCore
import SwiftUI

// Themed building blocks for the iOS screens. Everything here reads fonts,
// shapes and colours from the selected theme (`AtlasTheme`, `\.atlasTheme`),
// never from literals, so each theme draws its own cards, chips and tab bar.

// MARK: - Navigation title

extension View {
  /// An inline navigation title in the theme's display font. A system large
  /// title cannot take a theme font and does not follow a live theme change.
  func iosTitle(_ title: String) -> some View {
    navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(AtlasTheme.canvas, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .principal) {
          Text(title)
            .font(AtlasTheme.font(.display, .headline))
            .tracking(AtlasTheme.tracking(.display, size: 17))
            .foregroundStyle(AtlasTheme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityAddTraits(.isHeader)
        }
      }
  }
}

// MARK: - Cards

/// A padded card with the theme's border, corner radius and shadow. Pass
/// `fill` for a tinted card (the portfolio total uses the theme's pastel).
struct IOSCard<Content: View>: View {
  var padding: CGFloat = 16
  var fill: Color?
  var ink: Color?
  var content: Content

  init(
    padding: CGFloat = 16,
    fill: Color? = nil,
    ink: Color? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.padding = padding
    self.fill = fill
    self.ink = ink
    self.content = content()
  }

  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .foregroundStyle(ink ?? AtlasTheme.ink)
      .iosCardSurface(fill: fill)
  }
}

extension View {
  /// The theme's card chrome (fill, border, corner radius, shadow) around
  /// content that already has its own padding.
  func iosCardSurface(fill: Color? = nil, radius: CGFloat? = nil) -> some View {
    atlasChrome(
      fill: fill ?? AtlasTheme.surface,
      border: AtlasTheme.outline,
      level: .card,
      radius: radius ?? AtlasRadius.card
    )
  }

  /// Row chrome for a `List` that draws each row as its own card. Put the
  /// result on the row; put `iosCardSurface` on the row's content so the
  /// whole card is the tap target.
  func iosListRow() -> some View {
    listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 10, trailing: 22))
  }
}

/// The ink and fill of the portfolio's lead card in the current theme.
struct IOSHeroStyle {
  var fill: Color
  var ink: Color
  var secondaryInk: Color
  var isTinted: Bool

  static func current(_ tokens: AtlasThemeTokens, index: Int = 0) -> IOSHeroStyle {
    if tokens.shape.cardFill == .pastel {
      let pastel = tokens.chart.pastel(at: index)
      return IOSHeroStyle(
        fill: pastel.color,
        ink: tokens.palette.onPastel.color,
        secondaryInk: tokens.palette.onPastel.color.opacity(0.78),
        isTinted: true
      )
    }
    return IOSHeroStyle(
      fill: tokens.palette.surface.color,
      ink: tokens.palette.ink.color,
      secondaryInk: tokens.palette.ink3.color,
      isTinted: false
    )
  }
}

// MARK: - Section titles

struct IOSSectionTitle: View {
  var text: String
  var trailing: AnyView?

  init(_ text: String) {
    self.text = text
    trailing = nil
  }

  init<Trailing: View>(_ text: String, @ViewBuilder trailing: () -> Trailing) {
    self.text = text
    self.trailing = AnyView(trailing())
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(text)
        .font(AtlasTheme.font(.display, .title3))
        .tracking(AtlasTheme.tracking(.display, size: 20))
        .foregroundStyle(AtlasTheme.ink)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 8)
      trailing
    }
    .frame(minHeight: 32)
  }
}

// MARK: - Chips

/// A selectable pill or tag (the portfolio view switcher, the Sources
/// switcher). Selected chips use the theme's selection colours and, in the
/// hard-edged themes, its outline and offset shadow.
struct IOSChip: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var title: String
  var systemImage: String?
  var isSelected: Bool
  var action: () -> Void

  init(_ title: String, systemImage: String? = nil, isSelected: Bool, action: @escaping () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.isSelected = isSelected
    self.action = action
  }

  var body: some View {
    let shape = AtlasTheme.shape
    Button(action: action) {
      HStack(spacing: 6) {
        if let systemImage {
          Image(systemName: systemImage)
            .font(.footnote.weight(.semibold))
            .accessibilityHidden(true)
        }
        Text(title)
          .font(AtlasTheme.font(.label, .subheadline, weight: .semibold))
          .lineLimit(1)
      }
      .foregroundStyle(isSelected ? AtlasTheme.onSelection : AtlasTheme.ink2)
      .padding(.horizontal, 14)
      .frame(minHeight: 36)
      .atlasChrome(
        fill: isSelected ? AtlasTheme.selection : AtlasTheme.surface,
        border: isSelected ? AtlasTheme.outline : AtlasTheme.controlBoundary.opacity(0.55),
        level: .control,
        borderWidth: isSelected
          ? max(shape.controlBorderWidth, 1.5) : (shape.hasBoldBorders ? 1.5 : 1),
        showsShadow: isSelected
      )
      // Hard shadows need room to the right and below.
      .padding(.trailing, isSelected ? (shape.controlShadowOffset?.width ?? 0) : 0)
      .padding(.bottom, isSelected ? (shape.controlShadowOffset?.height ?? 0) : 0)
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}

// MARK: - Notices

/// A plain statement next to the data it is about: a warning, a changed
/// source, being offline. No title line; the sentence is the message.
struct IOSNotice: View {
  var systemImage: String
  var text: String
  var tone: AtlasCalloutTone = .warning

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: systemImage)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(tone.color)
        .accessibilityHidden(true)
      Text(text)
        .font(AtlasTheme.font(.body, .callout))
        .foregroundStyle(AtlasTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .atlasChrome(
      fill: tone.softFill,
      border: AtlasTheme.shape.hasBoldBorders ? AtlasTheme.outline : tone.color.opacity(0.32),
      level: .control,
      radius: AtlasRadius.control,
      borderWidth: AtlasTheme.shape.hasBoldBorders ? AtlasTheme.shape.controlBorderWidth : 1,
      showsShadow: false
    )
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Empty state

/// An invitation, not an error: what is missing and the one thing to do.
struct IOSEmptyState: View {
  var systemImage: String
  var title: String
  var copy: String
  var actionTitle: String?
  var secondaryTitle: String?
  var showsProgress = false
  var action: () -> Void = {}
  var secondaryAction: () -> Void = {}

  var body: some View {
    VStack(spacing: 14) {
      ZStack {
        if showsProgress {
          ProgressView()
        } else {
          Image(systemName: systemImage)
            .font(.title2.weight(.semibold))
            .foregroundStyle(AtlasTheme.accent)
        }
      }
      .frame(width: 56, height: 56)
      .background(AtlasTheme.accentSoft)
      .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
      .accessibilityHidden(true)
      VStack(spacing: 6) {
        Text(title)
          .font(AtlasTheme.font(.display, .title3))
          .foregroundStyle(AtlasTheme.ink)
          .accessibilityAddTraits(.isHeader)
        Text(copy)
          .font(AtlasTheme.font(.body, .callout))
          .foregroundStyle(AtlasTheme.ink2)
      }
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      if let actionTitle {
        Button(action: action) {
          Text(actionTitle).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        .padding(.top, 4)
      }
      if let secondaryTitle {
        Button(action: secondaryAction) {
          Text(secondaryTitle).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
      }
    }
    .frame(maxWidth: 420)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 28)
    .padding(.horizontal, 20)
  }
}

// MARK: - Tab bar

/// The bottom bar. The system tab bar takes no theme font or shape, so the
/// shell hides it and draws this one: ruled in hard-edged themes, a filled
/// selection pill in all of them.
struct IOSTabBar: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.colorSchemeContrast) private var contrast
  var selection: AtlasSection
  var select: (AtlasSection) -> Void

  var body: some View {
    let shape = AtlasTheme.shape
    HStack(spacing: 2) {
      ForEach(AtlasSection.allCases) { section in
        item(section, shape: shape)
      }
    }
    .padding(.horizontal, 8)
    .padding(.top, 8)
    .padding(.bottom, 6)
    .background(alignment: .top) {
      AtlasTheme.surface
        .overlay(alignment: .top) {
          Rectangle()
            .fill(shape.hasBoldBorders ? AtlasTheme.outline : AtlasTheme.ruleSoft)
            .frame(height: shape.hasBoldBorders || contrast == .increased ? 2 : 1)
        }
        .ignoresSafeArea(edges: .bottom)
    }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isTabBar)
  }

  private func item(_ section: AtlasSection, shape: AtlasShape) -> some View {
    let isSelected = selection == section
    return Button {
      select(section)
    } label: {
      VStack(spacing: 3) {
        Image(systemName: section.systemImage)
          .font(.system(size: 18, weight: .semibold))
          .dynamicTypeSize(...DynamicTypeSize.accessibility1)
          .accessibilityHidden(true)
        Text(section.title)
          .font(AtlasTheme.font(.label, .caption2, weight: .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
      .foregroundStyle(isSelected ? AtlasTheme.onSelection : AtlasTheme.ink3)
      .frame(maxWidth: .infinity, minHeight: 50)
      .atlasChrome(
        fill: isSelected ? AtlasTheme.selection : Color.clear,
        border: isSelected ? AtlasTheme.outline : Color.clear,
        level: .control,
        radius: shape.pillControls ? 18 : AtlasRadius.control,
        borderWidth: isSelected && (shape.hasBoldBorders || contrast == .increased)
          ? max(shape.controlBorderWidth, 2) : 0,
        showsShadow: false
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(section.title)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier("tab-\(section.rawValue)")
  }
}
