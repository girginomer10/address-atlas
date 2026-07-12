import XCTest
@testable import AddressAtlasCore

final class UserInputValidationTests: XCTestCase {
  func testAcceptsDotCommaAndScientificDecimals() {
    XCTAssertEqual(UserInputValidation.nonnegativeFiniteNumber("1.5"), 1.5)
    XCTAssertEqual(UserInputValidation.nonnegativeFiniteNumber("1,5"), 1.5)
    XCTAssertEqual(UserInputValidation.nonnegativeFiniteNumber("2e3"), 2_000)
    XCTAssertEqual(UserInputValidation.nonnegativeFiniteNumber("0"), 0)
  }

  func testRejectsInvalidNegativeAndNonFiniteValues() {
    for input in ["", "abc", "1.2.3", "1,234.5", "-1", "nan", "inf", "+infinity"] {
      XCTAssertNil(UserInputValidation.nonnegativeFiniteNumber(input), input)
    }
  }
}
