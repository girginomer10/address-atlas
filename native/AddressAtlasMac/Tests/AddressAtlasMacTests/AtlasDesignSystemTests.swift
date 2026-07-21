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
