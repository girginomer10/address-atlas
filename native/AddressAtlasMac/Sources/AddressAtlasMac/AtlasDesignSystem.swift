import AddressAtlasCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum AtlasTheme {
  static let paperRGB = (red: 0.965, green: 0.952, blue: 0.92)
  static let paper2RGB = (red: 0.925, green: 0.912, blue: 0.88)
  static let ink3RGB = (red: 0.42, green: 0.39, blue: 0.34)
  static let paper = Color(red: paperRGB.red, green: paperRGB.green, blue: paperRGB.blue)
  static let paper2 = Color(red: paper2RGB.red, green: paper2RGB.green, blue: paper2RGB.blue)
  static let paper3 = Color(red: 0.885, green: 0.872, blue: 0.84)
  static let ink = Color(red: 0.16, green: 0.15, blue: 0.13)
  static let ink2 = Color(red: 0.34, green: 0.32, blue: 0.28)
  static let ink3 = Color(red: ink3RGB.red, green: ink3RGB.green, blue: ink3RGB.blue)
  static let rule = Color(red: 0.78, green: 0.755, blue: 0.69)
  static let ruleSoft = Color(red: 0.84, green: 0.82, blue: 0.76)
  static let accent = Color(red: 0.18, green: 0.31, blue: 0.56)
  static let gain = Color(red: 0.12, green: 0.45, blue: 0.27)
  static let loss = Color(red: 0.72, green: 0.17, blue: 0.12)
}

struct Page<Content: View>: View {
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
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        HStack(alignment: .top, spacing: 28) {
          VStack(alignment: .leading, spacing: 12) {
            AtlasLabel(eyebrow)
            Text(title)
              .font(.system(size: 58, weight: .regular, design: .serif))
              .italic()
              .lineLimit(1)
              .minimumScaleFactor(0.7)
            Text(subtitle)
              .font(.system(size: 15))
              .foregroundStyle(AtlasTheme.ink2)
              .lineSpacing(3)
              .frame(maxWidth: 680, alignment: .leading)
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 5) {
            AtlasLabel(statTitle)
            Text(statValue)
              .font(.system(size: 13, weight: .semibold, design: .monospaced))
          }
          .frame(minWidth: 170, alignment: .trailing)
        }
        .padding(.bottom, 28)
        .overlay(alignment: .bottom) {
          Rectangle().fill(AtlasTheme.rule).frame(height: 1)
        }

        StatusLine()
        content
      }
      .padding(.horizontal, 48)
      .padding(.vertical, 30)
      .frame(maxWidth: 1220, alignment: .leading)
    }
    .scrollContentBackground(.hidden)
    .background(AtlasTheme.paper)
  }
}

struct Surface<Content: View>: View {
  var padding: CGFloat
  var content: Content

  init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
    self.padding = padding
    self.content = content()
  }

  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(AtlasTheme.paper)
      .foregroundStyle(AtlasTheme.ink)
      .overlay(Rectangle().stroke(AtlasTheme.rule, lineWidth: 1))
  }
}

struct SectionHeader: View {
  var title: String
  var meta: String

  var body: some View {
    HStack {
      AtlasLabel(title)
      Spacer()
      AtlasLabel(meta)
    }
  }
}

struct AtlasLabel: View {
  var text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text.uppercased())
      .font(.system(size: 10, weight: .medium, design: .monospaced))
      .foregroundStyle(AtlasTheme.ink3)
      .tracking(1.1)
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
      .font(.system(size: 10, weight: .medium, design: .monospaced))
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .frame(height: 22)
      .overlay(Rectangle().stroke(color.opacity(0.55), lineWidth: 1))
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
    AtlasLabel(text)
      .frame(width: width, alignment: alignment)
      .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
  }
}

struct KeyValueGrid: View {
  var rows: [(String, String)]

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
        HStack(alignment: .firstTextBaseline) {
          AtlasLabel(row.0)
            .frame(width: 140, alignment: .leading)
          Text(row.1)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(AtlasTheme.ink2)
            .textSelection(.enabled)
          Spacer()
        }
        .padding(.vertical, 10)
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
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 26))
        .foregroundStyle(AtlasTheme.ink3)
      Text(title)
        .font(.system(size: 18, weight: .semibold, design: .serif))
      Text(copy)
        .font(.system(size: 13))
        .foregroundStyle(AtlasTheme.ink3)
    }
    .frame(maxWidth: .infinity)
    .padding(36)
    .background(AtlasTheme.paper2)
    .overlay(Rectangle().stroke(AtlasTheme.rule, lineWidth: 1))
  }
}

struct BrandLockup: View {
  var body: some View {
    HStack(spacing: 12) {
      Text("A")
        .font(.system(size: 22, weight: .regular, design: .serif))
        .italic()
        .frame(width: 36, height: 36)
        .overlay(Circle().stroke(AtlasTheme.ink, lineWidth: 1))
      VStack(alignment: .leading, spacing: 1) {
        Text("Address Atlas")
          .font(.system(size: 19, weight: .regular, design: .serif))
          .italic()
        AtlasLabel("Private portfolio map")
      }
    }
  }
}

struct SidebarTrustLine: View {
  var title: String
  var copy: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      AtlasLabel(title)
      Text(copy)
        .font(.system(size: 13))
        .foregroundStyle(AtlasTheme.ink2)
    }
    .padding(.vertical, 11)
    .overlay(alignment: .bottom) {
      Rectangle().fill(AtlasTheme.ruleSoft).frame(height: 1)
    }
  }
}

struct StatusLine: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let operatorMessage = state.operatorMessage {
        HStack(spacing: 8) {
          Image(systemName: "info.circle")
          Text(operatorMessage)
        }
        .foregroundStyle(AtlasTheme.accent)
        .accessibilityLabel("Sync server message: \(operatorMessage)")
      }
      if !state.notice.isEmpty {
        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle")
          Text(state.notice)
        }
        .foregroundStyle(AtlasTheme.gain)
      }
      if !state.error.isEmpty {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle")
          Text(state.error)
        }
        .foregroundStyle(AtlasTheme.loss)
      }
      if !state.isAppVersionSupported {
        Link(destination: state.safeUpdateDownloadURL) {
          Label(
            "Download the latest signed Address Atlas release", systemImage: "arrow.down.circle")
        }
        .accessibilityHint("Opens the hard-pinned Address Atlas releases page in your browser")
      }
    }
    .font(.system(size: 12))
  }
}

struct AtlasTextFieldStyle: TextFieldStyle {
  @Environment(\.isEnabled) private var isEnabled

  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration
      .textFieldStyle(.plain)
      .foregroundStyle(isEnabled ? AtlasTheme.ink : AtlasTheme.ink3)
      .padding(.horizontal, 12)
      .frame(height: 40)
      .background(isEnabled ? AtlasTheme.paper : AtlasTheme.paper2)
      .overlay(
        Rectangle().stroke(isEnabled ? AtlasTheme.rule : AtlasTheme.ruleSoft, lineWidth: 1)
      )
      .opacity(isEnabled ? 1 : 0.72)
  }
}

struct AtlasPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(isEnabled ? AtlasTheme.paper : AtlasTheme.ink3)
      .padding(.horizontal, 15)
      .frame(minHeight: 40)
      .background(
        isEnabled
          ? (configuration.isPressed ? AtlasTheme.accent : AtlasTheme.ink)
          : AtlasTheme.paper3
      )
      .overlay(
        Rectangle().stroke(isEnabled ? Color.clear : AtlasTheme.rule, lineWidth: 1)
      )
      .contentShape(Rectangle())
      .opacity(isEnabled ? 1 : 0.78)
  }
}

struct AtlasSecondaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(
        isEnabled
          ? (configuration.isPressed ? AtlasTheme.accent : AtlasTheme.ink)
          : AtlasTheme.ink3
      )
      .padding(.horizontal, 14)
      .frame(minHeight: 38)
      .background(isEnabled ? AtlasTheme.paper : AtlasTheme.paper2)
      .overlay(
        Rectangle().stroke(
          isEnabled
            ? (configuration.isPressed ? AtlasTheme.accent : AtlasTheme.rule)
            : AtlasTheme.ruleSoft,
          lineWidth: 1)
      )
      .contentShape(Rectangle())
      .opacity(isEnabled ? 1 : 0.72)
  }
}

struct SidebarButtonStyle: ButtonStyle {
  var active: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .medium))
      .foregroundStyle(active ? AtlasTheme.paper : AtlasTheme.ink2)
      .background(
        active ? AtlasTheme.ink : (configuration.isPressed ? AtlasTheme.paper2 : Color.clear))
  }
}

struct IconButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13))
      .foregroundStyle(
        isEnabled
          ? (configuration.isPressed ? AtlasTheme.loss : AtlasTheme.ink3)
          : AtlasTheme.paper3
      )
      .frame(width: 30, height: 30)
      .contentShape(Rectangle())
      .opacity(isEnabled ? 1 : 0.55)
  }
}

func money(_ value: Double) -> String {
  value.formatted(.currency(code: "USD"))
}
