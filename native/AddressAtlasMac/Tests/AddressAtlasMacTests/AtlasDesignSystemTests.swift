import AddressAtlasCore
import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import AddressAtlasMac

final class AtlasDesignSystemTests: XCTestCase {
  @MainActor
  func testLaunchLayoutsProduceOnlyFiniteNonnegativeAppKitGeometry() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try EncryptedSQLiteVaultStore(
      path: directory.appending(path: "vault.sqlite"),
      vaultKey: try VaultCrypto().generateVaultKey()
    )
    _ = try store.load()
    let unlockedState = AppState(testStore: store, document: VaultDocument())

    assertValidLayout(
      UnlockView().environmentObject(AppState()),
      size: NSSize(width: 800, height: 560),
      context: "locked launch"
    )
    assertValidLayout(
      MainView().environmentObject(unlockedState),
      size: NSSize(width: 900, height: 600),
      context: "unlocked launch"
    )
  }

  @MainActor
  func testAccessibilityAnnouncementsCoalesceDuplicateViewsButAllowFreshEvents() {
    var clock = 10.0
    var announcements: [(message: String, priority: Int)] = []
    let announcer = AtlasAccessibilityAnnouncer(
      duplicateCoalescingInterval: 0.75,
      now: { clock },
      poster: { message, priority in
        announcements.append((message, priority.rawValue))
      }
    )

    announcer.announceVisible("Vault saved.", kind: .notice)
    announcer.announceVisible("Vault saved.", kind: .notice)
    announcer.announceEvent("Vault saved.", kind: .notice)

    XCTAssertEqual(announcements.map(\.message), ["Status: Vault saved."])
    XCTAssertEqual(announcements.map(\.priority), [NSAccessibilityPriorityLevel.medium.rawValue])

    clock += 1
    announcer.announceEvent("Vault saved.", kind: .notice)
    announcer.clear(.notice)
    announcer.announceEvent("Vault saved.", kind: .notice)

    XCTAssertEqual(
      announcements.map(\.message),
      ["Status: Vault saved.", "Status: Vault saved.", "Status: Vault saved."]
    )
  }

  @MainActor
  func testAccessibilityAnnouncementsClearEmptyStateAndPrioritizeErrors() {
    var announcements: [(message: String, priority: Int)] = []
    let announcer = AtlasAccessibilityAnnouncer(
      now: { 20 },
      poster: { message, priority in
        announcements.append((message, priority.rawValue))
      }
    )

    announcer.announceEvent("  Storage failed.  ", kind: .error)
    announcer.announceEvent("   ", kind: .error)
    announcer.announceVisible("Storage failed.", kind: .error)

    XCTAssertEqual(
      announcements.map(\.message),
      ["Error: Storage failed.", "Error: Storage failed."]
    )
    XCTAssertEqual(
      announcements.map(\.priority),
      [NSAccessibilityPriorityLevel.high.rawValue, NSAccessibilityPriorityLevel.high.rawValue]
    )
  }

  @MainActor
  func testExportPreviewAccessibilityContentMatchesGeneratedPreview() {
    let generated = "VOICEOVER_EXPORT_MARKER,{\"wallet\":\"visible\"}"
    let preview = ExportPreview(exportedPreview: generated)
    let displayedText = preview.displayedText
    let accessibilityContent = preview.accessibilityContent
    let accessibilityIdentifier = ExportPreview.contentAccessibilityIdentifier

    XCTAssertEqual(displayedText, generated)
    XCTAssertEqual(accessibilityContent, generated)
    XCTAssertNotEqual(displayedText, "Read-only export preview")
    XCTAssertEqual(accessibilityIdentifier, "export-preview-content")
  }

  func testSecondaryTextMeetsNormalTextContrastOnBothPaperSurfaces() {
    let foreground = AtlasTheme.ink3RGB

    XCTAssertGreaterThanOrEqual(
      contrastRatio(foreground, AtlasTheme.paperRGB),
      4.5
    )
    XCTAssertGreaterThanOrEqual(
      contrastRatio(foreground, AtlasTheme.paper2RGB),
      4.5
    )
  }

  func testWarningTextMeetsNormalTextContrastOnBothPaperSurfaces() {
    XCTAssertGreaterThanOrEqual(
      contrastRatio(AtlasTheme.warningRGB, AtlasTheme.paperRGB),
      4.5
    )
    XCTAssertGreaterThanOrEqual(
      contrastRatio(AtlasTheme.warningRGB, AtlasTheme.paper2RGB),
      4.5
    )
  }

  func testExportPreviewIsReadOnlySizedAndDisclosesTruncation() {
    let data = Data("0123456789".utf8)

    let preview = ExportPipeline.preview(for: data, maximumByteCount: 4)

    XCTAssertTrue(preview.hasPrefix("0123"))
    XCTAssertTrue(preview.contains("Preview truncated"))
    XCTAssertTrue(preview.contains("saved export includes all records"))
    XCTAssertEqual(
      ExportPipeline.preview(for: data, maximumByteCount: data.count),
      "0123456789"
    )
  }

  func testExportPipelineWritesTheExactRenderedDataRatherThanPreviewText() throws {
    let destination = FileManager.default.temporaryDirectory
      .appending(path: "AddressAtlasExport-\(UUID().uuidString).csv")
    defer { try? FileManager.default.removeItem(at: destination) }
    let payload = ExportPayload.csv([])
    let expected = try ExportPipeline.data(for: payload)

    let preview = try ExportPipeline.write(payload, to: destination)

    XCTAssertEqual(try Data(contentsOf: destination), expected)
    XCTAssertEqual(preview, String(decoding: expected, as: UTF8.self))
  }

  func testExportFilenamesDescribeRedactedReportsInsteadOfVaultBackups() {
    let csvName = ExportPayload.csv([]).suggestedName
    let jsonName = ExportPayload.json(VaultDocument()).suggestedName

    XCTAssertTrue(csvName.contains("report"))
    XCTAssertTrue(jsonName.contains("report"))
    XCTAssertFalse(jsonName.contains("vault"))
    XCTAssertFalse(jsonName.contains("backup"))
  }

  func testAccessibilityIdentitiesDisambiguateDuplicateVisibleLabels() {
    let firstToken = CustomTokenRecord(
      chainKind: .evm,
      chainId: "ethereum",
      address: "0x0000000000000000000000000000000000000001",
      symbol: "USD",
      name: "Dollar One",
      decimals: 18
    )
    let secondToken = CustomTokenRecord(
      chainKind: .evm,
      chainId: "base",
      address: "0x0000000000000000000000000000000000000002",
      symbol: "USD",
      name: "Dollar Two",
      decimals: 18
    )
    let firstHolding = ManualHoldingRecord(
      id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
      label: "Offline",
      provider: "manual",
      symbol: "BTC",
      name: "Bitcoin",
      amount: 1,
      priceUsd: nil,
      valueUsd: 1
    )
    let secondHolding = ManualHoldingRecord(
      id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
      label: "Offline",
      provider: "manual",
      symbol: "BTC",
      name: "Bitcoin",
      amount: 1,
      priceUsd: nil,
      valueUsd: 1
    )

    XCTAssertNotEqual(
      AtlasAccessibility.tokenIdentity(firstToken),
      AtlasAccessibility.tokenIdentity(secondToken)
    )
    XCTAssertNotEqual(
      AtlasAccessibility.manualHoldingIdentity(firstHolding),
      AtlasAccessibility.manualHoldingIdentity(secondHolding)
    )
  }

  private func contrastRatio(
    _ first: (red: Double, green: Double, blue: Double),
    _ second: (red: Double, green: Double, blue: Double)
  ) -> Double {
    let lighter = max(relativeLuminance(first), relativeLuminance(second))
    let darker = min(relativeLuminance(first), relativeLuminance(second))
    return (lighter + 0.05) / (darker + 0.05)
  }

  private func relativeLuminance(
    _ color: (red: Double, green: Double, blue: Double)
  ) -> Double {
    0.2126 * linearized(color.red)
      + 0.7152 * linearized(color.green)
      + 0.0722 * linearized(color.blue)
  }

  private func linearized(_ component: Double) -> Double {
    component <= 0.04045
      ? component / 12.92
      : pow((component + 0.055) / 1.055, 2.4)
  }

  @MainActor
  private func assertValidLayout<Content: View>(
    _ content: Content,
    size: NSSize,
    context: String
  ) {
    let hostingView = NSHostingView(rootView: content)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()
    assertValidGeometry(in: hostingView, path: context)
  }

  @MainActor
  private func assertValidGeometry(in view: NSView, path: String) {
    let frame = view.frame
    XCTAssertTrue(frame.origin.x.isFinite, "\(path) has a non-finite x origin")
    XCTAssertTrue(frame.origin.y.isFinite, "\(path) has a non-finite y origin")
    XCTAssertTrue(frame.width.isFinite, "\(path) has a non-finite width")
    XCTAssertTrue(frame.height.isFinite, "\(path) has a non-finite height")
    XCTAssertGreaterThanOrEqual(frame.width, 0, "\(path) has a negative width")
    XCTAssertGreaterThanOrEqual(frame.height, 0, "\(path) has a negative height")
    for (index, subview) in view.subviews.enumerated() {
      assertValidGeometry(
        in: subview,
        path: "\(path)/\(type(of: subview))[\(index)]"
      )
    }
  }
}
