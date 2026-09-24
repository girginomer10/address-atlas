import AddressAtlasCore
import Network
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Page container

/// Compact-width page: a large navigation title, the shared status line, an
/// optional subtitle, and content stacked with 16pt gutters. Screens use this
/// instead of the desktop `Page`, whose 42pt in-page title and 32pt gutters
/// are sized for a window.
struct IOSPage<Content: View>: View {
  var title: String
  var subtitle: String?
  var content: Content

  init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.subtitle = subtitle
    self.content = content()
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        StatusLine(presentation: .inline)
        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(AtlasTheme.ink2)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        content
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 32)
      .frame(maxWidth: 760, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively)
    .background(AtlasTheme.canvas)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.large)
    .toolbarBackground(AtlasTheme.canvas, for: .navigationBar)
  }
}

// MARK: - Text input hygiene

extension View {
  /// Addresses, contract IDs, API keys, and secrets must never be autocorrected,
  /// auto-capitalized, or offered to password AutoFill.
  func atlasIdentifierInput() -> some View {
    textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .keyboardType(.asciiCapable)
      .textContentType(.oneTimeCode)
  }

  func atlasDecimalInput() -> some View {
    keyboardType(.decimalPad)
      .autocorrectionDisabled()
  }
}

// MARK: - Exports

/// Wraps an in-memory export so SwiftUI's `fileExporter` can save it.
struct ExportFileDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.commaSeparatedText, .json, .data]
  static let writableContentTypes: [UTType] = [.commaSeparatedText, .json, .data]

  var data: Data

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

/// App-owned scratch directory for files that are handed to the share sheet
/// or the Files picker. Each call gets its own directory so names never
/// collide, and callers remove the directory when the transfer completes.
enum TemporaryExportFiles {
  static func write(_ data: Data, named name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "exports", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let url = directory.appending(path: name)
    try data.write(to: url, options: [.atomic, .completeFileProtection])
    return url
  }

  /// Directory for a recovery kit that `AtomicFilePublisher` can publish into
  /// (owner-only, real directory, fsync-capable) before it is handed to the
  /// Files picker as a copy.
  static func makeRecoveryKitDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "recovery-kit", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    return directory
  }

  static func remove(_ url: URL) {
    let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
    try? FileManager.default.removeItem(at: directory)
  }
}

/// UIKit share sheet for a file URL, used where `ShareLink` cannot observe the
/// completion (the temporary file must be deleted afterwards).
struct ShareSheet: UIViewControllerRepresentable {
  var items: [URL]
  var onComplete: (Bool) -> Void

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
    let completion = onComplete
    controller.completionWithItemsHandler = { _, completed, _, _ in
      completion(completed)
    }
    return controller
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Reachability

/// Foreground network gate for scans so an offline device gets an explicit
/// message instead of a snapshot full of transport warnings.
@MainActor
final class NetworkReachability: ObservableObject {
  @Published private(set) var isReachable = true
  @Published private(set) var isConstrained = false
  private let monitor = NWPathMonitor()

  init() {
    monitor.pathUpdateHandler = { [weak self] path in
      let reachable = path.status == .satisfied
      let constrained = path.isConstrained || path.isExpensive
      Task { @MainActor in
        self?.isReachable = reachable
        self?.isConstrained = constrained
      }
    }
    monitor.start(queue: DispatchQueue(label: "com.addressatlas.ios.reachability"))
  }

  deinit {
    monitor.cancel()
  }

  static let offlineMessage =
    "This device is offline. Connect to a network before scanning; nothing was changed."
}

// MARK: - Shared state, iOS lifecycle

extension AppState {
  /// Flushes wallet-label drafts and pending sync persistence through the
  /// shared termination lane while iOS still grants background time. Active
  /// work (scan, sync, export, credential check) is left untouched; the lane
  /// would refuse it anyway and the app is only suspended, not quit.
  func flushBeforeSuspension() async {
    guard isUnlocked, !isUnlocking, !scanning, !syncing,
      !isValidatingExchangeCredentials, !isExportOperationInProgress
    else { return }
    guard hasPendingWalletLabelDrafts || pendingSyncPersistence != nil || isPersisting
    else { return }
    guard beginTerminationRequest() else { return }
    _ = await prepareForTermination()
  }

  /// A successful flush leaves the shared termination flag raised because
  /// macOS quits afterwards; iOS resumes instead, so the UI is re-enabled.
  func resumeAfterSuspension() {
    if isTerminationInProgress {
      setTerminationInProgress(false)
    }
  }

  /// Starts a scan only with connectivity; mirrors `startScan()` otherwise.
  func startScanIfReachable(_ reachability: NetworkReachability) {
    guard reachability.isReachable else {
      notice = ""
      error = NetworkReachability.offlineMessage
      return
    }
    startScan()
  }

  /// iOS variant of `exportRecoveryKit(to:)`: the durable write (F_FULLFSYNC
  /// barriers and directory fsync) runs off the main actor.
  func exportRecoveryKitOffMain(to url: URL) async throws -> String {
    guard let vaultKey else {
      recordDiagnosticFailure(.recoveryKitExportFailed)
      throw RecoveryKitError.invalidVaultKey
    }
    let codec = recoveryKit
    do {
      let recoveryCode = try await Task.detached {
        try codec.export(vaultKey: vaultKey, to: url)
      }.value
      notice = "Recovery kit saved. Store the code separately."
      error = ""
      return recoveryCode
    } catch {
      recordDiagnosticFailure(.recoveryKitExportFailed)
      throw error
    }
  }

  static let recoveryKitContentType = UTType(exportedAs: "com.addressatlas.recovery-kit")
}
