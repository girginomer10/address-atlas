import AddressAtlasCore
import XCTest

@testable import AddressAtlasMac

@MainActor
final class ShareSafeExportUITests: XCTestCase {
  func testShareSaferPayloadNamesAndCopyStateThePrivacyBoundary() throws {
    let document = VaultDocument()
    let csv = ExportPayload.shareSafeCSV(document)
    let json = ExportPayload.shareSafeJSON(document)

    XCTAssertEqual(csv.suggestedName, "address-atlas-share-safer-summary.csv")
    XCTAssertEqual(json.suggestedName, "address-atlas-share-safer-summary.json")
    XCTAssertEqual(csv.displayName, "Share-safer CSV summary")
    XCTAssertEqual(json.displayName, "Share-safer JSON summary")
    XCTAssertTrue(csv.isShareSafer)
    XCTAssertTrue(json.isShareSafer)
    XCTAssertTrue(ShareSafePortfolioReport.privacyNotice.contains("re-identify"))
    XCTAssertTrue(ShareSafePortfolioReport.privacyNotice.contains("not anonymous"))
    XCTAssertTrue(ExportView.shareSaferExplanation.contains("omits addresses"))
    XCTAssertTrue(ExportView.shareSaferExplanation.contains("exact amounts"))
    XCTAssertTrue(ExportView.shareSaferExplanation.contains("coarse ranges"))
  }

  func testFullPayloadNamesAndCopyMakeIdentificationExplicit() {
    let csv = ExportPayload.csv([])
    let json = ExportPayload.json(VaultDocument())

    XCTAssertTrue(csv.suggestedName.contains("full-identifying"))
    XCTAssertTrue(json.suggestedName.contains("full-identifying"))
    XCTAssertEqual(csv.displayName, "Full identifying CSV report")
    XCTAssertEqual(json.displayName, "Full identifying JSON report")
    XCTAssertFalse(csv.isShareSafer)
    XCTAssertFalse(json.isShareSafer)
    XCTAssertTrue(ExportView.fullIdentifyingExplanation.contains("identifying"))
    XCTAssertTrue(ExportView.fullIdentifyingExplanation.contains("addresses"))
    XCTAssertTrue(ExportView.fullIdentifyingExplanation.contains("exact balances"))
    XCTAssertTrue(ExportView.fullIdentifyingExplanation.contains("not backups"))
  }

  func testShareSaferPayloadsUseTheSameSourceOfTruthDTO() throws {
    let document = VaultDocument()
    let expected = try AddressAtlasExporter.shareSafeReport(for: document)

    let jsonData = try ExportPipeline.data(for: .shareSafeJSON(document))
    let decoded = try JSONDecoder.addressAtlas.decode(
      ShareSafePortfolioReport.self,
      from: jsonData
    )
    let csv = String(
      decoding: try ExportPipeline.data(for: .shareSafeCSV(document)),
      as: UTF8.self
    )

    XCTAssertEqual(decoded, expected)
    XCTAssertEqual(decoded.groups, [])
    XCTAssertTrue(csv.hasPrefix("privacy_notice,"))
    XCTAssertTrue(csv.contains(ShareSafePortfolioReport.privacyNotice))
  }
}
