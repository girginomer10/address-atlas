import AddressAtlasCore
import SwiftUI

// Placeholder; replaced by the real unlock/recovery screen.
struct UnlockScreen: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    NavigationStack {
      IOSPage(title: "Address Atlas") {
        Surface(style: .accent) {
          VStack(alignment: .leading, spacing: 12) {
            BrandLockup()
            Button {
              Task { await state.unlock() }
            } label: {
              Label("Unlock vault", systemImage: "lock.open.fill")
            }
            .buttonStyle(AtlasPrimaryButtonStyle())
            .disabled(state.isUnlocking)
          }
        }
      }
    }
  }
}
