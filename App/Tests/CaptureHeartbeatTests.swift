import AVFoundation
import XCTest
@testable import DictationApp

/// The background heartbeat and the audio-session wording, both pure.
final class CaptureHeartbeatTests: XCTestCase {
    func testTheHeartbeatSaysNothingUntilAFullIntervalHasPassed() {
        var beat = CaptureHeartbeat()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(beat.tick(now: start, decibels: -60))
        for step in 1..<119 { XCTAssertNil(beat.tick(now: start.addingTimeInterval(Double(step) * 0.25), decibels: -60)) }
    }

    func testTheHeartbeatCountsChunksAndPeakThenStartsAgain() throws {
        var beat = CaptureHeartbeat()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = beat.tick(now: start, decibels: -60)
        _ = beat.tick(now: start.addingTimeInterval(10), decibels: -41)
        _ = beat.tick(now: start.addingTimeInterval(20), decibels: -70)
        let line = try XCTUnwrap(beat.tick(now: start.addingTimeInterval(30), decibels: -55))
        XCTAssertEqual(line, "capture alive in background: 3 audio chunks in 30 s, peak -41 dBFS, total 3")
        XCTAssertNil(beat.tick(now: start.addingTimeInterval(31), decibels: -50), "the next window starts at the last line")
        let next = try XCTUnwrap(beat.tick(now: start.addingTimeInterval(61), decibels: -50))
        XCTAssertEqual(next, "capture alive in background: 2 audio chunks in 31 s, peak -50 dBFS, total 5")
    }

    func testAShorterIntervalAndTheRunningTotalForTheDeviceTest() throws {
        var beat = CaptureHeartbeat()
        beat.interval = 5
        let start = Date(timeIntervalSince1970: 1_000)
        _ = beat.tick(now: start, decibels: -60)
        XCTAssertNil(beat.tick(now: start.addingTimeInterval(4.9), decibels: -60))
        let first = try XCTUnwrap(beat.tick(now: start.addingTimeInterval(5), decibels: -60))
        XCTAssertEqual(first, "capture alive in background: 2 audio chunks in 5 s, peak -60 dBFS, total 2")
        _ = beat.tick(now: start.addingTimeInterval(7), decibels: -60)
        let second = try XCTUnwrap(beat.tick(now: start.addingTimeInterval(10.2), decibels: -60))
        XCTAssertEqual(second, "capture alive in background: 2 audio chunks in 5 s, peak -60 dBFS, total 4")
    }

    func testResettingTheHeartbeatForgetsTheWindow() {
        var beat = CaptureHeartbeat()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = beat.tick(now: start, decibels: -60)
        beat.reset()
        XCTAssertNil(beat.tick(now: start.addingTimeInterval(40), decibels: -60), "foreground time is not counted as background")
    }

    // MARK: Audio session wording

    func testInterruptionReasonsAreReadable() {
        XCTAssertTrue(AudioCapture.interruptionReason(nil).contains("call"))
        XCTAssertTrue(AudioCapture.interruptionReason(0).contains("Siri"))
        XCTAssertEqual(AudioCapture.interruptionReason(2), "the built-in microphone was muted")
        XCTAssertEqual(AudioCapture.interruptionReason(4), "the audio route was disconnected")
        XCTAssertEqual(AudioCapture.interruptionReason(99), "audio interruption (reason 99)")
    }

    func testRouteChangeReasonsAreReadable() {
        let unplugged = AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        XCTAssertEqual(AudioCapture.routeReason(unplugged), "input or output disconnected")
        XCTAssertEqual(AudioCapture.routeReason(nil), "unknown")
        XCTAssertEqual(AudioCapture.routeReason(9_999), "reason 9999")
    }
}
