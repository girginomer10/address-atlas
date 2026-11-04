import AddressAtlasCore
#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct Page<Content: View>: View {
  /// Desktop pages reserve a readable minimum width; compact iOS layouts must
  /// never force horizontal scrolling.
  static var minimumContentWidth: CGFloat {
    #if os(macOS)
      return 720
    #else
      return 0
    #endif
  }

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
            .frame(minWidth: Self.minimumContentWidth)

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
    .background(AtlasCanvasBackground())
  }

  private func heading(lineLimit: Int) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(eyebrow)
        .font(AtlasTheme.font(.label, .caption, weight: .semibold))
        .foregroundStyle(AtlasTheme.accent)
      Text(title)
        .font(AtlasTheme.font(.display, size: titleSize, relativeTo: .largeTitle, weight: .bold))
        .tracking(AtlasTheme.tracking(.display, size: titleSize))
        .lineLimit(lineLimit)
        .minimumScaleFactor(0.7)
      Text(subtitle)
        .font(AtlasTheme.font(.body, .body))
        .foregroundStyle(AtlasTheme.ink2)
        .lineSpacing(2)
        .frame(maxWidth: 680, alignment: .leading)
    }
  }

  private var headerStat: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(statTitle)
        .font(AtlasTheme.font(.label, .caption, weight: .medium))
        .foregroundStyle(AtlasTheme.ink3)
      Text(statValue)
        .font(AtlasTheme.font(.number, .callout, weight: .semibold))
        .foregroundStyle(AtlasTheme.ink)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .atlasChrome(
      fill: AtlasTheme.surface,
      border: AtlasTheme.outline,
      level: .control,
      radius: AtlasRadius.control,
      borderWidth: AtlasTheme.shape.cardBorderWidth
    )
    .accessibilityElement(children: .combine)
  }
}

/// The window canvas: the theme's canvas colour, with a faint gradient where
/// the theme asks for one.
struct AtlasCanvasBackground: View {
  var body: some View {
    if AtlasTheme.shape.canvasGradient {
      LinearGradient(
        colors: [AtlasTheme.canvas, AtlasTheme.surfaceMuted.opacity(0.22)],
        startPoint: .top,
        endPoint: .bottom
      )
    } else {
      AtlasTheme.canvas
    }
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
      .foregroundStyle(AtlasTheme.ink)
      .atlasChrome(
        fill: background,
        border: border,
        level: .card,
        showsShadow: style == .standard || AtlasTheme.shape.hasHardShadows
      )
  }

  private var background: Color {
    switch style {
    case .standard: AtlasTheme.surface
    case .subtle: AtlasTheme.surfaceMuted
    case .accent: AtlasTheme.accentSoft
    case .warning: AtlasTheme.warningSoft
    case .danger: AtlasTheme.lossSoft
    }
  }

  /// Brutal themes outline every card in ink; quiet themes tint the outline of
  /// callout cards with their tone.
  private var border: Color {
    if AtlasTheme.shape.hasBoldBorders { return AtlasTheme.outline }
    switch style {
    case .standard, .subtle: return AtlasTheme.outline
    case .accent: return AtlasTheme.accent.opacity(0.30)
    case .warning: return AtlasTheme.warning.opacity(0.34)
    case .danger: return AtlasTheme.loss.opacity(0.34)
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
      .font(AtlasTheme.font(.display, .headline, weight: .bold))
      .foregroundStyle(AtlasTheme.ink)
      .accessibilityAddTraits(.isHeader)
  }

  private var headerMeta: some View {
    Text(meta)
      .font(AtlasTheme.font(.label, .caption))
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
      .font(AtlasTheme.font(.label, .caption, weight: .semibold))
      .foregroundStyle(AtlasTheme.ink3)
  }
}

/// A chip or pill: a short status or tag in a tone colour. Quiet themes tint
/// the chip; outlined themes draw it as a bordered, hard-edged tag.
struct Badge: View {
  var text: String
  var color: Color

  init(_ text: String, color: Color = AtlasTheme.ink3) {
    self.text = text
    self.color = color
  }

  var body: some View {
    let shape = AtlasTheme.shape
    Text(text)
      .font(AtlasTheme.font(.label, .caption2, weight: .semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .frame(minHeight: 24)
      .atlasChrome(
        fill: shape.hasBoldBorders ? AtlasTheme.surface : color.opacity(0.11),
        border: shape.hasBoldBorders ? AtlasTheme.outline : color.opacity(0.28),
        level: .control,
        radius: shape.pillControls ? 999 : shape.radiusSmall,
        borderWidth: shape.hasBoldBorders ? min(shape.controlBorderWidth, 2) : 1,
        showsShadow: false
      )
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
      .font(AtlasTheme.font(.label, .caption, weight: .semibold))
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
            .font(AtlasTheme.font(.body, .callout, weight: .medium))
            .foregroundStyle(AtlasTheme.ink3)
            .frame(width: 160, alignment: .leading)
          Text(row.1)
            .font(AtlasTheme.font(.body, .callout))
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
        .background(AtlasTheme.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
      Text(title)
        .font(AtlasTheme.font(.display, .title3, weight: .bold))
      Text(copy)
        .font(AtlasTheme.font(.body, .callout))
        .foregroundStyle(AtlasTheme.ink3)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(40)
    .background(AtlasTheme.surfaceMuted.opacity(0.38))
    .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous)
        .stroke(
          AtlasTheme.shape.hasBoldBorders ? AtlasTheme.outline : AtlasTheme.ruleSoft,
          style: StrokeStyle(
            lineWidth: max(1, AtlasTheme.shape.cardBorderWidth * 0.8), dash: [5, 4])
        )
    }
  }
}

struct BrandLockup: View {
  var body: some View {
    HStack(spacing: 11) {
      Image(systemName: "map.fill")
        .font(.body.weight(.semibold))
        .foregroundStyle(AtlasTheme.onAccent)
        .frame(width: 38, height: 38)
        .atlasChrome(
          fill: AtlasTheme.accent,
          border: AtlasTheme.outline,
          level: .control,
          radius: AtlasTheme.shape.pillControls ? 12 : AtlasRadius.control,
          borderWidth: AtlasTheme.shape.hasBoldBorders ? AtlasTheme.shape.controlBorderWidth : 0
        )

      VStack(alignment: .leading, spacing: 2) {
        Text("Address Atlas")
          .font(AtlasTheme.font(.display, .headline, weight: .bold))
        Text("Private portfolio map")
          .font(AtlasTheme.font(.label, .caption))
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
          .font(AtlasTheme.font(.body, .callout, weight: .medium))
        Text(copy)
          .font(AtlasTheme.font(.label, .caption))
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
        .font(AtlasTheme.font(.body, .callout, weight: .medium))
        .foregroundStyle(AtlasTheme.ink2)
      if let detail {
        Text(detail)
          .font(AtlasTheme.font(.label, .caption))
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

  var softFill: Color {
    switch self {
    case .info: AtlasTheme.accentSoft
    case .success: AtlasTheme.gainSoft
    case .warning: AtlasTheme.warningSoft
    case .danger: AtlasTheme.lossSoft
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
          .font(AtlasTheme.font(.body, .callout, weight: .semibold))
        Text(copy)
          .font(AtlasTheme.font(.body, .callout))
          .foregroundStyle(AtlasTheme.ink2)
          .lineSpacing(2)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .atlasChrome(
      fill: tone.softFill,
      border: AtlasTheme.shape.hasBoldBorders ? AtlasTheme.outline : tone.color.opacity(0.30),
      level: .control,
      radius: AtlasRadius.control,
      borderWidth: AtlasTheme.shape.hasBoldBorders ? AtlasTheme.shape.controlBorderWidth : 1,
      showsShadow: false
    )
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
        .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous))
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(AtlasTheme.font(.display, .headline, weight: .bold))
        Text(subtitle)
          .font(AtlasTheme.font(.body, .callout))
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
          .background(AtlasTheme.gainSoft)
          .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.small, style: .continuous))
        VStack(alignment: .leading, spacing: 1) {
          Text("Private by design")
            .font(AtlasTheme.font(.body, .callout, weight: .semibold))
          Text("Encrypted on this \(PlatformCopy.deviceNoun)")
            .font(AtlasTheme.font(.label, .caption))
            .foregroundStyle(AtlasTheme.ink3)
        }
      }
      Text("Credentials and portfolio data stay encrypted before storage or sync.")
        .font(AtlasTheme.font(.body, .caption))
        .foregroundStyle(AtlasTheme.ink3)
        .lineSpacing(2)
    }
    .padding(14)
    .background(AtlasTheme.surfaceMuted.opacity(0.44))
    .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous)
        .stroke(
          AtlasTheme.shape.hasBoldBorders ? AtlasTheme.outline : AtlasTheme.ruleSoft,
          lineWidth: max(1, AtlasTheme.shape.cardBorderWidth * 0.6))
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

    var priority: AtlasAnnouncementPriority {
      switch self {
      case .operatorMessage, .notice: .medium
      case .guidance, .error: .high
      }
    }
  }

  typealias Clock = @MainActor () -> TimeInterval
  typealias Poster = @MainActor (String, AtlasAnnouncementPriority) -> Void

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

  #if canImport(AppKit)
    private static func postToAppKit(
      _ message: String,
      priority: AtlasAnnouncementPriority
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
  #else
    /// UIKit has no announcement priority; the message itself is posted.
    private static func postToAppKit(
      _ message: String,
      priority: AtlasAnnouncementPriority
    ) {
      UIAccessibility.post(notification: .announcement, argument: message)
    }
  #endif
}

/// Announcement urgency, mapped onto AppKit's priority levels on macOS so the
/// existing macOS behavior and tests are unchanged.
#if canImport(AppKit)
  typealias AtlasAnnouncementPriority = NSAccessibilityPriorityLevel
#else
  enum AtlasAnnouncementPriority: Int, Sendable {
    case medium = 50
    case high = 90
  }
#endif

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
                state.updateActionTitle,
                systemImage: "arrow.down.circle"
              )
            }
            .accessibilityHint(state.updateActionHint)
          }
        }
        .font(AtlasTheme.font(.body, .callout))
        .padding(.horizontal, presentation == .pinned ? 16 : 0)
        .padding(.vertical, presentation == .pinned ? 13 : 0)
        .frame(maxWidth: presentation == .pinned ? .infinity : nil, alignment: .leading)
        .modifier(PinnedStatusChrome(isPinned: presentation == .pinned))
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

/// The pinned status banner is a themed toast: card chrome when pinned, bare
/// inline text otherwise.
private struct PinnedStatusChrome: ViewModifier {
  var isPinned: Bool

  func body(content: Content) -> some View {
    if isPinned {
      content.atlasChrome(
        fill: AtlasTheme.surface,
        border: AtlasTheme.outline,
        level: .control,
        radius: AtlasRadius.control,
        borderWidth: max(1, AtlasTheme.shape.cardBorderWidth)
      )
    } else {
      content
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
  /// Colours and widths of a text field or secondary button. `theme` defaults
  /// to the selected theme; tests pass each theme explicitly.
  static func tokens(
    for kind: AtlasControlKind,
    appearance: AtlasAppearanceVariant,
    state: AtlasControlVisualState,
    theme: AtlasThemeID? = nil
  ) -> AtlasControlStyleTokens {
    let definition = theme.map(AtlasThemeCatalog.definition(for:)) ?? AtlasTheme.definition
    let palette = definition.palette(for: appearance)
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
      background: state.isEnabled ? palette.surface : palette.surfaceMuted,
      boundary: boundary,
      focusRing: palette.focusRing,
      boundaryWidth: max(Double(definition.shape.controlBorderWidth), appearance.isHighContrast ? 2 : 1.5),
      focusRingWidth: state.isEnabled && state.isFocused ? 3 : 0,
      focusRingOutset: 3
    )
  }
}

/// The 3 pt keyboard-focus ring drawn outside a control.
private struct AtlasFocusRing: View {
  var color: Color
  var width: CGFloat
  var outset: CGFloat = 3
  var radius: CGFloat

  var body: some View {
    if width > 0 {
      RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
        .stroke(color, lineWidth: width)
        .padding(-outset)
        .accessibilityHidden(true)
    }
  }
}

private struct AtlasControlOutline: View {
  let tokens: AtlasControlStyleTokens
  let radius: CGFloat

  var body: some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
      .stroke(tokens.boundary.color, lineWidth: tokens.boundaryWidth)
      .overlay {
        AtlasFocusRing(
          color: tokens.focusRing.color,
          width: tokens.focusRingWidth,
          outset: tokens.focusRingOutset,
          radius: radius
        )
      }
      .accessibilityHidden(true)
  }
}

struct AtlasTextFieldStyle: TextFieldStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  #if os(iOS)
    /// The field's padding is outside the UIKit text view, so a touch on it
    /// would otherwise do nothing; the whole rounded control focuses the field.
    @FocusState private var tapFocused: Bool
  #endif

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
    let radius = AtlasRadius.control

    #if os(iOS)
      configuration
        .textFieldStyle(.plain)
        .focused($tapFocused)
        .foregroundStyle(tokens.foreground.color)
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(minHeight: 42)
        .background(tokens.background.color)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(AtlasControlOutline(tokens: tokens, radius: radius))
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onTapGesture {
          if isEnabled { tapFocused = true }
        }
    #else
      configuration
        .textFieldStyle(.plain)
        .foregroundStyle(tokens.foreground.color)
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(minHeight: 42)
        .background(tokens.background.color)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(AtlasControlOutline(tokens: tokens, radius: radius))
    #endif
  }
}

struct AtlasPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.atlasTheme) private var tokens

  func makeBody(configuration: Configuration) -> some View {
    let shape = AtlasTheme.shape
    let radius: CGFloat = shape.pillControls ? 999 : shape.radiusControl
    let pressed = configuration.isPressed && isEnabled
    // An accent fill in the shadow's own colour (Candy's black button) would
    // only grow a smudge; it keeps its border and loses the offset.
    let hidesShadow = tokens.palette.accent == tokens.palette.shadow
    configuration.label
      .font(AtlasTheme.font(.body, .callout, weight: .semibold))
      .foregroundStyle(isEnabled ? AtlasTheme.onAccent : AtlasTheme.ink3)
      .padding(.horizontal, 16)
      .frame(minHeight: 42)
      .atlasChrome(
        fill: isEnabled
          ? AtlasTheme.accent.opacity(pressed && !shape.hasHardShadows ? 0.82 : 1)
          : AtlasTheme.surfaceMuted,
        border: isEnabled
          ? (shape.hasBoldBorders ? AtlasTheme.outline : AtlasTheme.accent.opacity(0.25))
          : AtlasTheme.ruleSoft,
        level: .control,
        radius: radius,
        borderWidth: shape.hasBoldBorders ? shape.controlBorderWidth : 1,
        isPressed: pressed && !hidesShadow,
        showsShadow: isEnabled && !hidesShadow
      )
      .overlay {
        AtlasFocusRing(
          color: AtlasTheme.focusRing,
          width: isEnabled && isFocused ? 3 : 0,
          radius: min(radius, 21)
        )
      }
      .contentShape(AtlasOutline(radius: radius))
      .scaleEffect(pressed && (!shape.hasHardShadows || hidesShadow) ? 0.985 : 1)
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
    let shape = AtlasTheme.shape
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
    let radius: CGFloat = shape.pillControls ? 999 : shape.radiusControl
    let pressed = configuration.isPressed && isEnabled

    configuration.label
      .font(AtlasTheme.font(.body, .callout, weight: .medium))
      .foregroundStyle(tokens.foreground.color)
      .padding(.horizontal, 14)
      .frame(minHeight: 40)
      .atlasChrome(
        fill: tokens.background.color,
        border: tokens.boundary.color,
        level: .control,
        radius: radius,
        borderWidth: tokens.boundaryWidth,
        isPressed: pressed,
        showsShadow: isEnabled
      )
      .overlay {
        AtlasFocusRing(
          color: tokens.focusRing.color,
          width: tokens.focusRingWidth,
          outset: tokens.focusRingOutset,
          radius: min(radius, 21)
        )
      }
      .contentShape(AtlasOutline(radius: radius))
      .scaleEffect(pressed && !shape.hasHardShadows ? 0.985 : 1)
      .animation(
        AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
        value: configuration.isPressed
      )
  }
}

/// Navigation row: the selected item uses the theme's selection fill, outlined
/// (and shadowed) in the themes that draw hard edges.
struct SidebarButtonStyle: ButtonStyle {
  @Environment(\.isFocused) private var isFocused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  var active: Bool

  func makeBody(configuration: Configuration) -> some View {
    let shape = AtlasTheme.shape
    let radius = AtlasRadius.control
    configuration.label
      .font(AtlasTheme.font(.body, .callout, weight: active ? .semibold : .medium))
      .foregroundStyle(active ? AtlasTheme.onSelection : AtlasTheme.ink2)
      .atlasChrome(
        fill: active
          ? AtlasTheme.selection
          : (configuration.isPressed ? AtlasTheme.surfaceMuted.opacity(0.75) : Color.clear),
        border: active ? AtlasTheme.outline : Color.clear,
        level: .control,
        radius: radius,
        borderWidth: active && (shape.hasBoldBorders || contrast == .increased)
          ? max(shape.controlBorderWidth, 2) : 0,
        showsShadow: active
      )
      .overlay {
        AtlasFocusRing(
          color: AtlasTheme.focusRing,
          width: isFocused ? 3 : 0,
          radius: radius
        )
      }
      .scaleEffect(configuration.isPressed && !shape.hasHardShadows ? 0.99 : 1)
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
            .stroke(AtlasTheme.focusRing, lineWidth: 3)
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
    "\(AtlasFormatting.dateTime(run.generatedAt)), record ID \(run.id.uuidString.lowercased())"
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
  value.formatted(.currency(code: "USD").locale(AtlasFormatting.locale))
}
