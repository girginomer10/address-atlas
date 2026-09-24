import AddressAtlasCore
import SwiftUI

@main
struct AddressAtlasiOSApp: App {
  @StateObject private var state = AppState(
    endpointConfigTrustStore: AppState.productionEndpointConfigTrustStore()
  )

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(state)
    }
  }
}
