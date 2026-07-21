import AddressAtlasCore
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum AtlasTheme {
  static let paperRGB = (red: 0.965, green: 0.952, blue: 0.92)
  static let paper2RGB = (red: 0.925, green: 0.912, blue: 0.88)
  static let ink3RGB = (red: 0.42, green: 0.39, blue: 0.34)
  static let warningRGB = (red: 0.55, green: 0.30, blue: 0.02)
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
  /// Dark enough for normal-size warning text on both paper surfaces.
  static let warning = Color(
    red: warningRGB.red,
    green: warningRGB.green,
    blue: warningRGB.blue
  )
}

struct Page<Content: View>: View {
  @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 58
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
        VStack(alignment: .leading, spacing: 26) {
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 28) {
              heading(lineLimit: 1)
              Spacer()
              headerStat
                .frame(minWidth: 170, alignment: .trailing)
            }
            // Below this width the subtitle becomes an unreadably narrow sliver
            // beside the stat block even if SwiftUI can technically compress it.
            .frame(minWidth: 760)

            VStack(alignment: .leading, spacing: 18) {
              heading(lineLimit: 2)
              headerStat
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(.bottom, 28)
          .overlay(alignment: .bottom) {
            Rectangle().fill(AtlasTheme.rule).frame(height: 1)
          }

          content
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 30)
        .frame(maxWidth: 1220, alignment: .leading)
      }
      .scrollContentBackground(.hidden)
    }
    .background(AtlasTheme.paper)
  }

  private func heading(lineLimit: Int) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      AtlasLabel(eyebrow)
      Text(title)
        .font(.system(size: titleSize, weight: .regular, design: .serif))
        .italic()
        .lineLimit(lineLimit)
        .minimumScaleFactor(0.7)
      Text(subtitle)
        .font(.body)
        .foregroundStyle(AtlasTheme.ink2)
        .lineSpacing(3)
        .frame(maxWidth: 680, alignment: .leading)
    }
  }

  private var headerStat: some View {
    VStack(alignment: .trailing, spacing: 5) {
      AtlasLabel(statTitle)
      Text(statValue)
        .font(.callout.monospaced().weight(.semibold))
    }
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
      .font(.caption2.monospaced().weight(.medium))
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
      .font(.caption2.monospaced().weight(.medium))
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .frame(minHeight: 22)
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
            .font(.caption.monospaced())
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
        .font(.title2)
        .foregroundStyle(AtlasTheme.ink3)
      Text(title)
        .font(.system(.title3, design: .serif).weight(.semibold))
      Text(copy)
        .font(.callout)
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
        .font(.system(.title2, design: .serif))
        .italic()
        .frame(width: 36, height: 36)
        .overlay(Circle().stroke(AtlasTheme.ink, lineWidth: 1))
      VStack(alignment: .leading, spacing: 1) {
        Text("Address Atlas")
          .font(.system(.title3, design: .serif))
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
        .font(.callout)
        .foregroundStyle(AtlasTheme.ink2)
    }
    .padding(.vertical, 11)
    .overlay(alignment: .bottom) {
      Rectangle().fill(AtlasTheme.ruleSoft).frame(height: 1)
    }
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
        .padding(.horizontal, presentation == .pinned ? 30 : 0)
        .padding(.vertical, presentation == .pinned ? 12 : 0)
        .frame(maxWidth: presentation == .pinned ? .infinity : nil, alignment: .leading)
        .background(presentation == .pinned ? AtlasTheme.paper2 : Color.clear)
        .overlay(alignment: .bottom) {
          if presentation == .pinned {
            Rectangle().fill(AtlasTheme.rule).frame(height: 1)
          }
        }
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

struct AtlasTextFieldStyle: TextFieldStyle {
  @Environment(\.isEnabled) private var isEnabled

  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration
      .textFieldStyle(.plain)
      .foregroundStyle(isEnabled ? AtlasTheme.ink : AtlasTheme.ink3)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .frame(minHeight: 40)
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
      .font(.callout.weight(.semibold))
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
      .font(.callout.weight(.medium))
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
      .font(.body.weight(.medium))
      .foregroundStyle(active ? AtlasTheme.paper : AtlasTheme.ink2)
      .background(
        active ? AtlasTheme.ink : (configuration.isPressed ? AtlasTheme.paper2 : Color.clear))
  }
}

struct IconButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout)
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
}

func money(_ value: Double) -> String {
  value.formatted(.currency(code: "USD"))
}
