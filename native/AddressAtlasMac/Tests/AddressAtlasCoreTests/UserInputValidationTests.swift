import XCTest
@testable import AddressAtlasCore

final class UserInputValidationTests: XCTestCase {
  func testParsesGroupingAndDecimalsUsingTheSelectedLocale() {
    let english = Locale(identifier: "en_US")
    let turkish = Locale(identifier: "tr_TR")

    XCTAssertEqual(UserInputValidation.nonnegativeFiniteNumber("1,000", locale: english), 1_000)
    XCTAssertEqual(UserInputValidation.nonnegativeFiniteNumber("1,234.5", locale: english), 1_234.5)
    XCTAssertEqual(UserInputValidation.nonnegativeFiniteNumber("1.000", locale: turkish), 1_000)
    XCTAssertEqual(UserInputValidation.nonnegativeFiniteNumber("1.234,5", locale: turkish), 1_234.5)
    XCTAssertEqual(UserInputValidation.nonnegativeFiniteNumber("1,5", locale: turkish), 1.5)
    XCTAssertEqual(UserInputValidation.nonnegativeFiniteNumber("2e3", locale: english), 2_000)
    XCTAssertEqual(UserInputValidation.nonnegativeFiniteNumber("0", locale: english), 0)
  }

  func testRejectsInvalidNegativeAndNonFiniteValues() {
    let locale = Locale(identifier: "en_US")
    for input in ["", "abc", "1.2.3", "12,34", "-1", "nan", "inf", "+infinity"] {
      XCTAssertNil(UserInputValidation.nonnegativeFiniteNumber(input, locale: locale), input)
    }
  }
}
