import AddressAtlasCore
import SwiftUI
import UIKit

/// Gates the main shell behind the unlocked vault, runs the foreground-only
/// auto-refresh loop, and maps iOS scene transitions onto the shared state's
/// termination/durability lane (the macOS app does this from
/// `applicationShouldTerminate`; iOS suspends instead of quitting).
struct RootView: View {
  /// Matches the macOS auto-refresh cadence.
  static let autoRefreshInterval: TimeInterval = 15 * 60
  /// The loop wakes once a minute so a foreground transition never restarts
  /// the whole interval and a sleep that expired while suspended does not
  /// scan before the scene has settled.
  static let autoRefreshTick: Duration = .seconds(60)

  @EnvironmentObject private var state: AppState
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var reachability = NetworkReachability()
  @StateObject private var suspension = SuspensionCoordinator()
  @State private var lastAutoRefresh = Date()

  private var autoRefreshTaskID: String {
    "\(state.isUnlocked)-\(state.document.preferences.autoRefresh)"
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
      TemporaryExportFiles.purgeStale()
      await state.unlock()
      state.excludeLocalStoreFromDeviceBackups()
    }
    .task(id: autoRefreshTaskID) {
      guard state.isUnlocked, state.document.preferences.autoRefresh else { return }
      lastAutoRefresh = Date()
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: Self.autoRefreshTick)
        } catch {
          return
        }
        guard Date().timeIntervalSince(lastAutoRefresh) >= Self.autoRefreshInterval,
          scenePhase == .active,
          state.isUnlocked,
          state.document.preferences.autoRefresh,
          state.hasScanSources,
          reachability.isReachable,
          !state.scanning,
          !state.syncing,
          !state.syncPersistencePending
        else { continue }
        lastAutoRefresh = Date()
        state.startScan()
      }
    }
    .onChange(of: state.scanning) { _, isScanning in
      // A manual scan also resets the cadence, as on macOS where every scan
      // restarts the 15-minute wait.
      if isScanning { lastAutoRefresh = Date() }
    }
    .onChange(of: scenePhase) { _, phase in
      suspension.handle(phase, state: state)
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: UIApplication.protectedDataWillBecomeUnavailableNotification)
    ) { _ in
      suspension.deviceWillLock(state: state)
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

  /// The vault key and the Kraken installation secret are
  /// WhenUnlockedThisDeviceOnly, so a scan that outlives the lock screen can
  /// only fail; it is cancelled with the normal cancellation notice instead.
  func deviceWillLock(state: AppState) {
    if state.scanning {
      state.cancelScan()
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
