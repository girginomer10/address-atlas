import AddressAtlasCore
import SwiftUI

@main
struct AddressAtlasiOSApp: App {
  @StateObject private var state = AppState(
    endpointConfigTrustStore: AppState.productionEndpointConfigTrustStore()
  )
  /// Theme, light/dark choice and portfolio view preferences. Not sensitive,
  /// so they live in UserDefaults rather than the encrypted vault.
  @StateObject private var displayPreferences = AtlasDisplayPreferences()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(state)
        .environmentObject(displayPreferences)
        .atlasThemeRoot(displayPreferences)
    }
  }
}
