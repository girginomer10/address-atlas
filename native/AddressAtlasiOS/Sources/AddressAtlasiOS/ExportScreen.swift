import AddressAtlasCore
import SwiftUI
import UniformTypeIdentifiers

/// iOS port of the macOS `ExportView` and `ExportPreview`: the share-safer
/// summary first, the full identifying reports behind an explicit disclosure,
/// and the read-only preview rendered as rows instead of a `Table`. Every
/// export is generated locally by the shared `ExportPipeline` and leaves the
/// device only through the Files picker or the share sheet.
struct ExportScreen: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var exportedPreview = ""
  @State private var showFullIdentifyingExports = false
  @State private var activeAction: ExportScreenAction?
  @State private var lastExportDisplayName = ""
  @State private var pendingFileExport: ExportScreenFileExport?
  @State private var isFileExporterPresented = false
  @State private var shareItem: ExportScreenShareItem?
  @State private var activeShare: ExportScreenShareItem?

  private var latestAssetCount: Int {
    state.latestScan?.holdings.count ?? 0
  }

  private var latestAssetsBadge: String {
    latestAssetCount == 1
      ? "1 asset in the latest scan"
      : "\(latestAssetCount) assets in the latest scan"
  }

  var body: some View {
    IOSPage(
      title: "Export",
      subtitle:
        "Choose the minimum detail your recipient needs. Every export is generated locally on this device."
    ) {
      shareSaferSurface
      fullIdentifyingSurface
      ExportScreenPreview(exportedPreview: exportedPreview)
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
  }

  // MARK: - Sections

  private var shareSaferSurface: some View {
    Surface(style: .accent) {
      VStack(alignment: .leading, spacing: 16) {
        PanelHeader(
          title: "Share-safer summary",
          subtitle: "Recommended for intentional sharing · not anonymous",
          systemImage: "person.crop.circle.badge.checkmark"
        )
        Badge(latestAssetsBadge, color: AtlasTheme.accent)
        InfoCallout(
          title: "Reduced exposure—not anonymous",
          copy: "\(ShareSafePortfolioReport.privacyNotice) \(ExportCopy.shareSaferExplanation)",
          tone: .info
        )
        VStack(alignment: .leading, spacing: 14) {
          ExportScreenFormatRow(
            key: .shareSafeCSV,
            displayName: ExportPayload.shareSafeCSV(state.document).displayName,
            isPrimary: true,
            activeAction: activeAction,
            onSave: { perform(.saveToFiles, for: .shareSafeCSV) },
            onShare: { perform(.share, for: .shareSafeCSV) },
            onPreview: { perform(.preview, for: .shareSafeCSV) }
          )
          ExportScreenFormatRow(
            key: .shareSafeJSON,
            displayName: ExportPayload.shareSafeJSON(state.document).displayName,
            isPrimary: false,
            activeAction: activeAction,
            onSave: { perform(.saveToFiles, for: .shareSafeJSON) },
            onShare: { perform(.share, for: .shareSafeJSON) },
            onPreview: { perform(.preview, for: .shareSafeJSON) }
          )
        }
        .disabled(state.isExportOperationInProgress)
      }
    }
  }

  private var fullIdentifyingSurface: some View {
    Surface(style: .danger) {
      VStack(alignment: .leading, spacing: 14) {
        Button {
          withAnimation(AtlasMotion.animation(AtlasMotion.standard, reduceMotion: reduceMotion)) {
            showFullIdentifyingExports.toggle()
          }
        } label: {
          HStack(alignment: .center, spacing: 12) {
            PanelHeader(
              title: "Full identifying reports",
              subtitle: "Addresses, balances, and portfolio details are disclosed",
              systemImage: "exclamationmark.triangle.fill",
              tint: AtlasTheme.loss
            )
            Image(systemName: showFullIdentifyingExports ? "chevron.up" : "chevron.down")
              .font(.callout.weight(.semibold))
              .foregroundStyle(AtlasTheme.ink3)
              .frame(width: 24, height: 24)
              .accessibilityHidden(true)
          }
          .frame(minHeight: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Full identifying reports")
        .accessibilityValue(showFullIdentifyingExports ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows or hides the exports that disclose addresses and balances.")
        .accessibilityIdentifier("full-identifying-export-disclosure")

        if showFullIdentifyingExports {
          InfoCallout(
            title: "This report can identify your portfolio",
            copy: ExportCopy.fullIdentifyingExplanation,
            tone: .danger
          )
          VStack(alignment: .leading, spacing: 14) {
            ExportScreenFormatRow(
              key: .fullCSV,
              displayName: ExportPayload.csv([]).displayName,
              isPrimary: false,
              activeAction: activeAction,
              onSave: { perform(.saveToFiles, for: .fullCSV) },
              onShare: { perform(.share, for: .fullCSV) },
              onPreview: { perform(.preview, for: .fullCSV) }
            )
            ExportScreenFormatRow(
              key: .fullJSON,
              displayName: ExportPayload.json(state.document).displayName,
              isPrimary: false,
              activeAction: activeAction,
              onSave: { perform(.saveToFiles, for: .fullJSON) },
              onShare: { perform(.share, for: .fullJSON) },
              onPreview: { perform(.preview, for: .fullJSON) }
            )
          }
          .disabled(state.isExportOperationInProgress)
        }
      }
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
  /// before any rendering starts and released on every completion path.
  private func perform(_ kind: ExportScreenAction.Kind, for key: ExportScreenExportKey) {
    guard let payload = payload(for: key) else { return }
    guard state.beginExportOperation() else { return }
    state.error = ""
    activeAction = ExportScreenAction(kind: kind, key: key)
    lastExportDisplayName = payload.displayName
    let writesTemporaryFile = kind == .share
    Task { @MainActor in
      defer { activeAction = nil }
      do {
        let prepared = try await Task.detached(priority: .userInitiated) {
          try ExportScreenPreparedExport(payload: payload, writesTemporaryFile: writesTemporaryFile)
        }.value
        exportedPreview = prepared.preview
        switch kind {
        case .preview:
          state.finishExportOperation()
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

private enum ExportScreenExportKey: Equatable {
  case shareSafeCSV
  case shareSafeJSON
  case fullCSV
  case fullJSON

  var title: String {
    switch self {
    case .shareSafeCSV, .fullCSV: "CSV"
    case .shareSafeJSON, .fullJSON: "JSON"
    }
  }

  var detail: String {
    switch self {
    case .shareSafeCSV: "Grouped ranges only. Opens in any spreadsheet app."
    case .shareSafeJSON: "The same grouped summary as structured data."
    case .fullCSV: "Latest addresses, labels, asset names, and exact balances."
    case .fullJSON: "Adds portfolio records, settings, timestamps, and scan history."
    }
  }

  var saveTitle: String {
    switch self {
    case .shareSafeCSV, .fullCSV: "Save CSV"
    case .shareSafeJSON, .fullJSON: "Save JSON"
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

/// One format: a text button for the Files picker plus icon buttons for the
/// share sheet and the read-only preview. Every control is at least 44pt tall
/// and carries a full accessibility label.
private struct ExportScreenFormatRow: View {
  var key: ExportScreenExportKey
  var displayName: String
  var isPrimary: Bool
  var activeAction: ExportScreenAction?
  var onSave: () -> Void
  var onShare: () -> Void
  var onPreview: () -> Void

  private func isActive(_ kind: ExportScreenAction.Kind) -> Bool {
    activeAction == ExportScreenAction(kind: kind, key: key)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(key.title)
          .font(.callout.weight(.semibold))
        Text(key.detail)
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink3)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)

      AdaptiveStack(horizontalSpacing: 8, verticalSpacing: 8) {
        saveButton
        Button(action: onShare) {
          ExportScreenActionLabel(
            isActive: isActive(.share), systemImage: "square.and.arrow.up", title: nil)
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        .accessibilityLabel("Share \(displayName)")
        .accessibilityHint("Generates the file on this device and opens the share sheet.")
        Button(action: onPreview) {
          ExportScreenActionLabel(isActive: isActive(.preview), systemImage: "eye", title: nil)
        }
        .buttonStyle(AtlasSecondaryButtonStyle())
        .accessibilityLabel("Preview \(displayName)")
        .accessibilityHint("Shows the exact report in the read-only preview below without saving it.")
      }
    }
  }

  @ViewBuilder
  private var saveButton: some View {
    let button = Button(action: onSave) {
      ExportScreenActionLabel(
        isActive: isActive(.saveToFiles), systemImage: "arrow.down.doc", title: key.saveTitle)
    }
    .accessibilityLabel("Save \(displayName) to Files")
    .accessibilityHint("Generates the file on this device and opens the Files picker.")

    if isPrimary {
      button.buttonStyle(AtlasPrimaryButtonStyle())
    } else {
      button.buttonStyle(AtlasSecondaryButtonStyle())
    }
  }
}

private struct ExportScreenActionLabel: View {
  var isActive: Bool
  var systemImage: String
  var title: String?

  var body: some View {
    Group {
      if isActive {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          if title != nil {
            Text("Preparing…")
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preparing export, in progress")
      } else if let title {
        Label(title, systemImage: systemImage)
      } else {
        Image(systemName: systemImage)
      }
    }
    .frame(minHeight: 44)
  }
}

/// Read-only preview as navigable rows. Keeps the macOS accessibility
/// contract: one element per `ExportPreviewRow`, labelled by location and
/// valued by content, inside a container with the shared identifier.
private struct ExportScreenPreview: View {
  static let contentAccessibilityIdentifier = "export-preview-content"

  var exportedPreview: String

  private var displayedText: String {
    exportedPreview.isEmpty
      ? "Preview the recommended share-safer summary here. It reduces direct exposure, but portfolio composition can still identify you; it is not anonymous."
      : exportedPreview
  }

  var body: some View {
    let model = ExportPreviewAccessibilityModel(text: displayedText)

    Surface {
      VStack(alignment: .leading, spacing: 10) {
        PanelHeader(
          title: "Read-only preview",
          subtitle: "Inspect the exact report before saving or sharing",
          systemImage: "doc.text.magnifyingglass"
        )
        Text(model.spokenSummary)
          .font(.caption)
          .foregroundStyle(AtlasTheme.ink2)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel(model.accessibilitySummaryLabel)
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(model.rows) { row in
            VStack(alignment: .leading, spacing: 2) {
              Text(row.locationLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(AtlasTheme.ink3)
                .accessibilityHidden(true)
              Text(row.visibleContent)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(row.locationLabel)
                .accessibilityValue(row.accessibilityValue)
                .accessibilityIdentifier(row.accessibilityIdentifier)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.id != model.rows.last?.id {
              Divider().overlay(AtlasTheme.ruleSoft)
            }
          }
        }
        .padding(10)
        .background(AtlasTheme.surfaceMuted.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: AtlasRadius.control, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Read-only export preview list")
        .accessibilityHint(ExportPreviewAccessibilityModel.navigationHint)
        .accessibilityIdentifier(Self.contentAccessibilityIdentifier)
      }
      .accessibilityElement(children: .contain)
    }
  }
}
