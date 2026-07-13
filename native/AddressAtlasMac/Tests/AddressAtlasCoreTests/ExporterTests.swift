import XCTest
@testable import AddressAtlasCore

final class ExporterTests: XCTestCase {
  func testCSVQuotesCarriageReturnAndCRLFFields() {
    let csv = AddressAtlasExporter.csv(
      for: [asset(walletLabel: "Treasury\rDesk", chainName: "Chain\r\nNetwork")]
    )

    XCTAssertTrue(csv.contains("\"Treasury\rDesk\""))
    XCTAssertTrue(csv.contains("\"Chain\r\nNetwork\""))
  }

  func testCSVNeutralizesFormulaMarkersAtCellAndEmbeddedRecordStarts() {
    let csv = AddressAtlasExporter.csv(
      for: [
        asset(
          walletLabel: "=HYPERLINK(\"https://example.invalid\")",
          chainName: "Safe\r+SUM(1,1)",
          symbol: "SAFE\n@COMMAND",
          name: "Safe\r\n-DANGER"
        )
      ]
    )

    XCTAssertTrue(csv.contains("\"'=HYPERLINK(\"\"https://example.invalid\"\")\""))
    XCTAssertTrue(csv.contains("\"Safe\r'+SUM(1,1)\""))
    XCTAssertTrue(csv.contains("\"SAFE\n'@COMMAND\""))
    XCTAssertTrue(csv.contains("\"Safe\r\n'-DANGER\""))
  }

  private func asset(
    walletLabel: String,
    chainName: String = "Ethereum",
    symbol: String = "TEST",
    name: String = "Test Token"
  ) -> TrackedAsset {
    TrackedAsset(
      id: "test",
      address: "0x0000000000000000000000000000000000000001",
      chainId: "ethereum",
      chainName: chainName,
      family: .evm,
      symbol: symbol,
      name: name,
      amount: 1,
      priceUsd: 2,
      valueUsd: 2,
      source: .native,
      walletLabel: walletLabel
    )
  }
}
