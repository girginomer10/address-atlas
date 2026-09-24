import AddressAtlasCore
import SwiftUI
import UIKit

/// Gates the main shell behind the unlocked vault, runs the foreground-only
/// auto-refresh loop, and maps iOS scene transitions onto the shared state's
/// termination/durability lane (the macOS app does this from
/// `applicationShouldTerminate`; iOS suspends instead of quitting).
struct RootView: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var reachability = NetworkReachability()
  @StateObject private var suspension = SuspensionCoordinator()

  private var autoRefreshTaskID: String {
    "\(state.isUnlocked)-\(state.document.preferences.autoRefresh)-\(scenePhase == .active)"
  }

  var body: some View {
    Group {
      if state.isUnlocked {
        MainShell()
      } else {
        UnlockScreen()
      }
    }
    .background(AtlasTheme.paper)
    .foregroundStyle(AtlasTheme.ink)
    .tint(AtlasTheme.accent)
    .disabled(state.isTerminationInProgress)
    .environmentObject(reachability)
    .task {
      await state.unlock()
    }
    .task(id: autoRefreshTaskID) {
      guard state.isUnlocked, state.document.preferences.autoRefresh, scenePhase == .active
      else { return }
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(15 * 60))
        } catch {
          return
        }
        guard state.isUnlocked,
          state.document.preferences.autoRefresh,
          state.hasScanSources,
          reachability.isReachable,
          !state.scanning,
          !state.syncing,
          !state.syncPersistencePending
        else { continue }
        state.startScan()
      }
    }
    .onChange(of: scenePhase) { _, phase in
      suspension.handle(phase, state: state)
    }
  }
}

/// Owns the UIKit background-time assertion around the pre-suspension flush
/// and restores interactivity when the scene becomes active again.
@MainActor
final class SuspensionCoordinator: ObservableObject {
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var flushTask: Task<Void, Never>?

  func handle(_ phase: ScenePhase, state: AppState) {
    switch phase {
    case .background:
      beginBackgroundTask(state: state)
      flushTask = Task { [weak self] in
        await state.flushBeforeSuspension()
        self?.endBackgroundTaskIfIdle(state: state)
      }
    case .active:
      let pendingFlush = flushTask
      Task { [weak self] in
        await pendingFlush?.value
        self?.flushTask = nil
        self?.endBackgroundTask()
        state.resumeAfterSuspension()
      }
    case .inactive:
      break
    @unknown default:
      break
    }
  }

  private func beginBackgroundTask(state: AppState) {
    endBackgroundTask()
    backgroundTask = UIApplication.shared.beginBackgroundTask(
      withName: "com.addressatlas.ios.suspension-flush"
    ) { [weak self] in
      MainActor.assumeIsolated {
        // iOS is about to suspend the process; an in-flight scan would only
        // produce a deadline-warning snapshot after resume, so it is cancelled
        // explicitly and the user sees the cancellation notice instead.
        if state.scanning {
          state.cancelScan()
        }
        self?.endBackgroundTask()
      }
    }
  }

  /// A scan that was still running when the flush finished keeps the
  /// assertion until it ends or the expiration handler cancels it.
  private func endBackgroundTaskIfIdle(state: AppState) {
    guard !state.scanning else { return }
    endBackgroundTask()
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }
}
