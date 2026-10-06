import AddressAtlasCore
import SwiftUI
import UIKit

// MARK: - Cross-screen navigation

/// A task that one screen asks another to start, such as the onboarding
/// finish or a Portfolio empty-state button opening the add-wallet sheet on
/// the Wallets tab. The destination screen consumes it exactly once.
enum IOSPendingAction: Equatable, Sendable {
  case addWallet
  case connectExchange
  case addManualHolding
  case addCustomToken
}

/// Shared iPhone/iPad navigation intent. `TabShell` and `SplitShell` switch
/// to `selectedSection` whenever `openRequest` changes (so reopening the
/// section the person already left still works); screens observe
/// `pendingAction` and clear it with `consume(_:)` once they have presented
/// the requested sheet.
@MainActor
final class IOSNavigationModel: ObservableObject {
  @Published private(set) var selectedSection: AtlasSection = .portfolio
  @Published private(set) var openRequest = 0
  @Published var pendingAction: IOSPendingAction?

  func open(_ section: AtlasSection, then action: IOSPendingAction? = nil) {
    selectedSection = section
    pendingAction = action
    openRequest &+= 1
  }

  /// Returns true (and clears the request) when `action` is pending.
  func consume(_ action: IOSPendingAction) -> Bool {
    guard pendingAction == action else { return false }
    pendingAction = nil
    return true
  }
}

/// The first-run walkthrough is shown once per install, and only while the
/// vault has no sources; restored or returning vaults go straight to the app.
enum IOSOnboarding {
  static let completedKey = "onboarding.completed.v1"
}

// MARK: - Token monogram

/// Colored initial for an asset. The hue is derived from the symbol so the
/// same asset always gets the same color across Portfolio and Assets; a few
/// well-known assets use their familiar hue.
struct TokenMonogram: View {
  @Environment(\.colorScheme) private var colorScheme
  var symbol: String
  var size: CGFloat = 36
  var isPlaceholder = false

  private static let knownHues: [String: Double] = [
    "BTC": 0.08, "WBTC": 0.08, "ETH": 0.64, "WETH": 0.64, "STETH": 0.6,
    "USDT": 0.44, "USDC": 0.58, "DAI": 0.12, "SOL": 0.78, "BNB": 0.13,
    "XRP": 0.0, "ADA": 0.6, "DOT": 0.92, "ATOM": 0.7, "MATIC": 0.75, "POL": 0.75,
    "ARB": 0.57, "OP": 0.99, "AVAX": 0.0, "LINK": 0.62, "TRX": 0.99,
  ]

  static func hue(for symbol: String) -> Double {
    let key = symbol.uppercased()
    if let known = knownHues[key] { return known }
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in key.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return Double(hash % 360) / 360
  }

  private var initials: String {
    let letters = symbol.uppercased().filter { $0.isLetter || $0.isNumber }
    return String(letters.prefix(1))
  }

  var body: some View {
    let hue = Self.hue(for: symbol)
    let foreground =
      isPlaceholder
      ? AtlasTheme.ink3
      : Color(hue: hue, saturation: 0.72, brightness: colorScheme == .dark ? 0.92 : 0.62)
    let background =
      isPlaceholder
      ? AtlasTheme.ink3.opacity(0.12)
      : Color(hue: hue, saturation: 0.6, brightness: 0.85).opacity(colorScheme == .dark ? 0.24 : 0.16)
    ZStack {
      Circle().fill(background)
      if isPlaceholder {
        Image(systemName: "ellipsis")
          .font(.system(size: size * 0.36, weight: .bold))
      } else {
        Text(initials.isEmpty ? "?" : initials)
          .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
          .minimumScaleFactor(0.6)
          .lineLimit(1)
      }
    }
    .foregroundStyle(foreground)
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

// MARK: - Formatting

enum AtlasPercent {
  /// Locale-aware share of a total, with a "<0.1%" floor for tiny non-zero
  /// shares so the floor uses the same separators as every other percentage.
  static func text(_ fraction: Double) -> String {
    let style = FloatingPointFormatStyle<Double>.Percent()
      .precision(.fractionLength(0...1))
      .locale(AtlasFormatting.locale)
    guard fraction.isFinite else { return "–" }
    if fraction > 0, fraction < 0.001 {
      return "<" + 0.001.formatted(style)
    }
    return fraction.formatted(style)
  }
}

// MARK: - Sheets

/// Standard add/edit sheet: inline title, Cancel, an optional confirm action
/// in the navigation bar, a scrolling form body, and the sheet's own inline
/// status so errors appear next to the form instead of behind the sheet.
struct IOSFormSheet<Content: View>: View {
  @Environment(\.dismiss) private var dismiss
  var title: String
  var content: Content

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          content
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 32)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .scrollDismissesKeyboard(.interactively)
      .background(AtlasTheme.canvas)
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(AtlasTheme.canvas, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      .atlasKeyboardDoneButton()
    }
    .presentationDragIndicator(.visible)
  }
}

/// The shared error line for a form shown inside a sheet or right under the
/// control that produced it. Reads `state.error`, so the message is the same
/// one the shared state layer produced.
struct IOSInlineError: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    if !state.error.isEmpty {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "exclamationmark.circle.fill")
          .accessibilityHidden(true)
        Text(state.error)
          .fixedSize(horizontal: false, vertical: true)
      }
      .font(.callout)
      .foregroundStyle(AtlasTheme.loss)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(AtlasTheme.loss.opacity(0.08))
      .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Error: \(state.error)")
      .onAppear {
        AtlasAccessibilityAnnouncer.shared.announceEvent(state.error, kind: .error)
      }
    }
  }
}

// MARK: - Progressive disclosure

/// Collapsed explanation for details most people do not need on every visit.
/// Long privacy and mechanism copy lives here instead of in always-open
/// callouts.
struct LearnMoreDisclosure<Content: View>: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var isExpanded = false
  var title: String
  var systemImage: String
  var content: Content

  init(
    _ title: String = "How this works",
    systemImage: String = "info.circle",
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 10) {
          if !dynamicTypeSize.isAccessibilitySize {
            Image(systemName: systemImage)
              .foregroundStyle(AtlasTheme.accent)
              .accessibilityHidden(true)
          }
          Text(title)
            .font(.callout.weight(.medium))
            .foregroundStyle(AtlasTheme.ink)
            .multilineTextAlignment(.leading)
          Spacer(minLength: 8)
          Image(systemName: "chevron.down")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AtlasTheme.ink3)
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
            .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      .accessibilityHint(isExpanded ? "Hides the details." : "Shows the details.")

      if isExpanded {
        VStack(alignment: .leading, spacing: 10) {
          content
        }
        .font(.callout)
        .foregroundStyle(AtlasTheme.ink2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 10)
        .transition(.opacity)
      }
    }
    .padding(.horizontal, 14)
    .background(AtlasTheme.surfaceMuted.opacity(0.4))
    .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
  }
}

/// One fact inside a `LearnMoreDisclosure` or onboarding page.
struct IOSFactRow: View {
  var systemImage: String
  var title: String
  var copy: String
  var tint: Color = AtlasTheme.accent

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.body.weight(.semibold))
        .foregroundStyle(tint)
        .frame(width: 28)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout.weight(.semibold))
          .foregroundStyle(AtlasTheme.ink)
        Text(copy)
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Keyboard

extension View {
  /// Decimal and number pads have no return key; this adds a Done button
  /// above every keyboard on the page. Apply once per page or sheet.
  func atlasKeyboardDoneButton() -> some View {
    toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") {
          UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .font(.body.weight(.semibold))
      }
    }
  }
}

// MARK: - Status

/// Long-lived status that must stay on the page: operator messages, required
/// actions, and the unsupported-version update link. Transient notices and
/// errors are shown by `IOSStatusToast` instead.
struct IOSPersistentStatus: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    if state.operatorMessage != nil || state.persistentOperationGuidance != nil
      || !state.isAppVersionSupported
    {
      VStack(alignment: .leading, spacing: 8) {
        if let operatorMessage = state.operatorMessage {
          Label(operatorMessage, systemImage: "info.circle")
            .foregroundStyle(AtlasTheme.accent)
            .accessibilityLabel("Sync server message: \(operatorMessage)")
        }
        if let guidance = state.persistentOperationGuidance {
          Label(guidance, systemImage: "exclamationmark.shield")
            .foregroundStyle(AtlasTheme.warning)
            .accessibilityLabel("Action required: \(guidance)")
        }
        if !state.isAppVersionSupported {
          Link(destination: state.safeUpdateDownloadURL) {
            Label(state.updateActionTitle, systemImage: "arrow.down.circle")
          }
          .accessibilityHint(state.updateActionHint)
        }
      }
      .font(.callout)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// Floating capsule above the tab bar for `state.notice` (auto-dismissed) and
/// `state.error` (stays until tapped, replaced, or cleared by navigation).
/// It also posts the VoiceOver announcement the inline status line used to.
struct IOSStatusToast: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Bottom inset above the tab bar; nil pins the toast to the top edge
  /// (unlock and onboarding pages keep their primary buttons at the bottom).
  var bottomPadding: CGFloat?

  static let noticeDuration: Duration = .seconds(4)

  private var message: (text: String, isError: Bool)? {
    if !state.error.isEmpty { return (state.error, true) }
    if !state.notice.isEmpty { return (state.notice, false) }
    return nil
  }

  var body: some View {
    VStack {
      if bottomPadding != nil { Spacer() }
      if let message {
        Button {
          if message.isError { state.error = "" } else { state.notice = "" }
        } label: {
          HStack(alignment: .top, spacing: 10) {
            Image(
              systemName: message.isError
                ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
            )
            .foregroundStyle(message.isError ? AtlasTheme.loss : AtlasTheme.gain)
            .accessibilityHidden(true)
            Text(message.text)
              .font(.callout.weight(.medium))
              .foregroundStyle(AtlasTheme.ink)
              .multilineTextAlignment(.leading)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if message.isError {
              Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(AtlasTheme.ink3)
                .accessibilityHidden(true)
            }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
          .background(
            RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous)
              .fill(.regularMaterial)
          )
          .overlay {
            RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous)
              .stroke(
                (message.isError ? AtlasTheme.loss : AtlasTheme.gain).opacity(0.35),
                lineWidth: 1)
          }
          .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
          .frame(maxWidth: 560)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, bottomPadding ?? 0)
        .padding(.top, bottomPadding == nil ? 8 : 0)
        .transition(
          reduceMotion
            ? .opacity
            : .move(edge: bottomPadding == nil ? .top : .bottom).combined(with: .opacity))
        .accessibilityLabel(message.isError ? "Error: \(message.text)" : "Status: \(message.text)")
        .accessibilityHint("Dismisses the message.")
        .id(message.text)
      }
      if bottomPadding == nil { Spacer() }
    }
    .animation(
      AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion),
      value: message?.text
    )
    .task(id: state.notice) {
      let notice = state.notice
      guard !notice.isEmpty else { return }
      AtlasAccessibilityAnnouncer.shared.announceEvent(notice, kind: .notice)
      try? await Task.sleep(for: Self.noticeDuration)
      if state.notice == notice { state.notice = "" }
    }
    .onChange(of: state.error) { _, error in
      AtlasAccessibilityAnnouncer.shared.announceEvent(error, kind: .error)
    }
  }
}

// MARK: - Privacy cover

/// Opaque cover shown whenever the scene is not active, so the app switcher
/// snapshot never contains balances, addresses, revealed API keys, or a
/// recovery code.
struct IOSPrivacyCover: View {
  var body: some View {
    ZStack {
      AtlasTheme.canvas.ignoresSafeArea()
      VStack(spacing: 14) {
        Image(systemName: "lock.fill")
          .font(.system(size: 28, weight: .semibold))
          .foregroundStyle(AtlasTheme.accent)
          .frame(width: 64, height: 64)
          .background(AtlasTheme.accent.opacity(0.1))
          .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        Text("Address Atlas")
          .font(.headline)
          .foregroundStyle(AtlasTheme.ink)
      }
    }
    .accessibilityHidden(true)
  }
}

extension IOSPendingAction {
  /// The screen that owns the sheet for this action.
  var section: AtlasSection {
    switch self {
    case .addWallet: .wallets
    case .connectExchange: .exchanges
    case .addManualHolding, .addCustomToken: .tokens
    }
  }
}
