import AppKit
import SwiftUI

struct PrivacySafeDiagnosticsControls: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      PanelHeader(
        title: "Privacy-safe diagnostics",
        subtitle: "Useful support context without portfolio content",
        systemImage: "stethoscope"
      )
      InfoCallout(
        title: "Designed to exclude sensitive data",
        copy:
          "Includes app and schema versions, coarse state flags, count ranges, and stable failure codes. Excludes addresses, labels, amounts, credentials, sessions, URLs, file paths, and raw errors.",
        tone: .success
      )
      Button {
        copyDiagnostics()
      } label: {
        Label("Copy diagnostics", systemImage: "doc.on.doc")
      }
      .buttonStyle(AtlasSecondaryButtonStyle())
      .accessibilityHint(
        "Copies a bounded technical report that excludes portfolio content and identifiers."
      )
    }
  }

  private func copyDiagnostics() {
    let report = state.privacySafeDiagnosticsReport()
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    if pasteboard.setString(report, forType: .string) {
      state.notice = "Privacy-safe diagnostics copied."
      state.error = ""
    } else {
      state.notice = ""
      state.error = "Diagnostics could not be copied. No vault data was placed on the clipboard."
    }
  }
}
