import Combine
import Foundation
import SwiftUI

/// How the portfolio is drawn. Chosen in a later phase; the preference is
/// stored now so the choice survives the switch. Raw values are persisted.
enum PortfolioVisualization: String, CaseIterable, Identifiable, Codable, Sendable {
  case map
  case ring
  case strip
  case grid
  case bubbles
  case ringsInRings
  case flow
  case list
  case overTime
  case whatChanged
  case atlasMap
  case slope
  case concentration
  case calendar

  static let `default`: PortfolioVisualization = .map

  var id: String { rawValue }

  var title: String {
    switch self {
    case .map: "Map"
    case .ring: "Ring"
    case .strip: "Strip"
    case .grid: "Grid"
    case .bubbles: "Bubbles"
    case .ringsInRings: "Rings in rings"
    case .flow: "Flow"
    case .list: "List"
    case .overTime: "Over time"
    case .whatChanged: "What changed"
    case .atlasMap: "Atlas map"
    case .slope: "Slope"
    case .concentration: "Concentration"
    case .calendar: "Calendar"
    }
  }
}

/// Display preferences: theme, light/dark choice, and the portfolio view and
/// grouping the next phase will use.
///
/// These are cosmetic and not sensitive, so they live in `UserDefaults`, not in
/// the encrypted vault, and are not synced. The store is the one source of truth
/// for the running theme: every change is pushed to `AtlasThemeRuntime`, which
/// restyles the live UI on Mac and iOS without a relaunch.
@MainActor
final class AtlasDisplayPreferences: ObservableObject {
  enum Key {
    static let theme = "display.theme.v1"
    static let appearanceMode = "display.appearanceMode.v1"
    static let portfolioVisualization = "display.portfolioVisualization.v1"
    static let portfolioGrouping = "display.portfolioGrouping.v1"
  }

  /// Grouping keys the portfolio views accept. The grouping enum itself comes
  /// from AddressAtlasCore later; until then it is stored as a raw string.
  nonisolated static let groupingValues = ["asset", "network", "source", "state", "kind"]
  nonisolated static let defaultGrouping = "asset"

  @Published var theme: AtlasThemeID {
    didSet {
      guard theme != oldValue else { return }
      defaults.set(theme.rawValue, forKey: Key.theme)
      pushToRuntime()
    }
  }

  @Published var appearanceMode: AtlasAppearanceMode {
    didSet {
      guard appearanceMode != oldValue else { return }
      defaults.set(appearanceMode.rawValue, forKey: Key.appearanceMode)
      pushToRuntime()
    }
  }

  @Published var portfolioVisualization: PortfolioVisualization {
    didSet {
      guard portfolioVisualization != oldValue else { return }
      defaults.set(portfolioVisualization.rawValue, forKey: Key.portfolioVisualization)
    }
  }

  /// One of `groupingValues`; anything else is replaced by the default.
  @Published var portfolioGrouping: String {
    didSet {
      guard portfolioGrouping != oldValue else { return }
      guard Self.groupingValues.contains(portfolioGrouping) else {
        portfolioGrouping = Self.defaultGrouping
        return
      }
      defaults.set(portfolioGrouping, forKey: Key.portfolioGrouping)
    }
  }

  private let defaults: UserDefaults

  /// The colour scheme to force on the window, or nil to follow the system.
  /// Single-mode themes force their own.
  var forcedColorScheme: ColorScheme? {
    theme.forcedColorScheme(for: appearanceMode)
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    theme = defaults.string(forKey: Key.theme).flatMap(AtlasThemeID.init(rawValue:)) ?? .default
    appearanceMode =
      defaults.string(forKey: Key.appearanceMode).flatMap(AtlasAppearanceMode.init(rawValue:))
      ?? .system
    portfolioVisualization =
      defaults.string(forKey: Key.portfolioVisualization)
      .flatMap(PortfolioVisualization.init(rawValue:)) ?? .default
    let storedGrouping = defaults.string(forKey: Key.portfolioGrouping)
    portfolioGrouping =
      storedGrouping.flatMap { Self.groupingValues.contains($0) ? $0 : nil }
      ?? Self.defaultGrouping
    pushToRuntime()
  }

  private func pushToRuntime() {
    AtlasThemeRuntime.shared.apply(theme: theme, appearanceMode: appearanceMode)
  }
}
