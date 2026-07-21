import AppKit
import SwiftUI

struct PrivacySafeDiagnosticsControls: View {
  @EnvironmentObject private var state: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionHeader(title: "Support diagnostics", meta: "Privacy-safe by construction")
      Text(
        "Copies app, macOS, vault-schema and endpoint-config versions; coarse state flags and count buckets; and stable failure codes. It never copies wallet addresses, URLs, labels, notes, amounts, identifiers, credentials, session material, file paths, or raw error text."
      )
      .font(.callout)
      .foregroundStyle(AtlasTheme.ink2)
      Button("Copy privacy-safe diagnostics") {
        copyDiagnostics()
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
