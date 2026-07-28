import XCTest
@testable import OpenFire

final class StringLocalizedTests: XCTestCase {
    func testFallbackToEnglishWhenNoZhLanguage() {
        XCTAssertFalse(
            "Max Items in Menu".localized(preferredLanguage: "auto").isEmpty
        )
    }
    
    func testExplicitLanguageOverride() {
        let enString = "Copy".localized(preferredLanguage: "en")
        XCTAssertEqual(enString, "Copy")

        let zhString = "Copy".localized(preferredLanguage: "zh-Hans")
        XCTAssertEqual(zhString, "复制")
    }
}
