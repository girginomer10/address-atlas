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
  @State private var confirmsDamagedVaultQuarantine = false
  @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 48

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [AtlasTheme.canvas, AtlasTheme.surfaceMuted.opacity(0.28)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      HStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            BrandLockup()

            VStack(alignment: .leading, spacing: 14) {
              Label("Local-first portfolio security", systemImage: "lock.shield.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(AtlasTheme.accent)
              Text("Your portfolio,\nprivate by default.")
                .font(.system(size: titleSize, weight: .bold, design: .rounded))
                .tracking(-1.2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
              Text(
                "Your vault key stays in macOS Keychain. Portfolio data, exchange credentials, scan history, and sync snapshots are encrypted before storage."
              )
              .font(.body)
              .foregroundStyle(AtlasTheme.ink2)
              .lineSpacing(3)
              .frame(maxWidth: 620, alignment: .leading)
            }

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
          .frame(maxWidth: 760, minHeight: 600, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        trustPanel
      }
    }
    .frame(minWidth: 800, minHeight: 560)
    .confirmationDialog(
      "Preserve damaged vault and start clean?",
      isPresented: $confirmsDamagedVaultQuarantine,
      titleVisibility: .visible
    ) {
      Button("Preserve in quarantine and start clean", role: .destructive) {
        Task { await state.quarantineDamagedVaultAndStartClean() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Address Atlas will first verify a crash-durable private copy of vault.sqlite and every present SQLite sidecar. Only then will it activate an empty local vault using the same Keychain key. Nothing will be downloaded automatically."
      )
    }
  }

  private var unlockCard: some View {
    Surface(style: .accent) {
      AdaptiveStack(horizontalSpacing: 18) {
        PanelHeader(
          title: "Encrypted local vault",
          subtitle: "Protected by a random 256-bit key in Keychain",
          systemImage: "lock.fill"
        )
        Button {
          Task { await state.unlock() }
        } label: {
          if state.isUnlocking {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Text("Unlocking…")
            }
          } else {
            Label("Unlock vault", systemImage: "lock.open.fill")
          }
        }
        .buttonStyle(AtlasPrimaryButtonStyle())
        .disabled(state.isUnlocking)
      }
    }
  }

  @ViewBuilder
  private func damagedVaultCard(_ recovery: DamagedVaultRecoveryAvailability) -> some View {
    Surface(style: .warning) {
      VStack(alignment: .leading, spacing: 14) {
        PanelHeader(
          title: "Local vault needs attention",
          subtitle: recovery == .validatedRollbackCheckpoint
            ? "A verified encrypted restore point is available"
            : "The damaged database can be preserved before starting clean",
          systemImage: "exclamationmark.shield.fill",
          tint: AtlasTheme.warning
        )
        if recovery == .validatedRollbackCheckpoint {
          Button("Restore verified rollback point") {
            Task { await state.recoverDamagedVaultFromRollbackCheckpoint() }
          }
          .buttonStyle(AtlasPrimaryButtonStyle())
          .disabled(state.isUnlocking)
        }
        Button("Preserve damaged vault and start clean", role: .destructive) {
          confirmsDamagedVaultQuarantine = true
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        .disabled(state.isUnlocking)
      }
    }
  }

  private var recoveryCard: some View {
    Surface {
      VStack(alignment: .leading, spacing: 16) {
        PanelHeader(
          title: "Restore Keychain access",
          subtitle: "Use your recovery file and separately stored code",
          systemImage: "key.fill"
        )
        AdaptiveStack(horizontalSpacing: 12) {
          SecureField("Recovery code", text: $restoreCode)
            .textFieldStyle(AtlasTextFieldStyle())
            .accessibilityLabel("Recovery code")
          Button("Choose recovery file") {
            restoreRecoveryKit()
          }
          .buttonStyle(AtlasSecondaryButtonStyle())
          .disabled(
            state.isUnlocking
              || restoreCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Text("The recovery file is verified before anything in Keychain is changed.")
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
      }
    }
  }

  private var trustPanel: some View {
    VStack(alignment: .leading, spacing: 28) {
      Badge("Zero custody", color: AtlasTheme.gain)
      VStack(alignment: .leading, spacing: 10) {
        Text("Everything you track.\nNothing to hand over.")
          .font(.title.weight(.bold))
          .tracking(-0.5)
        Text("Address Atlas is a read-only portfolio map built around local ownership.")
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink2)
          .lineSpacing(3)
      }
      VStack(alignment: .leading, spacing: 20) {
        UnlockFeature(
          title: "No signing",
          copy: "Only public wallet addresses are scanned",
          systemImage: "signature"
        )
        UnlockFeature(
          title: "No custody",
          copy: "Private keys and seed phrases never enter the app",
          systemImage: "hand.raised.fill"
        )
        UnlockFeature(
          title: "Private sync",
          copy: "The server stores opaque encrypted snapshots",
          systemImage: "icloud.and.arrow.up.fill"
        )
      }
      Spacer(minLength: 0)
      Label("Designed for macOS", systemImage: "apple.logo")
        .font(.caption.weight(.medium))
        .foregroundStyle(AtlasTheme.ink3)
    }
    .padding(36)
    .frame(width: 330)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(
      LinearGradient(
        colors: [AtlasTheme.accent.opacity(0.11), AtlasTheme.gain.opacity(0.055)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
    .overlay(alignment: .leading) {
      Rectangle().fill(AtlasTheme.ruleSoft).frame(width: 1)
    }
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

private struct UnlockFeature: View {
  var title: String
  var copy: String
  var systemImage: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.body.weight(.semibold))
        .foregroundStyle(AtlasTheme.accent)
        .frame(width: 36, height: 36)
        .background(AtlasTheme.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.callout.weight(.semibold))
        Text(copy)
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
          .lineSpacing(2)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
