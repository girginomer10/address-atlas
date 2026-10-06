import AddressAtlasCore
import SwiftUI
import UniformTypeIdentifiers

/// iOS port of the macOS `ExportView` and `ExportPreview`: the share-safer
/// summary first as the one obvious choice, the full identifying reports
/// behind an explicit danger disclosure, and the read-only preview in a sheet
/// rendered as rows instead of a `Table`. Every export is generated locally by
/// the shared `ExportPipeline` and leaves the device only through the Files
/// picker or the share sheet.
struct ExportScreen: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var exportedPreview = ""
  @State private var previewDisplayName = ""
  @State private var isPreviewPresented = false
  @State private var shareSaferFormat: ExportScreenFormat = .csv
  @State private var fullFormat: ExportScreenFormat = .csv
  @State private var showFullIdentifyingExports = false
  @State private var activeAction: ExportScreenAction?
  @State private var lastExportDisplayName = ""
  @State private var pendingFileExport: ExportScreenFileExport?
  @State private var isFileExporterPresented = false
  @State private var shareItem: ExportScreenShareItem?
  @State private var activeShare: ExportScreenShareItem?
  @State private var preparationTask: Task<Void, Never>?

  private var latestAssetCount: Int {
    state.latestScan?.holdings.count ?? 0
  }

  private var latestScanLine: String {
    switch latestAssetCount {
    case 0: "No assets in the latest scan yet."
    case 1: "Covers 1 asset from the latest scan."
    default: "Covers \(latestAssetCount) assets from the latest scan."
    }
  }

  var body: some View {
    IOSPage(title: "Export", subtitle: "Files are generated on this device.") {
      shareSaferSurface
      fullIdentifyingSurface
    }
    .fileExporter(
      isPresented: $isFileExporterPresented,
      document: pendingFileExport?.document,
      contentTypes: pendingFileExport.map { [$0.payload.contentType] } ?? [],
      defaultFilename: pendingFileExport?.payload.suggestedName,
      onCompletion: { result in
        finishFileExport(result)
      },
      onCancellation: {
        releaseFileExport()
      }
    )
    .onChange(of: isFileExporterPresented) { _, presented in
      // The picker reports success, failure, or cancellation before this
      // change is observed; the release is idempotent and only catches a
      // dismissal that reported nothing.
      guard !presented else { return }
      releaseFileExport()
    }
    .sheet(item: $shareItem, onDismiss: { finishShare(completed: false) }) { item in
      ShareSheet(items: [item.url]) { completed in
        finishShare(completed: completed)
      }
      .presentationDetents([.medium, .large])
      .ignoresSafeArea()
    }
    .sheet(isPresented: $isPreviewPresented) {
      ExportScreenPreviewSheet(
        displayName: previewDisplayName,
        exportedPreview: exportedPreview
      )
    }
    .onDisappear {
      // Leaving the page while a file is still being rendered would
      // otherwise present the picker or share sheet from a page that no
      // longer exists, leaving the shared export lock claimed.
      cancelPreparation()
    }
  }

  // MARK: - Sections

  private var shareSaferSurface: some View {
    let key = shareSaferFormat.shareSaferKey
    let displayName = payloadDisplayName(for: key)
    return Surface(style: .accent) {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .top, spacing: 12) {
          if !dynamicTypeSize.isAccessibilitySize {
            Image(systemName: "person.crop.circle.badge.checkmark")
              .font(.title3.weight(.semibold))
              .foregroundStyle(AtlasTheme.accent)
              .frame(width: 44, height: 44)
              .background(AtlasTheme.accent.opacity(0.12))
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
              .accessibilityHidden(true)
          }
          VStack(alignment: .leading, spacing: 3) {
            Text("Share-safer summary")
              .font(.headline.weight(.semibold))
              .foregroundStyle(AtlasTheme.ink)
              .accessibilityAddTraits(.isHeader)
            Text("Grouped ranges, no addresses or exact amounts.")
              .font(.callout)
              .foregroundStyle(AtlasTheme.ink2)
              .fixedSize(horizontal: false, vertical: true)
            Text(latestScanLine)
              .font(.caption)
              .foregroundStyle(AtlasTheme.ink3)
              .padding(.top, 2)
          }
        }

        ExportScreenFormatPicker(selection: $shareSaferFormat, detail: key.detail)

        exportActions(for: key, displayName: displayName, savesAsPrimary: true)

        VStack(alignment: .leading, spacing: 10) {
          Label {
            Text("Reduced exposure, not anonymous: your mix of assets can still identify you.")
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "eye.trianglebadge.exclamationmark")
              .foregroundStyle(AtlasTheme.warning)
          }
          .font(.footnote)
          .foregroundStyle(AtlasTheme.ink2)

          LearnMoreDisclosure("What's left out", systemImage: "list.bullet.rectangle") {
            Text(ShareSafePortfolioReport.privacyNotice)
            Text(ExportCopy.shareSaferExplanation)
          }
        }
      }
    }
  }

  private var fullIdentifyingSurface: some View {
    let key = fullFormat.fullKey
    let displayName = payloadDisplayName(for: key)
    return Surface(style: .danger) {
      VStack(alignment: .leading, spacing: 14) {
        Button {
          withAnimation(AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion)) {
            showFullIdentifyingExports.toggle()
          }
        } label: {
          HStack(alignment: .center, spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(AtlasTheme.loss)
                .frame(width: 36, height: 36)
                .background(AtlasTheme.loss.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
              Text("Full identifying reports")
                .font(.headline.weight(.semibold))
                .foregroundStyle(AtlasTheme.ink)
              Text("Addresses and exact balances")
                .font(.callout)
                .foregroundStyle(AtlasTheme.ink3)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.down")
              .font(.callout.weight(.semibold))
              .foregroundStyle(AtlasTheme.ink3)
              .rotationEffect(.degrees(showFullIdentifyingExports ? 180 : 0))
          }
          .frame(minHeight: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Full identifying reports")
        .accessibilityValue(showFullIdentifyingExports ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows or hides the exports that disclose addresses and balances.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("full-identifying-export-disclosure")

        if showFullIdentifyingExports {
          Text(
            "Anyone with these files can see your addresses, labels, and exact balances. They contain no exchange credentials and are not backups."
          )
          .font(.callout)
          .foregroundStyle(AtlasTheme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel(
            "Warning: anyone with these files can see your addresses, labels, and exact balances. They contain no exchange credentials and are not backups."
          )

          ExportScreenFormatPicker(selection: $fullFormat, detail: key.detail)

          exportActions(for: key, displayName: displayName, savesAsPrimary: false)
            .transition(.opacity)
        }
      }
    }
  }

  /// Save to Files on its own row, Share and Preview below it. The full
  /// identifying reports use the same layout with a secondary Save so the
  /// share-safer summary stays the one obvious choice.
  private func exportActions(
    for key: ExportScreenExportKey, displayName: String, savesAsPrimary: Bool
  ) -> some View {
    VStack(spacing: 10) {
      ExportScreenActionButton(
        title: "Save to Files",
        systemImage: "arrow.down.doc",
        isPrimary: savesAsPrimary,
        isActive: isActive(.saveToFiles, key),
        accessibilityLabel: "Save \(displayName) to Files",
        accessibilityHint: "Generates the file on this device and opens the Files picker.",
        action: { perform(.saveToFiles, for: key) }
      )
      AdaptiveStack(horizontalSpacing: 10, verticalSpacing: 10) {
        ExportScreenActionButton(
          title: "Share",
          systemImage: "square.and.arrow.up",
          isActive: isActive(.share, key),
          accessibilityLabel: "Share \(displayName)",
          accessibilityHint: "Generates the file on this device and opens the share sheet.",
          action: { perform(.share, for: key) }
        )
        ExportScreenActionButton(
          title: "Preview",
          systemImage: "eye",
          isActive: isActive(.preview, key),
          accessibilityLabel: "Preview \(displayName)",
          accessibilityHint: "Shows the exact report without saving it.",
          action: { perform(.preview, for: key) }
        )
      }
    }
    .disabled(state.isExportOperationInProgress)
  }

  private func isActive(_ kind: ExportScreenAction.Kind, _ key: ExportScreenExportKey) -> Bool {
    activeAction == ExportScreenAction(kind: kind, key: key)
  }

  private func payloadDisplayName(for key: ExportScreenExportKey) -> String {
    switch key {
    case .shareSafeCSV: ExportPayload.shareSafeCSV(state.document).displayName
    case .shareSafeJSON: ExportPayload.shareSafeJSON(state.document).displayName
    case .fullCSV: ExportPayload.csv([]).displayName
    case .fullJSON: ExportPayload.json(state.document).displayName
    }
  }

  // MARK: - Payloads

  private func payload(for key: ExportScreenExportKey) -> ExportPayload? {
    switch key {
    case .shareSafeCSV: .shareSafeCSV(state.document)
    case .shareSafeJSON: .shareSafeJSON(state.document)
    case .fullCSV: csvPayloadIncludingDrafts()
    case .fullJSON: jsonPayloadIncludingDrafts()
    }
  }

  private func csvPayloadIncludingDrafts() -> ExportPayload? {
    payloadIncludingDrafts {
      .csv(try state.holdingsForExportIncludingWalletLabelDrafts())
    }
  }

  private func jsonPayloadIncludingDrafts() -> ExportPayload? {
    payloadIncludingDrafts {
      .json(try state.documentForExportIncludingWalletLabelDrafts())
    }
  }

  private func payloadIncludingDrafts(
    _ makePayload: () throws -> ExportPayload
  ) -> ExportPayload? {
    do {
      return try makePayload()
    } catch WalletLabelDraftError.invalidLabel {
      state.notice = ""
      state.error = "Wallet labels must be between 1 and 80 characters before exporting."
      return nil
    } catch {
      state.presentUserFacingError(error)
      return nil
    }
  }

  // MARK: - Export lane

  /// One shared lane for preview, Files, and share: the export flag is claimed
  /// before any rendering starts and released on every completion path,
  /// including the page disappearing while the file is still being rendered.
  private func perform(_ kind: ExportScreenAction.Kind, for key: ExportScreenExportKey) {
    guard let payload = payload(for: key) else { return }
    guard state.beginExportOperation() else { return }
    state.error = ""
    activeAction = ExportScreenAction(kind: kind, key: key)
    lastExportDisplayName = payload.displayName
    let writesTemporaryFile = kind == .share
    preparationTask = Task { @MainActor in
      defer {
        activeAction = nil
        if !Task.isCancelled { preparationTask = nil }
      }
      do {
        let prepared = try await Task.detached(priority: .userInitiated) {
          try ExportScreenPreparedExport(payload: payload, writesTemporaryFile: writesTemporaryFile)
        }.value
        guard !Task.isCancelled else {
          // The page went away while rendering: nothing is presented, the
          // temporary share file is deleted, and the lock is released.
          if let url = prepared.temporaryURL {
            TemporaryExportFiles.remove(url)
          }
          state.finishExportOperation()
          return
        }
        exportedPreview = prepared.preview
        switch kind {
        case .preview:
          previewDisplayName = payload.displayName
          state.finishExportOperation()
          isPreviewPresented = true
        case .saveToFiles:
          pendingFileExport = ExportScreenFileExport(
            payload: payload,
            document: ExportFileDocument(data: prepared.data)
          )
          isFileExporterPresented = true
        case .share:
          guard let url = prepared.temporaryURL else {
            state.finishExportOperation()
            return
          }
          let item = ExportScreenShareItem(url: url, payload: payload)
          activeShare = item
          shareItem = item
        }
      } catch {
        state.presentUserFacingError(error)
        state.finishExportOperation()
      }
    }
  }

  /// Only a render that has not presented anything yet is cancelled; the
  /// Files picker and share sheet keep their own completion paths.
  private func cancelPreparation() {
    guard let task = preparationTask else { return }
    preparationTask = nil
    task.cancel()
  }

  private func finishFileExport(_ result: Result<URL, any Error>) {
    switch result {
    case .success:
      state.notice = "\(lastExportDisplayName) saved."
      state.error = ""
    case .failure(let error):
      state.presentUserFacingError(error)
    }
    releaseFileExport()
  }

  private func releaseFileExport() {
    guard pendingFileExport != nil else { return }
    pendingFileExport = nil
    state.finishExportOperation()
  }

  private func finishShare(completed: Bool) {
    guard let item = activeShare else { return }
    activeShare = nil
    shareItem = nil
    TemporaryExportFiles.remove(item.url)
    if completed {
      state.notice = "\(item.payload.displayName) shared."
      state.error = ""
    }
    state.finishExportOperation()
  }
}

// MARK: - Models

private enum ExportScreenFormat: Hashable {
  case csv
  case json

  var shareSaferKey: ExportScreenExportKey {
    self == .csv ? .shareSafeCSV : .shareSafeJSON
  }

  var fullKey: ExportScreenExportKey {
    self == .csv ? .fullCSV : .fullJSON
  }
}

private enum ExportScreenExportKey: Equatable {
  case shareSafeCSV
  case shareSafeJSON
  case fullCSV
  case fullJSON

  var detail: String {
    switch self {
    case .shareSafeCSV: "Opens in any spreadsheet app."
    case .shareSafeJSON: "The same summary as structured data."
    case .fullCSV: "Latest addresses, labels, asset names, and exact balances."
    case .fullJSON: "Adds portfolio records, settings, timestamps, and scan history."
    }
  }
}

private struct ExportScreenAction: Equatable {
  enum Kind: Equatable {
    case preview
    case saveToFiles
    case share
  }

  var kind: Kind
  var key: ExportScreenExportKey
}

/// Rendered off the main actor; carries the bytes for the Files picker, the
/// preview text, and the temporary file the share sheet reads.
private struct ExportScreenPreparedExport: Sendable {
  let data: Data
  let preview: String
  let temporaryURL: URL?

  init(payload: ExportPayload, writesTemporaryFile: Bool) throws {
    let exportData = try ExportPipeline.data(for: payload)
    data = exportData
    preview = ExportPipeline.preview(for: exportData)
    temporaryURL =
      writesTemporaryFile
      ? try TemporaryExportFiles.write(exportData, named: payload.suggestedName)
      : nil
  }
}

private struct ExportScreenFileExport {
  let payload: ExportPayload
  let document: ExportFileDocument
}

private struct ExportScreenShareItem: Identifiable {
  let id = UUID()
  let url: URL
  let payload: ExportPayload
}

// MARK: - Components

private struct ExportScreenFormatPicker: View {
  @Binding var selection: ExportScreenFormat
  var detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Picker("Format", selection: $selection) {
        Text("CSV").tag(ExportScreenFormat.csv)
        Text("JSON").tag(ExportScreenFormat.json)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(minHeight: 36)
      .accessibilityLabel("Format")
      Text(detail)
        .font(.caption)
        .foregroundStyle(AtlasTheme.ink3)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// A full-width action with a progress state. Every control is at least
/// 44pt tall and carries a full accessibility label naming the report.
private struct ExportScreenActionButton: View {
  var title: String
  var systemImage: String
  var isPrimary = false
  var isActive: Bool
  var accessibilityLabel: String
  var accessibilityHint: String
  var action: () -> Void

  var body: some View {
    let button = Button(action: action) {
      Group {
        if isActive {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
              .tint(isPrimary ? AtlasTheme.paper : AtlasTheme.accent)
            Text("Preparing…")
          }
        } else {
          Label(title, systemImage: systemImage)
        }
      }
      .multilineTextAlignment(.center)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, minHeight: 44)
    }
    .accessibilityLabel(isActive ? "Preparing export, in progress" : accessibilityLabel)
    .accessibilityHint(isActive ? "" : accessibilityHint)

    if isPrimary {
      button.buttonStyle(AtlasPrimaryButtonStyle())
    } else {
      button.buttonStyle(AtlasSecondaryButtonStyle())
    }
  }
}

/// Read-only preview in its own sheet. Readable intro text on top; only the
/// actual CSV/JSON content is monospaced. Keeps the macOS accessibility
/// contract: one element per `ExportPreviewRow`, labelled by location and
/// valued by content, inside a container with the shared identifier.
private struct ExportScreenPreviewSheet: View {
  static let contentAccessibilityIdentifier = "export-preview-content"

  @Environment(\.dismiss) private var dismiss
  var displayName: String
  var exportedPreview: String

  var body: some View {
    let model = ExportPreviewAccessibilityModel(text: exportedPreview)

    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          VStack(alignment: .leading, spacing: 4) {
            Text(displayName)
              .font(.headline)
              .foregroundStyle(AtlasTheme.ink)
            Text("The exact file contents. Nothing is saved or shared from here.")
              .font(.callout)
              .foregroundStyle(AtlasTheme.ink2)
              .fixedSize(horizontal: false, vertical: true)
            Text(model.sourceLineCount == 1 ? "1 line" : "\(model.sourceLineCount) lines")
              .font(.caption)
              .foregroundStyle(AtlasTheme.ink3)
              .accessibilityLabel(model.accessibilitySummaryLabel)
          }

          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.rows) { row in
              HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(row.part == 1 ? "\(row.sourceLine)" : "")
                  .font(.caption2.monospacedDigit())
                  .foregroundStyle(AtlasTheme.ink3)
                  .frame(minWidth: 24, alignment: .trailing)
                  .accessibilityHidden(true)
                Text(row.visibleContent)
                  .font(.caption.monospaced())
                  .foregroundStyle(AtlasTheme.ink)
                  .textSelection(.enabled)
                  .fixedSize(horizontal: false, vertical: true)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .accessibilityLabel(row.locationLabel)
                  .accessibilityValue(row.accessibilityValue)
                  .accessibilityIdentifier(row.accessibilityIdentifier)
              }
              .padding(.vertical, 5)
            }
          }
          .padding(12)
          .background(AtlasTheme.surfaceMuted.opacity(0.5))
          .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
          .accessibilityElement(children: .contain)
          .accessibilityLabel("Read-only export preview list")
          .accessibilityHint(ExportPreviewAccessibilityModel.navigationHint)
          .accessibilityIdentifier(Self.contentAccessibilityIdentifier)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 32)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .background(AtlasTheme.canvas)
      .navigationTitle("Preview")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(AtlasTheme.canvas, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }
}
