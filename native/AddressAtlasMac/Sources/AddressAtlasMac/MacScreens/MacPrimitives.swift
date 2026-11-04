import AddressAtlasCore
import SwiftUI

// Building blocks of the Mac screens. They sit on top of the shared design
// system (`Surface`, `Badge`, `InfoCallout`, the button styles, `StatusLine`)
// and read every colour, font and shape from the theme tokens, so each screen
// looks right in all six themes.

// MARK: - Page

/// Scrolls the enclosing `MacPage` to a view that carries `.id(...)`.
struct MacScrollAction {
  var perform: (AnyHashable) -> Void

  func callAsFunction(_ id: AnyHashable) {
    perform(id)
  }
}

private struct MacScrollToKey: EnvironmentKey {
  static var defaultValue: MacScrollAction { MacScrollAction { _ in } }
}

extension EnvironmentValues {
  var macScrollTo: MacScrollAction {
    get { self[MacScrollToKey.self] }
    set { self[MacScrollToKey.self] = newValue }
  }
}

/// A screen: a title, an optional control at the trailing edge, then content.
/// The pinned status line (notices and errors) sits above the scroll area.
struct MacPage<Trailing: View, Content: View>: View {
  var title: String
  var trailing: Trailing
  var content: Content

  init(
    _ title: String,
    @ViewBuilder trailing: () -> Trailing,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.trailing = trailing()
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      StatusLine(presentation: .pinned)
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 22) {
            header
            content
          }
          .padding(.horizontal, 28)
          .padding(.top, 24)
          .padding(.bottom, 40)
          .frame(maxWidth: 1_180, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .environment(
          \.macScrollTo,
          MacScrollAction { id in proxy.scrollTo(id, anchor: .center) })
      }
    }
    .background(AtlasCanvasBackground())
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 16) {
      MacPageTitle(text: title)
      Spacer(minLength: 12)
      trailing
    }
  }
}

extension MacPage where Trailing == EmptyView {
  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.init(title, trailing: { EmptyView() }, content: content)
  }
}

struct MacPageTitle: View {
  @Environment(\.atlasTheme) private var tokens
  var text: String

  var body: some View {
    Text(text)
      .font(tokens.font(.display, size: 30, relativeTo: .largeTitle, weight: .bold))
      .tracking(tokens.typography.display.tracking * 30)
      .foregroundStyle(tokens.color(.ink))
      .lineLimit(1)
      .minimumScaleFactor(0.7)
      .accessibilityAddTraits(.isHeader)
  }
}

/// A section heading inside a page, with an optional control at its end.
struct MacHeading<Trailing: View>: View {
  var title: String
  var trailing: Trailing

  init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
    self.title = title
    self.trailing = trailing()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title)
        .font(AtlasTheme.font(.display, .title3, weight: .bold))
        .foregroundStyle(AtlasTheme.ink)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 8)
      trailing
    }
  }
}

extension MacHeading where Trailing == EmptyView {
  init(_ title: String) {
    self.init(title, trailing: { EmptyView() })
  }
}

// MARK: - Text

/// A figure in the theme's number face (or its body face where the number face
/// draws an ambiguous digit).
struct MacFigure: View {
  @Environment(\.atlasTheme) private var tokens
  var text: String
  var size: CGFloat = 13
  var weight: Font.Weight?
  var color: Color?

  var body: some View {
    Text(verbatim: text)
      .font(tokens.chartKitNumberFont(size, weight: weight))
      .foregroundStyle(color ?? tokens.color(.ink))
      .lineLimit(1)
  }
}

enum MacFormat {
  /// "+$1,204.30" or "−$30.00".
  static func signedMoney(_ value: Double) -> String {
    (value < 0 ? "\u{2212}" : "+") + money(abs(value))
  }

  /// "2.5%".
  static func percent(_ fraction: Double) -> String {
    abs(fraction).formatted(
      .percent.precision(.fractionLength(0...1)).locale(AtlasFormatting.locale))
  }

  /// "Nov 3".
  static func shortDay(_ date: Date) -> String {
    date.formatted(
      Date.FormatStyle().month(.abbreviated).day().locale(AtlasFormatting.locale))
  }

  static func amount(_ value: Double) -> String {
    value.formatted(
      .number.precision(.fractionLength(0...6)).locale(AtlasFormatting.locale))
  }

  static func count(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
    "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
  }
}

// MARK: - Coin mark

/// A coin's mark: its colour from the theme's asset palette, a glyph in the
/// readable ink for that colour, and the theme's shape (round or square).
struct CoinMark: View {
  @Environment(\.atlasTheme) private var tokens
  var symbol: String
  var size: CGFloat = 34

  private var glyph: String {
    switch CoinIdentity.key(forSymbol: symbol) {
    case "BTC": "\u{20BF}"
    case "ETH": "\u{039E}"
    default: String(symbol.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }
  }

  var body: some View {
    let color = tokens.chart.asset(symbol)
    let shape = tokens.shape
    let outline = shape.hasBoldBorders ? min(shape.cardBorderWidth, 2) : 0
    ZStack {
      if shape.pillControls {
        Circle().fill(color.color)
        if outline > 0 { Circle().stroke(tokens.color(.outline), lineWidth: outline) }
      } else {
        let radius = min(shape.radiusSmall, size * 0.3)
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(color.color)
        if outline > 0 {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(tokens.color(.outline), lineWidth: outline)
        }
      }
      Text(verbatim: glyph)
        .font(.system(size: size * 0.42, weight: .bold))
        .foregroundStyle(tokens.chartKitInk(on: color).color)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

// MARK: - Chips

/// The shape of a chip: a capsule in themes with pill controls, otherwise the
/// theme's control radius.
private struct MacChipChrome: ViewModifier {
  @Environment(\.colorSchemeContrast) private var contrast
  var selected: Bool
  var pressed = false
  var focused = false

  func body(content: Content) -> some View {
    let shape = AtlasTheme.shape
    // A capsule at the chip's 32 pt height: `.continuous` corners do not clamp
    // a larger radius (see MacButtons.swift).
    let radius: CGFloat = shape.pillControls ? 16 : shape.radiusControl
    content
      .font(AtlasTheme.font(.body, .callout, weight: selected ? .semibold : .medium))
      .foregroundStyle(selected ? AtlasTheme.onSelection : AtlasTheme.ink)
      .padding(.horizontal, 12)
      .frame(minHeight: 32)
      .macChrome(
        fill: selected
          ? AtlasTheme.selection
          : (pressed ? AtlasTheme.surfaceMuted : AtlasTheme.surface),
        border: selected ? AtlasTheme.outline : AtlasTheme.controlBoundary,
        isPill: shape.pillControls,
        radius: radius,
        borderWidth: selected
          ? max(shape.controlBorderWidth, contrast == .increased ? 2 : 1)
          : max(1, min(shape.controlBorderWidth, 2)),
        isPressed: pressed,
        showsShadow: selected
      )
      .overlay {
        if focused {
          RoundedRectangle(cornerRadius: min(radius, 18) + 2, style: .continuous)
            .stroke(AtlasTheme.focusRing, lineWidth: 3)
            .padding(-3)
            .accessibilityHidden(true)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: min(radius, 18), style: .continuous))
  }
}

struct MacChipButtonStyle: ButtonStyle {
  @Environment(\.isFocused) private var isFocused
  var selected: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .modifier(MacChipChrome(selected: selected, pressed: configuration.isPressed, focused: isFocused))
  }
}

/// A row of chips that behaves as a single-choice control (a segmented
/// control in the theme's own shape).
struct MacChipPicker<Option: Hashable>: View {
  var label: String
  var options: [Option]
  @Binding var selection: Option
  var title: (Option) -> String

  var body: some View {
    HStack(spacing: 8) {
      ForEach(options, id: \.self) { option in
        Button {
          selection = option
        } label: {
          Text(title(option)).lineLimit(1)
        }
        .buttonStyle(MacChipButtonStyle(selected: selection == option))
        .accessibilityAddTraits(selection == option ? .isSelected : [])
        .accessibilityLabel(title(option))
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(label)
  }
}

/// The portfolio view switcher: the most-used views as chips, the rest in a
/// "More" menu that takes the name of the chosen view while one of them is on.
struct MacViewSwitcher: View {
  @Binding var selection: PortfolioVisualization
  var options: [PortfolioVisualization]

  /// Shown as chips when they are allowed; the others live in the menu.
  static let primary: [PortfolioVisualization] = [.map, .ring, .list, .overTime, .whatChanged, .flow]

  private var chips: [PortfolioVisualization] {
    Self.primary.filter { options.contains($0) }
  }

  private var overflow: [PortfolioVisualization] {
    options.filter { !chips.contains($0) }
  }

  var body: some View {
    HStack(spacing: 8) {
      ForEach(chips) { view in
        Button {
          selection = view
        } label: {
          Text(view.title).lineLimit(1)
        }
        .buttonStyle(MacChipButtonStyle(selected: selection == view))
        .accessibilityAddTraits(selection == view ? .isSelected : [])
        .accessibilityLabel("\(view.title) view")
      }
      if !overflow.isEmpty {
        let overflowSelected = overflow.contains(selection)
        Menu {
          ForEach(overflow) { view in
            Button {
              selection = view
            } label: {
              if selection == view {
                Label(view.title, systemImage: "checkmark")
              } else {
                Text(view.title)
              }
            }
          }
        } label: {
          HStack(spacing: 5) {
            Text(overflowSelected ? selection.title : "More").lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
          }
        }
        .menuStyle(.button)
        .buttonStyle(MacChipButtonStyle(selected: overflowSelected))
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(overflowSelected ? "\(selection.title) view, more views" : "More views")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("View")
  }
}

/// "Group by: Asset" menu.
struct MacGroupingMenu: View {
  @Binding var selection: PortfolioGrouping
  var options: [PortfolioGrouping] = PortfolioGrouping.allCases

  var body: some View {
    Menu {
      ForEach(options, id: \.self) { grouping in
        Button {
          selection = grouping
        } label: {
          if selection == grouping {
            Label(grouping.displayName, systemImage: "checkmark")
          } else {
            Text(grouping.displayName)
          }
        }
      }
    } label: {
      HStack(spacing: 5) {
        Text("Group by").foregroundStyle(AtlasTheme.ink3)
        Text(selection.displayName).fontWeight(.semibold)
        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
      }
      .lineLimit(1)
    }
    .menuStyle(.button)
    .buttonStyle(MacChipButtonStyle(selected: false))
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("Group by, \(selection.displayName)")
  }
}

// MARK: - Rows

/// A full-width row that opens something. Highlights under the pointer and
/// shows a focus ring for the keyboard.
struct MacRowButton<Content: View>: View {
  var accessibilityLabel: String
  var accessibilityIdentifier: String?
  var action: () -> Void
  var content: Content

  @State private var hovering = false

  init(
    accessibilityLabel: String,
    accessibilityIdentifier: String? = nil,
    action: @escaping () -> Void,
    @ViewBuilder content: () -> Content
  ) {
    self.accessibilityLabel = accessibilityLabel
    self.accessibilityIdentifier = accessibilityIdentifier
    self.action = action
    self.content = content()
  }

  var body: some View {
    Button(action: action) {
      content
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? AtlasTheme.surfaceMuted.opacity(0.7) : Color.clear)
        .contentShape(Rectangle())
    }
    .buttonStyle(MacRowStyle())
    .onHover { hovering = $0 }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier(accessibilityIdentifier ?? "")
  }
}

private struct MacRowStyle: ButtonStyle {
  @Environment(\.isFocused) private var isFocused

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(configuration.isPressed ? AtlasTheme.surfaceMuted : Color.clear)
      .overlay {
        if isFocused {
          Rectangle()
            .stroke(AtlasTheme.focusRing, lineWidth: 3)
            .accessibilityHidden(true)
        }
      }
  }
}

/// Rows in one card, separated by quiet rules.
struct MacRowList<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
  var items: Data
  var row: (Data.Element) -> Row

  init(_ items: Data, @ViewBuilder row: @escaping (Data.Element) -> Row) {
    self.items = items
    self.row = row
  }

  var body: some View {
    Surface(padding: 0) {
      VStack(spacing: 0) {
        ForEach(items) { item in
          row(item)
          if item.id != items.last?.id {
            Divider().overlay(AtlasTheme.ruleSoft)
          }
        }
      }
    }
  }
}

// MARK: - Notes and empty states

/// A sentence about the data next to it: a warning or a plain fact, with an
/// icon in the tone's colour.
struct MacNote: View {
  var text: String
  var tone: AtlasCalloutTone = .warning
  var systemImage: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: systemImage ?? tone.icon)
        .font(.caption.weight(.semibold))
        .foregroundStyle(tone.color)
        .accessibilityHidden(true)
      Text(text)
        .font(AtlasTheme.font(.body, .callout))
        .foregroundStyle(AtlasTheme.ink2)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

/// A short label above a value: "Amount", "Price".
struct MacStat: View {
  var label: String
  var value: String
  var detail: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label)
        .font(AtlasTheme.font(.label, .caption, weight: .medium))
        .foregroundStyle(AtlasTheme.ink3)
      MacFigure(text: value, size: 15, weight: .semibold)
      if let detail {
        Text(detail)
          .font(AtlasTheme.font(.label, .caption))
          .foregroundStyle(AtlasTheme.ink3)
          .lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// "Nothing here yet" with an invitation and up to two actions.
struct MacEmptyState<Actions: View>: View {
  var title: String
  var copy: String
  var systemImage: String
  var actions: Actions

  init(
    _ title: String,
    copy: String,
    systemImage: String,
    @ViewBuilder actions: () -> Actions
  ) {
    self.title = title
    self.copy = copy
    self.systemImage = systemImage
    self.actions = actions()
  }

  var body: some View {
    VStack(spacing: 14) {
      EmptyState(title: title, systemImage: systemImage, copy: copy)
      AdaptiveStack(horizontalSpacing: 10) {
        actions
      }
      .frame(maxWidth: .infinity, alignment: .center)
    }
  }
}

extension MacEmptyState where Actions == EmptyView {
  init(_ title: String, copy: String, systemImage: String) {
    self.init(title, copy: copy, systemImage: systemImage, actions: { EmptyView() })
  }
}

/// The Scan button used by Portfolio, and by ⌘R through `MacScanAction`.
struct MacScanButton: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    Button {
      MacScanAction.perform(state)
    } label: {
      if state.scanning {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Cancel scan")
        }
      } else {
        Label("Scan", systemImage: "arrow.clockwise")
      }
    }
    .buttonStyle(MacPrimaryButtonStyle())
    .disabled(!MacScanAction.isAvailable(state))
    .help(state.scanning ? "Cancel the running scan (⌘R)" : "Scan every wallet and exchange (⌘R)")
    .accessibilityLabel(state.scanning ? "Cancel scan" : "Scan")
  }
}
