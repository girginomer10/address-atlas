import AddressAtlasCore
import SwiftUI

/// First-run screen, shown while the vault has no sources. One page: what the
/// app does, the three facts that matter before adding anything (wallets are
/// watch-only, exchange keys are read-only, the portfolio stays encrypted on
/// this device), and the ways forward. Finishing calls `onFinish` with the
/// task the person chose (or nil to explore the empty app first); `RootView`
/// records completion and routes the task to the screen that owns its sheet.
///
/// The actions sit in a bar at the bottom, clear of the status toast that
/// `RootView` pins to the top while this screen shows. At accessibility text
/// sizes the bar would fill the screen, so the actions scroll with the page.
struct OnboardingScreen: View {
  var onFinish: (IOSPendingAction?) -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    // DEBUGHARNESS-BEGIN
    if let mode = UserDefaults.standard.string(forKey: "AtlasDemoUnlock") {
      OnboardingUnlockHarness(mode: mode)
    } else {
      realBody
    }
  }

  @ViewBuilder private var realBody: some View {
    // DEBUGHARNESS-END
    GeometryReader { proxy in
      ScrollView {
        VStack(spacing: 20) {
          OnboardingHero()
          OnboardingFacts()
          if dynamicTypeSize.isAccessibilitySize {
            OnboardingActions(onFinish: onFinish)
              .padding(.top, 4)
          }
        }
        .padding(.horizontal, OnboardingLayout.gutter)
        .padding(.vertical, 24)
        .frame(maxWidth: OnboardingLayout.maxWidth)
        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
      }
      .scrollBounceBehavior(.basedOnSize)
      // DEBUGHARNESS-BEGIN
      .defaultScrollAnchor(UserDefaults.standard.bool(forKey: "AtlasDemoScrollBottom") ? .bottom : nil)
      // DEBUGHARNESS-END
    }
    .background(AtlasCanvasBackground().ignoresSafeArea())
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if !dynamicTypeSize.isAccessibilitySize {
        OnboardingActions(onFinish: onFinish)
          .padding(.horizontal, OnboardingLayout.gutter)
          .padding(.top, 14)
          .padding(.bottom, 12)
          .frame(maxWidth: OnboardingLayout.maxWidth)
          .frame(maxWidth: .infinity)
          .background(alignment: .top) { OnboardingBarBackground() }
      }
    }
  }
}

private enum OnboardingLayout {
  static let maxWidth: CGFloat = 520
  /// Wider than the hard card shadows of the Candy and Pixel themes, which
  /// fall to the right and below.
  static let gutter: CGFloat = 20
}

// MARK: - Content

/// The lead card: coin marks and what to do. In the themes with pastel cards
/// it takes the pastel fill, as the portfolio total does.
private struct OnboardingHero: View {
  @Environment(\.atlasTheme) private var tokens

  var body: some View {
    let hero = IOSHeroStyle.current(tokens)
    IOSCard(padding: 20, fill: hero.fill, ink: hero.ink) {
      VStack(alignment: .leading, spacing: 20) {
        OnboardingCoinRow()
        Text("Add a wallet address or an exchange to see what you hold.")
          .font(AtlasTheme.font(.display, size: 30, relativeTo: .title, weight: .bold))
          .tracking(AtlasTheme.tracking(.display, size: 30))
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          // Large display type at the largest accessibility sizes would fill
          // the screen with one sentence; the rest of the page still scales.
          .dynamicTypeSize(...DynamicTypeSize.accessibility2)
          .accessibilityAddTraits(.isHeader)
      }
    }
  }
}

/// A few asset marks in the selected theme's colours. Decorative.
private struct OnboardingCoinRow: View {
  var body: some View {
    HStack(spacing: 8) {
      TokenMonogram(symbol: "BTC", size: 40)
      TokenMonogram(symbol: "ETH", size: 40)
      TokenMonogram(symbol: "SOL", size: 40)
      TokenMonogram(symbol: "ATOM", size: 40)
    }
    .accessibilityHidden(true)
  }
}

private struct OnboardingFacts: View {
  var body: some View {
    IOSCard(padding: 18) {
      VStack(alignment: .leading, spacing: 18) {
        OnboardingFactRow(
          systemImage: "eye",
          title: "Wallets are watch-only",
          copy: "Public addresses only. No seed phrases."
        )
        OnboardingFactRow(
          systemImage: "key.horizontal",
          title: "Exchange keys must be read-only",
          copy: "Trading and withdrawals stay off."
        )
        OnboardingFactRow(
          systemImage: "lock",
          title: "Encrypted on this \(PlatformCopy.deviceNoun)",
          copy: "Nothing is ever sent for signing."
        )
      }
    }
  }
}

private struct OnboardingFactRow: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var systemImage: String
  var title: String
  var copy: String

  var body: some View {
    // At accessibility sizes the tile moves above the words, which then get
    // the whole card width instead of breaking mid-word.
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
      : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
    layout {
      OnboardingIconTile(systemImage: systemImage)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(AtlasTheme.font(.body, .callout, weight: .semibold))
          .foregroundStyle(AtlasTheme.ink)
        Text(copy)
          .font(AtlasTheme.font(.body, .callout))
          .foregroundStyle(AtlasTheme.ink2)
      }
      .fixedSize(horizontal: false, vertical: true)
      if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

/// An icon on the theme's soft accent fill, outlined in the themes that draw
/// hard edges.
private struct OnboardingIconTile: View {
  var systemImage: String

  var body: some View {
    let shape = AtlasTheme.shape
    let outline = RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous)
    Image(systemName: systemImage)
      .font(AtlasTheme.font(.body, .body, weight: .semibold))
      // The tile is a fixed size, so the glyph stops growing with it.
      .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
      .foregroundStyle(AtlasTheme.accent)
      .frame(width: 40, height: 40)
      .background(AtlasTheme.accentSoft, in: outline)
      .overlay {
        if shape.hasBoldBorders {
          outline.stroke(AtlasTheme.outline, lineWidth: 1.5)
        }
      }
      .accessibilityHidden(true)
  }
}

// MARK: - Actions

private struct OnboardingActions: View {
  var onFinish: (IOSPendingAction?) -> Void

  var body: some View {
    VStack(spacing: 12) {
      Button {
        onFinish(.addWallet)
      } label: {
        OnboardingActionLabel(title: "Add wallet", systemImage: "wallet.pass.fill")
      }
      .buttonStyle(AtlasPrimaryButtonStyle())
      .accessibilityHint("Opens the wallet form. You paste a public address.")
      .accessibilityIdentifier("onboarding-add-wallet")

      Button {
        onFinish(.connectExchange)
      } label: {
        OnboardingActionLabel(title: "Connect exchange", systemImage: "building.columns.fill")
      }
      .buttonStyle(AtlasSecondaryButtonStyle())
      .accessibilityHint("Opens the exchange form. You enter a read-only API key.")
      .accessibilityIdentifier("onboarding-connect-exchange")

      Button {
        onFinish(nil)
      } label: {
        Text("Skip")
          .font(AtlasTheme.font(.body, .callout, weight: .medium))
          .foregroundStyle(AtlasTheme.ink2)
          .frame(maxWidth: .infinity, minHeight: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint("Opens the app without adding anything. You can add a wallet or an exchange later.")
      .accessibilityIdentifier("onboarding-skip")
    }
  }
}

/// A button label that fills the width, with a 44pt touch target. At
/// accessibility sizes the icon goes, so the words get the room.
private struct OnboardingActionLabel: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var title: String
  var systemImage: String

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        Text(title).multilineTextAlignment(.center)
      } else {
        Label(title, systemImage: systemImage)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 44)
    .contentShape(Rectangle())
  }
}

/// The bottom bar's surface: the canvas with the same top rule as the tab bar.
private struct OnboardingBarBackground: View {
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let shape = AtlasTheme.shape
    AtlasTheme.canvas
      .overlay(alignment: .top) {
        Rectangle()
          .fill(shape.hasBoldBorders ? AtlasTheme.outline : AtlasTheme.ruleSoft)
          .frame(height: shape.hasBoldBorders || contrast == .increased ? 2 : 1)
      }
      .ignoresSafeArea(edges: .bottom)
  }
}

// DEBUGHARNESS-BEGIN
private struct OnboardingUnlockHarness: View {
  @EnvironmentObject private var state: AppState
  var mode: String
  var body: some View {
    UnlockScreen()
      .task {
        switch mode {
        case "error":
          state.error = "The encryption key for this device isn't available in Keychain."
        case "damaged":
          state.damagedVaultRecoveryAvailability = .validatedRollbackCheckpoint
          state.error = "Your saved portfolio on this device is damaged, but an earlier copy was checked and is intact. Restore the earlier copy, or set the damaged data aside and start fresh. Nothing has been deleted."
        case "quarantine":
          state.damagedVaultRecoveryAvailability = .quarantineOnly
          state.error = "Your saved portfolio on this device is damaged and no earlier copy is available."
        default: break
        }
      }
  }
}
// DEBUGHARNESS-END
