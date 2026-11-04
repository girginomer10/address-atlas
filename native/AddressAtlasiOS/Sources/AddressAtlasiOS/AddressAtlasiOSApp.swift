import AddressAtlasCore
import SwiftUI

@main
struct AddressAtlasiOSApp: App {
  @StateObject private var state = AddressAtlasiOSApp.makeState()
  /// Theme, light/dark choice and portfolio view preferences. Not sensitive,
  /// so they live in UserDefaults rather than the encrypted vault.
  @StateObject private var displayPreferences = AtlasDisplayPreferences()

  @MainActor
  private static func makeState() -> AppState {
    #if DEBUG
      // Debug builds only: `-AtlasDemoFixture` boots a throw-away vault with
      // synthetic data (see DemoFixture.swift). Release builds never compile it.
      if DemoFixture.isEnabled { return DemoFixture.makeState() }
    #endif
    return AppState(endpointConfigTrustStore: AppState.productionEndpointConfigTrustStore())
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(state)
        .environmentObject(displayPreferences)
        .atlasThemeRoot(displayPreferences)
    }
  }
}
