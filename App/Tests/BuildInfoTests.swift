import XCTest
@testable import DictationApp

final class BuildInfoTests: XCTestCase {
    func testDisplayCombinesVersionAndBuild() {
        let info = BuildInfo(info: ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45"])
        XCTAssertEqual(info.display, "v1.2.3 (45)")
    }

    func testMissingKeysFallBackToPlaceholder() {
        XCTAssertEqual(BuildInfo(info: [:]).display, "v? (?)")
    }

    func testMainBundleHasABuildNumber() {
        // The host app's Info.plist is generated from Config/Base.xcconfig; a '?' would mean the wiring broke.
        XCTAssertNotEqual(BuildInfo().build, "?")
    }
}
