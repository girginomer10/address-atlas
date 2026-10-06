import AddressAtlasCore
import SwiftUI

/// First-run walkthrough. Three short pages: what the app is, how it stays
/// private, and the first task. Finishing calls `onFinish` with the task the
/// person chose (or nil to explore the empty app first); `RootView` records
/// completion and routes the task to the screen that owns its sheet.
struct OnboardingScreen: View {
  var onFinish: (IOSPendingAction?) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var page = 0

  private static let pageCount = 3
  private var isLastPage: Bool { page == Self.pageCount - 1 }

  var body: some View {
    VStack(spacing: 0) {
      topBar

      TabView(selection: $page) {
        OnboardingWelcomePage()
          .tag(0)
        OnboardingHowItWorksPage()
          .tag(1)
        OnboardingGetStartedPage(onFinish: onFinish)
          .tag(2)
      }
      .tabViewStyle(.page(indexDisplayMode: .never))
      .animation(AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion), value: page)

      bottomBar
    }
    .background(OnboardingBackdrop().ignoresSafeArea())
  }

  // MARK: - Chrome

  private var topBar: some View {
    HStack {
      Spacer()
      // Removed (not just hidden) on the last page, where "Explore first"
      // does the same, so VoiceOver never reaches an invisible button.
      if !isLastPage {
        Button("Skip") { onFinish(nil) }
          .font(.body.weight(.medium))
          .foregroundStyle(AtlasTheme.ink2)
          .frame(minWidth: 44, minHeight: 44)
          .padding(.horizontal, 8)
          .accessibilityHint("Closes the introduction. You can add a wallet or exchange later.")
          .accessibilityIdentifier("onboarding-skip")
          .transition(.opacity)
      }
    }
    .animation(AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion), value: isLastPage)
    .padding(.horizontal, 8)
    .frame(height: 52)
  }

  private var bottomBar: some View {
    VStack(spacing: 18) {
      OnboardingPageIndicator(page: page, count: Self.pageCount)

      Group {
        if isLastPage {
          Button {
            onFinish(nil)
          } label: {
            Text("Explore first")
              .font(.body.weight(.medium))
              .foregroundStyle(AtlasTheme.ink2)
              .frame(maxWidth: .infinity, minHeight: 50)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityHint("Opens the app without adding anything yet.")
          .accessibilityIdentifier("onboarding-explore")
        } else {
          Button {
            withAnimation(AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion)) {
              page = min(page + 1, Self.pageCount - 1)
            }
          } label: {
            Text("Continue")
              .font(.body.weight(.semibold))
              .frame(maxWidth: .infinity, minHeight: 50)
          }
          .buttonStyle(OnboardingPrimaryButtonStyle())
          .accessibilityIdentifier("onboarding-continue")
        }
      }
      .frame(maxWidth: OnboardingLayout.maxWidth)
    }
    .padding(.horizontal, 24)
    .padding(.top, 8)
    .padding(.bottom, 16)
  }
}

private enum OnboardingLayout {
  static let maxWidth: CGFloat = 480
}

// MARK: - Pages

/// Shared scaffold: the hero sits above a large headline and a short line of
/// body copy. Each page scrolls so accessibility text sizes never clip, and
/// content is capped and centered for iPad.
private struct OnboardingPageScaffold<Hero: View, Content: View>: View {
  var headline: String
  var message: String?
  @ViewBuilder var hero: () -> Hero
  @ViewBuilder var content: () -> Content

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(spacing: 28) {
          hero()
            .frame(maxWidth: .infinity)
            .padding(.top, 8)

          VStack(spacing: 12) {
            Text(headline)
              .font(.system(.largeTitle, design: .rounded).weight(.bold))
              .tracking(-0.6)
              .multilineTextAlignment(.center)
              .foregroundStyle(AtlasTheme.ink)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityAddTraits(.isHeader)
            if let message {
              Text(message)
                .font(.title3)
                .foregroundStyle(AtlasTheme.ink2)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            }
          }

          content()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: OnboardingLayout.maxWidth)
        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
  }
}

private struct OnboardingWelcomePage: View {
  var body: some View {
    OnboardingPageScaffold(
      headline: "Your whole crypto portfolio, in one private place",
      message: "Wallets and exchanges together, without handing over a single key."
    ) {
      OnboardingHero(
        centerSymbol: "map.fill",
        satellites: ["bitcoinsign", "building.columns.fill", "wallet.pass.fill", "chart.pie.fill"]
      )
    } content: {
      EmptyView()
    }
  }
}

private struct OnboardingHowItWorksPage: View {
  var body: some View {
    OnboardingPageScaffold(headline: "Read-only by design", message: nil) {
      OnboardingHero(
        centerSymbol: "lock.shield.fill",
        satellites: ["eye.fill", "key.horizontal.fill", "icloud.fill"],
        compact: true
      )
    } content: {
      VStack(alignment: .leading, spacing: 20) {
        IOSFactRow(
          systemImage: "eye",
          title: "Watch-only wallets",
          copy: "Paste public addresses. No seed phrases, no signing."
        )
        IOSFactRow(
          systemImage: "key.horizontal",
          title: "Read-only exchanges",
          copy: "Connect with keys that can't trade or withdraw."
        )
        IOSFactRow(
          systemImage: "lock.shield",
          title: "Encrypted on this \(PlatformCopy.deviceNoun)",
          copy: "Plus an optional encrypted copy in your iCloud."
        )
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: AtlasRadius.large, style: .continuous)
          .fill(AtlasTheme.surface)
      )
      .overlay {
        RoundedRectangle(cornerRadius: AtlasRadius.large, style: .continuous)
          .stroke(AtlasTheme.ruleSoft, lineWidth: 1)
      }
    }
  }
}

private struct OnboardingGetStartedPage: View {
  var onFinish: (IOSPendingAction?) -> Void

  var body: some View {
    OnboardingPageScaffold(
      headline: "Start with one source",
      message: "You can add more anytime."
    ) {
      OnboardingHero(centerSymbol: "plus", satellites: [], compact: true)
    } content: {
      VStack(spacing: 12) {
        OnboardingChoiceCard(
          systemImage: "wallet.pass.fill",
          title: "Add a wallet address",
          detail: "Paste any public address",
          isPrimary: true
        ) {
          onFinish(.addWallet)
        }
        .accessibilityIdentifier("onboarding-add-wallet")

        OnboardingChoiceCard(
          systemImage: "building.columns.fill",
          title: "Connect an exchange",
          detail: "With a read-only API key",
          isPrimary: false
        ) {
          onFinish(.connectExchange)
        }
        .accessibilityIdentifier("onboarding-connect-exchange")
      }
    }
  }
}

// MARK: - Pieces

private struct OnboardingChoiceCard: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var systemImage: String
  var title: String
  var detail: String
  var isPrimary: Bool
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 14) {
        // At accessibility sizes the words need the whole width.
        if !dynamicTypeSize.isAccessibilitySize {
          Image(systemName: systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(isPrimary ? AtlasTheme.paper : AtlasTheme.accent)
            .frame(width: 46, height: 46)
            .background(
              RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isPrimary ? AtlasTheme.paper.opacity(0.18) : AtlasTheme.accent.opacity(0.1))
            )
            .accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.body.weight(.semibold))
            .foregroundStyle(isPrimary ? AtlasTheme.paper : AtlasTheme.ink)
          Text(detail)
            .font(.subheadline)
            .foregroundStyle(isPrimary ? AtlasTheme.paper.opacity(0.82) : AtlasTheme.ink3)
            .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.leading)
        Spacer(minLength: 8)
        if !dynamicTypeSize.isAccessibilitySize {
          Image(systemName: "chevron.right")
            .font(.footnote.weight(.bold))
            .foregroundStyle(isPrimary ? AtlasTheme.paper.opacity(0.8) : AtlasTheme.ink3)
            .accessibilityHidden(true)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: AtlasRadius.large, style: .continuous)
          .fill(isPrimary ? AnyShapeStyle(OnboardingAccentFill()) : AnyShapeStyle(AtlasTheme.surface))
      )
      .overlay {
        RoundedRectangle(cornerRadius: AtlasRadius.large, style: .continuous)
          .stroke(isPrimary ? AtlasTheme.accent.opacity(0.3) : AtlasTheme.ruleSoft, lineWidth: 1)
      }
      .shadow(color: isPrimary ? AtlasTheme.accent.opacity(0.22) : .black.opacity(0.05), radius: 12, y: 5)
      .contentShape(RoundedRectangle(cornerRadius: AtlasRadius.large, style: .continuous))
    }
    .buttonStyle(OnboardingPressStyle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
    .accessibilityHint(detail)
  }
}

private struct OnboardingAccentFill: ShapeStyle {
  func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
    LinearGradient(
      colors: [AtlasTheme.accent, AtlasTheme.accent.opacity(0.8)],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }
}

/// Brand-colored illustration built from SF Symbols: soft concentric rings,
/// an app-icon-style tile, and small satellite badges. The entrance motion is
/// skipped entirely with Reduce Motion.
private struct OnboardingHero: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var centerSymbol: String
  var satellites: [String]
  var compact = false

  @State private var appeared = false

  private var diameter: CGFloat {
    if dynamicTypeSize.isAccessibilitySize { return compact ? 120 : 150 }
    return compact ? 190 : 250
  }

  private var tileSize: CGFloat { diameter * 0.36 }

  var body: some View {
    ZStack {
      ForEach(0..<3, id: \.self) { ring in
        Circle()
          .stroke(AtlasTheme.accent.opacity(0.14 - Double(ring) * 0.035), lineWidth: 1)
          .frame(width: diameter * (0.62 + CGFloat(ring) * 0.19))
      }
      Circle()
        .fill(
          RadialGradient(
            colors: [AtlasTheme.accent.opacity(0.16), AtlasTheme.accent.opacity(0)],
            center: .center,
            startRadius: 0,
            endRadius: diameter * 0.5
          )
        )
        .frame(width: diameter, height: diameter)

      RoundedRectangle(cornerRadius: tileSize * 0.28, style: .continuous)
        .fill(
          LinearGradient(
            colors: [AtlasTheme.accent, AtlasTheme.accent.opacity(0.72)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .frame(width: tileSize, height: tileSize)
        .overlay {
          Image(systemName: centerSymbol)
            .font(.system(size: tileSize * 0.42, weight: .semibold))
            .foregroundStyle(AtlasTheme.paper)
        }
        .shadow(color: AtlasTheme.accent.opacity(0.3), radius: 16, y: 8)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.86)

      ForEach(Array(satellites.enumerated()), id: \.offset) { index, symbol in
        satellite(symbol)
          .offset(satelliteOffset(index: index))
          .scaleEffect(appeared || reduceMotion ? 1 : 0.4)
          .opacity(appeared || reduceMotion ? 1 : 0)
          .animation(
            reduceMotion ? nil : AtlasMotion.standard.delay(0.08 * Double(index + 1)),
            value: appeared
          )
      }
    }
    .frame(width: diameter, height: diameter)
    .animation(reduceMotion ? nil : AtlasMotion.standard, value: appeared)
    .onAppear { appeared = true }
    .accessibilityHidden(true)
  }

  private func satellite(_ symbol: String) -> some View {
    let size = diameter * 0.2
    return Circle()
      .fill(AtlasTheme.surface)
      .frame(width: size, height: size)
      .overlay {
        Circle().stroke(AtlasTheme.ruleSoft, lineWidth: 1)
      }
      .overlay {
        Image(systemName: symbol)
          .font(.system(size: size * 0.4, weight: .semibold))
          .foregroundStyle(AtlasTheme.accent)
      }
      .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
  }

  /// Satellites sit on the middle ring, starting at the upper left and
  /// spread evenly around it.
  private func satelliteOffset(index: Int) -> CGSize {
    guard !satellites.isEmpty else { return .zero }
    let radius = diameter * (0.62 + 0.19) / 2
    let start = satellites.count == 4 ? -Double.pi * 0.75 : -Double.pi / 2
    let angle = start + Double(index) * (2 * Double.pi / Double(satellites.count))
    return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
  }
}

private struct OnboardingPageIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var page: Int
  var count: Int

  var body: some View {
    HStack(spacing: 8) {
      ForEach(0..<count, id: \.self) { index in
        Capsule()
          .fill(index == page ? AtlasTheme.accent : AtlasTheme.ink3.opacity(0.3))
          .frame(width: index == page ? 22 : 8, height: 8)
      }
    }
    .animation(AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion), value: page)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Page \(page + 1) of \(count)")
  }
}

private struct OnboardingBackdrop: View {
  var body: some View {
    ZStack {
      AtlasTheme.canvas
      LinearGradient(
        colors: [AtlasTheme.accent.opacity(0.08), AtlasTheme.accent.opacity(0)],
        startPoint: .top,
        endPoint: .center
      )
    }
  }
}

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(AtlasTheme.paper)
      .background(
        RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous)
          .fill(AtlasTheme.accent.opacity(configuration.isPressed ? 0.84 : 1))
      )
      .shadow(color: AtlasTheme.accent.opacity(0.22), radius: 10, y: 4)
      .contentShape(RoundedRectangle(cornerRadius: AtlasRadius.card, style: .continuous))
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .animation(
        AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
        value: configuration.isPressed
      )
  }
}

private struct OnboardingPressStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .opacity(configuration.isPressed ? 0.92 : 1)
      .animation(
        AtlasMotion.animation(AtlasMotion.quick, reduceMotion: reduceMotion),
        value: configuration.isPressed
      )
  }
}
