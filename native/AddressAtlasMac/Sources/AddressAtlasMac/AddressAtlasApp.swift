import AddressAtlasCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct AddressAtlasMacApp: App {
  @StateObject private var state = AppState(
    endpointConfigTrustStore: AppState.productionEndpointConfigTrustStore()
  )

  var body: some Scene {
    Window("Address Atlas", id: "main") {
      RootView()
        .environmentObject(state)
        .task {
          await state.unlock()
        }
    }
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .newItem) {}
    }
  }
}

struct RootView: View {
  @EnvironmentObject private var state: AppState

  private var autoRefreshTaskID: String {
    "\(state.isUnlocked)-\(state.document.preferences.autoRefresh)"
  }

  private var endpointConfigRefreshTaskID: String {
    "\(state.isUnlocked)-\(state.document.syncState.serverURL)"
  }

  var body: some View {
    Group {
      if state.isUnlocked {
        MainView()
      } else {
        UnlockView()
      }
    }
    .background(AtlasTheme.paper)
    .foregroundStyle(AtlasTheme.ink)
    .preferredColorScheme(.light)
    .tint(AtlasTheme.accent)
    .task(id: autoRefreshTaskID) {
      guard state.isUnlocked, state.document.preferences.autoRefresh else { return }
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(15 * 60))
        } catch {
          return
        }
        guard state.isUnlocked,
          state.document.preferences.autoRefresh,
          state.hasScanSources,
          !state.scanning,
          !state.syncing,
          !state.syncPersistencePending
        else { continue }
        state.startScan()
      }
    }
    .task(id: endpointConfigRefreshTaskID) {
      await state.runEndpointConfigRefreshLoop()
    }
  }
}

struct UnlockView: View {
  @EnvironmentObject private var state: AppState
  @State private var restoreCode = ""

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 22) {
        BrandLockup()
        Spacer()
        Text("Encrypted local vault")
          .font(.system(size: 58, weight: .regular, design: .serif))
          .italic()
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        Text(
          "A random 256-bit vault key lives in macOS Keychain. Portfolio data, exchange credentials, scan history, and sync blobs stay encrypted before storage."
        )
        .font(.system(size: 15))
        .foregroundStyle(AtlasTheme.ink2)
        .lineSpacing(4)
        .frame(maxWidth: 560, alignment: .leading)
        Button {
          Task { await state.unlock() }
        } label: {
          if state.isUnlocking {
            Label("Unlocking...", systemImage: "hourglass")
          } else {
            Label("Unlock vault", systemImage: "lock.open")
          }
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        .disabled(state.isUnlocking)
        VStack(alignment: .leading, spacing: 9) {
          AtlasLabel("Lost Keychain access?")
          Text(
            "Restore the vault key with the recovery file and code. The file is verified before Keychain is changed."
          )
          .font(.system(size: 12))
          .foregroundStyle(AtlasTheme.ink2)
          HStack(spacing: 10) {
            SecureField("Recovery code", text: $restoreCode)
              .textFieldStyle(AtlasTextFieldStyle())
              .accessibilityLabel("Recovery code")
            Button("Restore recovery kit") {
              restoreRecoveryKit()
            }
            .buttonStyle(AtlasSecondaryButtonStyle())
            .disabled(
              state.isUnlocking
                || restoreCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
        .frame(maxWidth: 620, alignment: .leading)
        Spacer()
        StatusLine()
      }
      .padding(42)
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 20) {
        SidebarTrustLine(title: "No signing", copy: "Public addresses only")
        SidebarTrustLine(title: "No custody", copy: "Private keys never enter the app")
        SidebarTrustLine(title: "Zero knowledge sync", copy: "Server stores opaque vault snapshots")
      }
      .padding(34)
      .frame(width: 340)
      .frame(maxHeight: .infinity, alignment: .topLeading)
      .background(AtlasTheme.paper2)
      .overlay(alignment: .leading) {
        Rectangle().fill(AtlasTheme.rule).frame(width: 1)
      }
    }
    .frame(minWidth: 980, minHeight: 640)
  }

  private func restoreRecoveryKit() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "atlas-recovery") ?? .data]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    if panel.runModal() == .OK, let url = panel.url {
      Task {
        await state.restoreRecoveryKit(from: url, recoveryCode: restoreCode)
      }
    }
  }
}
