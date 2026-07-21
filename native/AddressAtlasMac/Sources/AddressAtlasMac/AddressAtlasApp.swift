import AddressAtlasCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AddressAtlasApplicationDelegate: NSObject, NSApplicationDelegate {
  let state: AppState
  private var terminationTask: Task<Void, Never>?

  override init() {
    state = AppState(
      endpointConfigTrustStore: AppState.productionEndpointConfigTrustStore()
    )
    super.init()
  }

  init(state: AppState) {
    self.state = state
    super.init()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    requestTermination { shouldTerminate in
      sender.reply(toApplicationShouldTerminate: shouldTerminate)
    }
  }

  @discardableResult
  func requestTermination(
    reply: @escaping @MainActor (Bool) -> Void
  ) -> NSApplication.TerminateReply {
    guard terminationTask == nil else { return .terminateLater }
    guard state.beginTerminationRequest() else { return .terminateLater }

    terminationTask = Task { @MainActor [weak self] in
      guard let self else {
        reply(false)
        return
      }
      let shouldTerminate = await state.prepareForTermination()
      terminationTask = nil
      reply(shouldTerminate)
    }
    return .terminateLater
  }
}

@main
struct AddressAtlasMacApp: App {
  @NSApplicationDelegateAdaptor(AddressAtlasApplicationDelegate.self)
  private var appDelegate

  var body: some Scene {
    Window("Address Atlas", id: "main") {
      RootView()
        .environmentObject(appDelegate.state)
        .task {
          await appDelegate.state.unlock()
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
    .disabled(state.isTerminationInProgress)
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
  @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 58

  var body: some View {
    HStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          BrandLockup()
          Spacer(minLength: 22)
          Text("Encrypted local vault")
            .font(.system(size: titleSize, weight: .regular, design: .serif))
            .italic()
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
          Text(
            "A random 256-bit vault key lives in macOS Keychain. Portfolio data, exchange credentials, scan history, and sync blobs stay encrypted before storage."
          )
          .font(.body)
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
            .font(.callout)
            .foregroundStyle(AtlasTheme.ink2)
            AdaptiveStack {
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
          Spacer(minLength: 22)
          StatusLine()
        }
        .padding(36)
        .frame(maxWidth: .infinity, minHeight: 560, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 20) {
        SidebarTrustLine(title: "No signing", copy: "Public addresses only")
        SidebarTrustLine(title: "No custody", copy: "Private keys never enter the app")
        SidebarTrustLine(title: "Zero knowledge sync", copy: "Server stores opaque vault snapshots")
      }
      .padding(34)
      .frame(width: 300)
      .frame(maxHeight: .infinity, alignment: .topLeading)
      .background(AtlasTheme.paper2)
      .overlay(alignment: .leading) {
        Rectangle().fill(AtlasTheme.rule).frame(width: 1)
      }
    }
    .frame(minWidth: 800, minHeight: 560)
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
