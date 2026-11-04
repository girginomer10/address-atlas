import AppKit
import SwiftUI

/// Copies a report for support that leaves out portfolio content.
struct PrivacySafeDiagnosticsControls: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      MacHeading("Diagnostics")
      Text(
        "Copies app and schema versions, state flags, count ranges and failure codes. It leaves out addresses, names, amounts, credentials, URLs, file paths and raw errors."
      )
      .font(AtlasTheme.font(.body, .callout))
      .foregroundStyle(AtlasTheme.ink2)
      .fixedSize(horizontal: false, vertical: true)
      Button {
        copyDiagnostics()
      } label: {
        Label("Copy diagnostics", systemImage: "doc.on.doc")
      }
      .buttonStyle(MacSecondaryButtonStyle())
      .accessibilityHint(
        "Copies a short technical report that leaves out portfolio content and identifiers."
      )
    }
  }

  private func copyDiagnostics() {
    let report = state.privacySafeDiagnosticsReport()
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    if pasteboard.setString(report, forType: .string) {
      state.notice = "Diagnostics copied."
      state.error = ""
    } else {
      state.notice = ""
      state.error = "Diagnostics couldn\u{2019}t be copied. Nothing from your vault was placed on the clipboard."
    }
  }
}
