import XCTest
@testable import DictationApp

final class EndpointerTests: XCTestCase {
    private let frame = Endpointer.frameSamples

    private func silence(_ frames: Int) -> [Float] { [Float](repeating: 0, count: frames * frame) }
    private func tone(_ frames: Int, amplitude: Float = 0.1) -> [Float] {
        (0..<(frames * frame)).map { amplitude * sin(Float($0) * 0.3) }
    }

    private func segments(_ stream: [Float], chunk: Int) -> [Endpointer.Segment] {
        var endpointer = Endpointer()
        var found: [Endpointer.Segment] = []
        var position = 0
        while position < stream.count {
            let end = min(position + chunk, stream.count)
            found += endpointer.feed(Array(stream[position..<end]))
            position = end
        }
        return found + endpointer.finish()
    }

    func testOneUtteranceKeepsPreRollAndTail() {
        let stream = silence(100) + tone(50) + silence(100)
        let found = segments(stream, chunk: 1000)
        XCTAssertEqual(found.count, 1)
        // Speech frames 100..<150: start 3 frames in, 20 frames of pre-roll back from the first speech frame.
        XCTAssertEqual(found[0].start, (100 - 20) * frame)
        XCTAssertEqual(found[0].end, (149 + 1 + 20) * frame)
        XCTAssertEqual(found[0].pcm.count, found[0].end - found[0].start)
        XCTAssertFalse(found[0].forcedCut)
    }

    func testChunkSizeDoesNotChangeTheResult() {
        let stream = silence(80) + tone(40) + silence(90) + tone(30) + silence(90)
        let reference = segments(stream, chunk: 160).map { [$0.start, $0.end] }
        XCTAssertEqual(reference.count, 2)
        for chunk in [1, 7, 333, 1000, 5000] { XCTAssertEqual(segments(stream, chunk: chunk).map { [$0.start, $0.end] }, reference) }
    }

    func testShortClickIsIgnoredAndShortPauseDoesNotSplit() {
        XCTAssertEqual(segments(silence(50) + tone(2) + silence(100), chunk: 800).count, 0)
        XCTAssertEqual(segments(silence(50) + tone(30) + silence(40) + tone(30) + silence(100), chunk: 800).count, 1)
    }

    func testOpenUtteranceIsClosedAtEndOfStream() {
        let found = segments(silence(50) + tone(30), chunk: 800)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].end, 80 * frame)
    }

    func testLongSpeechIsCutAtMaxFrames() {
        var config = Endpointer.Config()
        config.maxFrames = 100
        var endpointer = Endpointer(config: config)
        let found = endpointer.feed(silence(10) + tone(250)) + endpointer.finish()
        XCTAssertGreaterThanOrEqual(found.count, 2)
        XCTAssertTrue(found[0].forcedCut)
        XCTAssertEqual(found[0].pcm.count, 100 * frame)
    }

    func testQuietNoiseBelowThresholdNeverStartsASegment() {
        XCTAssertEqual(segments(tone(300, amplitude: 5e-4), chunk: 1600).count, 0)
    }

    func testNoisyRoomHoldsAFixedThresholdOpenButNotAFloorFollowingOne() {
        let noise = tone(100, amplitude: 0.025)  // about -35 dBFS, above the fixed -45 dB threshold
        XCTAssertGreaterThanOrEqual(segments(noise + noise, chunk: 1600).count, 1)
        var config = Endpointer.Config()
        config.floorMarginDb = 12
        var endpointer = Endpointer(config: config)
        var found = endpointer.feed(noise + noise) + endpointer.finish()
        XCTAssertEqual(found.count, 0)
        found = endpointer.feed(noise + tone(40, amplitude: 0.2) + noise + noise) + endpointer.finish()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].pcm.count / frame, 20 + 40 + 20, "pre-roll, speech and tail")
    }

    func testIsSpeakingTracksTheOpenUtterance() {
        var endpointer = Endpointer()
        _ = endpointer.feed(silence(30))
        XCTAssertFalse(endpointer.isSpeaking)
        _ = endpointer.feed(tone(10))
        XCTAssertTrue(endpointer.isSpeaking)
        _ = endpointer.feed(silence(80))
        XCTAssertFalse(endpointer.isSpeaking)
    }
}
