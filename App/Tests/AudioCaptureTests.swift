import AVFoundation
import XCTest
@testable import DictationApp

final class AudioCaptureTests: XCTestCase {
    func testTheSessionIsMixableSoOtherAppsAudioDoesNotInterruptIt() {
        XCTAssertEqual(AudioCapture.sessionCategory, .playAndRecord)
        XCTAssertTrue(AudioCapture.sessionOptions.contains(.mixWithOthers))
        XCTAssertTrue(AudioCapture.sessionOptions.contains(.defaultToSpeaker))
        XCTAssertEqual(AudioCapture.sessionMode, .measurement)
    }

    func testAnActivationErrorIsNamedByItsFourLetterCode() {
        XCTAssertEqual(AudioCapture.fourCharacterCode(561_017_449), " '!pri'")
        XCTAssertEqual(AudioCapture.fourCharacterCode(561_145_187), " '!rec'")
        XCTAssertEqual(AudioCapture.fourCharacterCode(560_557_684), " '!int'")
    }

    func testPlainCodesHaveNoFourLetterName() {
        XCTAssertEqual(AudioCapture.fourCharacterCode(0), "")
        XCTAssertEqual(AudioCapture.fourCharacterCode(-50), "")
        XCTAssertEqual(AudioCapture.fourCharacterCode(4660), "")
        XCTAssertEqual(AudioCapture.fourCharacterCode(0x0102_0304), "")
    }

    func testDescribeKeepsTheMessageAndAddsDomainAndCode() {
        let info = [NSLocalizedDescriptionKey: "Session activation failed"]
        let error = NSError(domain: NSOSStatusErrorDomain, code: 561_017_449, userInfo: info)
        XCTAssertEqual(AudioCapture.describe(error), "Session activation failed [NSOSStatusErrorDomain 561017449 '!pri']")
    }
}
