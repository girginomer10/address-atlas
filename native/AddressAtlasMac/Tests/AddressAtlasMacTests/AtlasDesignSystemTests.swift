import AddressAtlasCore
import Foundation
import XCTest

@testable import AddressAtlasMac

final class AtlasDesignSystemTests: XCTestCase {
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
}
