import AddressAtlasCore
import Foundation
import UniformTypeIdentifiers

/// View-free export payloads, rendering pipeline, preview accessibility model,
/// and disclosure copy shared by the macOS and iOS export screens.

enum ExportCopy {
  static let shareSaferExplanation =
    "It omits addresses, labels, symbols, names, record IDs, URLs, notes, history, timestamps, settings, credentials, sessions, and exact amounts, prices, and values. The latest holdings are grouped only by closed source categories and coarse ranges."
  static let fullIdentifyingExplanation =
    "Full exports are credential-free but identifying. CSV includes the latest addresses, labels, asset names, and exact balances. JSON also includes portfolio records, settings, timestamps, and scan history. They omit exchange credentials and sync authentication, and they are not backups."
}

enum ExportPayload: Sendable {
  case shareSafeCSV(VaultDocument)
  case shareSafeJSON(VaultDocument)
  case csv([TrackedAsset])
  case json(VaultDocument)

  var suggestedName: String {
    switch self {
    case .shareSafeCSV: "address-atlas-share-safer-summary.csv"
    case .shareSafeJSON: "address-atlas-share-safer-summary.json"
    case .csv: "address-atlas-full-identifying-holdings-report.csv"
    case .json: "address-atlas-full-identifying-portfolio-report.json"
    }
  }

  var contentType: UTType {
    switch self {
    case .shareSafeCSV, .csv: .commaSeparatedText
    case .shareSafeJSON, .json: .json
    }
  }

  var displayName: String {
    switch self {
    case .shareSafeCSV: "Share-safer CSV summary"
    case .shareSafeJSON: "Share-safer JSON summary"
    case .csv: "Full identifying CSV report"
    case .json: "Full identifying JSON report"
    }
  }

  var isShareSafer: Bool {
    switch self {
    case .shareSafeCSV, .shareSafeJSON: true
    case .csv, .json: false
    }
  }
}

enum ExportPipeline {
  static let maximumPreviewByteCount = 256 * 1_024

  nonisolated static func data(for payload: ExportPayload) throws -> Data {
    switch payload {
    case .shareSafeCSV(let document):
      return Data(try AddressAtlasExporter.shareSafeCSV(for: document).utf8)
    case .shareSafeJSON(let document):
      return try AddressAtlasExporter.shareSafeJSON(for: document)
    case .csv(let assets):
      return Data(try AddressAtlasExporter.csv(for: assets).utf8)
    case .json(let document):
      return try AddressAtlasExporter.json(for: document)
    }
  }

  nonisolated static func preview(
    for data: Data,
    maximumByteCount: Int = maximumPreviewByteCount
  ) -> String {
    guard maximumByteCount > 0 else {
      return data.isEmpty ? "" : "Preview omitted. The saved export still includes all records."
    }
    guard data.count > maximumByteCount else {
      return String(decoding: data, as: UTF8.self)
    }
    return String(decoding: data.prefix(maximumByteCount), as: UTF8.self)
      + "\n\n— Preview truncated to \(maximumByteCount.formatted(.number.locale(AtlasFormatting.locale))) bytes. The saved export includes all records."
  }

  nonisolated static func renderPreview(for payload: ExportPayload) throws -> String {
    try preview(for: data(for: payload))
  }

  nonisolated static func write(_ payload: ExportPayload, to url: URL) throws -> String {
    let exportData = try data(for: payload)
    try exportData.write(to: url, options: .atomic)
    return preview(for: exportData)
  }
}

struct ExportPreviewRow: Identifiable, Equatable, Sendable {
  let id: Int
  let sourceLine: Int
  let part: Int
  let partCount: Int
  let content: String

  var locationLabel: String {
    if partCount == 1 {
      return "Line \(sourceLine)"
    }
    return "Line \(sourceLine), part \(part) of \(partCount)"
  }

  var visibleContent: String { content.isEmpty ? " " : content }
  var accessibilityValue: String { content.isEmpty ? "Empty line" : content }
  var accessibilityIdentifier: String { "export-preview-row-\(id)" }
}

struct ExportPreviewAccessibilityModel: Equatable, Sendable {
  static let maximumNodeValueByteCount = 512
  static let maximumNavigableRowCount = 2_048
  static let maximumSummaryByteCount = 256

  let rows: [ExportPreviewRow]
  let sourceLineCount: Int
  let sourceByteCount: Int
  let didOmitContent: Bool

  init(text: String) {
    let splitLines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let sourceLines = splitLines.isEmpty ? [text[...]] : splitLines
    var generatedRows: [ExportPreviewRow] = []
    generatedRows.reserveCapacity(min(sourceLines.count, Self.maximumNavigableRowCount))

    rowGeneration: for (lineIndex, sourceLine) in sourceLines.enumerated() {
      let chunks = Self.boundedUTF8Chunks(String(sourceLine))
      for (chunkIndex, chunk) in chunks.enumerated() {
        guard generatedRows.count < Self.maximumNavigableRowCount else {
          break rowGeneration
        }
        generatedRows.append(
          ExportPreviewRow(
            id: generatedRows.count + 1,
            sourceLine: lineIndex + 1,
            part: chunkIndex + 1,
            partCount: chunks.count,
            content: chunk
          )
        )
      }
    }

    rows = generatedRows
    sourceLineCount = sourceLines.count
    sourceByteCount = text.utf8.count
    didOmitContent =
      generatedRows.last?.sourceLine != sourceLines.count
      || generatedRows.last?.part != generatedRows.last?.partCount
  }

  var spokenSummary: String {
    if didOmitContent {
      return
        "Read-only export preview. Showing the first \(rows.count) navigable rows from \(sourceLineCount) lines. Save the report to inspect all content."
    }
    return "Read-only export preview. \(sourceLineCount) lines in \(rows.count) navigable rows."
  }

  var accessibilitySummaryLabel: String { "Preview summary: \(spokenSummary)" }

  static let navigationHint =
    "Navigate the table by row. Long source lines are split into numbered parts."

  private static func boundedUTF8Chunks(_ text: String) -> [String] {
    guard !text.isEmpty else { return [""] }

    let bytes = Array(text.utf8)
    var chunks: [String] = []
    var start = 0

    while start < bytes.count {
      var end = min(start + maximumNodeValueByteCount, bytes.count)
      if end < bytes.count {
        while end > start, bytes[end] & 0xC0 == 0x80 {
          end -= 1
        }
      }
      // A UTF-8 scalar is at most four bytes, well below the configured bound.
      precondition(end > start)
      chunks.append(String(decoding: bytes[start..<end], as: UTF8.self))
      start = end
    }

    return chunks
  }
}
