import AddressAtlasCore
import SwiftUI

/// First-run walkthrough. Finishing calls `onFinish` with the first task the
/// person chose (or nil to explore the empty app).
struct OnboardingScreen: View {
  var onFinish: (IOSPendingAction?) -> Void

  var body: some View {
    VStack(spacing: 20) {
      BrandLockup()
      Button("Add a wallet") { onFinish(.addWallet) }
        .buttonStyle(AtlasPrimaryButtonStyle())
      Button("Not now") { onFinish(nil) }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AtlasTheme.canvas)
  }
}
