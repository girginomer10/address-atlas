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
  /// Theme, light/dark choice and portfolio view preferences. Not sensitive,
  /// so they live in UserDefaults rather than the encrypted vault.
  @StateObject private var displayPreferences = AtlasDisplayPreferences()
  /// The open section, shared with the menu commands.
  @StateObject private var navigation = MacNavigationModel()

  var body: some Scene {
    Window("Address Atlas", id: "main") {
      RootView(navigation: navigation)
        .environmentObject(appDelegate.state)
        .environmentObject(displayPreferences)
        .atlasThemeRoot(displayPreferences)
        .task {
          await appDelegate.state.unlock()
        }
    }
    .windowStyle(.hiddenTitleBar)
    .commands {
      AtlasCommands(state: appDelegate.state, navigation: navigation)
    }

    Settings {
      SettingsView()
        .environmentObject(appDelegate.state)
        .environmentObject(displayPreferences)
        .atlasThemeRoot(displayPreferences)
        .frame(minWidth: 900, minHeight: 650)
        .background(AtlasTheme.canvas)
    }
  }
}

/// Menu commands: ⌘N adds a wallet, ⌘F finds an asset, ⌘R scans, ⌘1 to ⌘7 open
/// the sections. They only act while the vault is unlocked.
struct AtlasCommands: Commands {
  @ObservedObject var state: AppState
  @ObservedObject var navigation: MacNavigationModel

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("Add Wallet") { navigate { navigation.requestAddWallet() } }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(!state.isUnlocked)
    }
    CommandGroup(after: .textEditing) {
      Button("Find Asset") { navigate { navigation.requestFind() } }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(!state.isUnlocked)
    }
    CommandMenu("Portfolio") {
      Button(state.scanning ? "Cancel Scan" : "Scan") { MacScanAction.perform(state) }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(!state.isUnlocked || !MacScanAction.isAvailable(state))
    }
    CommandMenu("Go") {
      ForEach(MainView.Section.allCases) { section in
        Button(section.title) { navigate { navigation.go(section) } }
          .keyboardShortcut(
            KeyEquivalent(Character("\(section.shortcutDigit)")), modifiers: .command
          )
          .disabled(!state.isUnlocked)
      }
    }
  }

  private func navigate(_ action: () -> Void) {
    state.clearTransientMessagesForNavigation()
    action()
  }
}

struct RootView: View {
  @EnvironmentObject private var state: AppState
  var navigation: MacNavigationModel

  private var autoRefreshTaskID: String {
    "\(state.isUnlocked)-\(state.document.preferences.autoRefresh)"
  }

  private var endpointConfigRefreshTaskID: String {
    "\(state.isUnlocked)-\(state.document.syncState.serverURL)"
  }

  var body: some View {
    Group {
      if state.isUnlocked {
        MainView(navigation: navigation)
      } else {
        UnlockView()
      }
    }
    .background(AtlasTheme.paper)
    .foregroundStyle(AtlasTheme.ink)
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
  }
}

struct UnlockView: View {
  @EnvironmentObject private var state: AppState
  @State private var restoreCode = ""
  @State private var confirmsDamagedVaultQuarantine = false

  var body: some View {
    ZStack {
      AtlasCanvasBackground()
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          MacBrand()
            .padding(.bottom, 4)

          unlockCard

          if let recovery = state.damagedVaultRecoveryAvailability {
            damagedVaultCard(recovery)
          }

          recoveryCard

          Surface(style: .subtle) {
            PrivacySafeDiagnosticsControls()
          }

          StatusLine()
        }
        .padding(36)
        .frame(maxWidth: 600, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
    }
    .frame(minWidth: 800, minHeight: 560)
    .confirmationDialog(
      "Save the damaged vault and start clean?",
      isPresented: $confirmsDamagedVaultQuarantine,
      titleVisibility: .visible
    ) {
      Button("Save aside and start clean", role: .destructive) {
        Task { await state.quarantineDamagedVaultAndStartClean() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Address Atlas first checks that a durable private copy of vault.sqlite and its sidecar files exists. Then it starts an empty local vault with the same Keychain key. Nothing is downloaded automatically."
      )
    }
  }

  private var unlockCard: some View {
    Surface(style: .accent) {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Vault locked")
            .font(AtlasTheme.font(.display, .title2, weight: .bold))
            .accessibilityAddTraits(.isHeader)
          Text("Your portfolio is encrypted. The key is in Keychain.")
            .font(AtlasTheme.font(.body, .callout))
            .foregroundStyle(AtlasTheme.ink2)
        }
        Button {
          Task { await state.unlock() }
        } label: {
          if state.isUnlocking {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Text("Unlocking\u{2026}")
            }
          } else {
            Label("Unlock", systemImage: "lock.open.fill")
          }
        }
        .buttonStyle(MacPrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(state.isUnlocking)
      }
    }
  }

  @ViewBuilder
  private func damagedVaultCard(_ recovery: DamagedVaultRecoveryAvailability) -> some View {
    Surface(style: .warning) {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 4) {
          Text("The local vault needs attention")
            .font(AtlasTheme.font(.display, .headline, weight: .bold))
            .accessibilityAddTraits(.isHeader)
          Text(
            recovery == .validatedRollbackCheckpoint
              ? "A verified, encrypted restore point is available."
              : "You can save the damaged database aside and start clean."
          )
          .font(AtlasTheme.font(.body, .callout))
          .foregroundStyle(AtlasTheme.ink2)
        }
        if recovery == .validatedRollbackCheckpoint {
          Button("Restore the earlier copy") {
            Task { await state.recoverDamagedVaultFromRollbackCheckpoint() }
          }
          .buttonStyle(MacPrimaryButtonStyle())
          .disabled(state.isUnlocking)
        }
        Button("Save damaged vault and start clean", role: .destructive) {
          confirmsDamagedVaultQuarantine = true
        }
        .buttonStyle(MacSecondaryButtonStyle())
        .disabled(state.isUnlocking)
      }
    }
  }

  private var recoveryCard: some View {
    Surface {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Restore Keychain access")
            .font(AtlasTheme.font(.display, .headline, weight: .bold))
            .accessibilityAddTraits(.isHeader)
          Text("Use your recovery file and the code you stored apart from it.")
            .font(AtlasTheme.font(.body, .callout))
            .foregroundStyle(AtlasTheme.ink2)
        }
        AdaptiveStack(horizontalSpacing: 12) {
          SecureField("Recovery code", text: $restoreCode)
            .textFieldStyle(AtlasTextFieldStyle())
            .accessibilityLabel("Recovery code")
          Button("Choose recovery file") {
            restoreRecoveryKit()
          }
          .buttonStyle(MacSecondaryButtonStyle())
          .disabled(
            state.isUnlocking
              || restoreCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Text("The file is checked before anything in Keychain changes.")
          .font(AtlasTheme.font(.label, .caption))
          .foregroundStyle(AtlasTheme.ink3)
      }
    }
  }

  private func restoreRecoveryKit() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "atlas-recovery") ?? .data]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    if panel.runModal() == .OK, let url = panel.url {
      let isAccessing = url.startAccessingSecurityScopedResource()
      Task {
        defer {
          if isAccessing {
            url.stopAccessingSecurityScopedResource()
          }
        }
        await state.restoreRecoveryKit(from: url, recoveryCode: restoreCode)
      }
    }
  }
}
