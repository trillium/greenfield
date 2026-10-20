import XCTest
@testable import DictationApp

final class UtteranceBufferTests: XCTestCase {
    private let rate = Int(AudioCapture.sampleRate)

    private func tone(_ seconds: Double, level: Float = 0.2) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { level * sin(Float($0) * 0.1) }
    }

    func testAHoldIncludesThePreRollAndTheTail() {
        var buffer = UtteranceBuffer()
        buffer.append(tone(2))
        buffer.beginHold()
        buffer.append(tone(1))
        buffer.endHold()
        XCTAssertNil(buffer.takeFinished(), "the tail has not arrived yet")
        buffer.append(tone(0.2))
        let utterance = buffer.takeFinished()
        XCTAssertEqual(utterance?.seconds ?? 0, 0.4 + 1 + 0.15, accuracy: 0.01)
        XCTAssertNil(buffer.takeFinished(), "an utterance is taken once")
    }

    func testFlushReleasesWithWhateverTailHasArrived() {
        var buffer = UtteranceBuffer()
        buffer.append(tone(1))
        buffer.beginHold()
        buffer.append(tone(0.5))
        buffer.endHold()
        let utterance = buffer.takeFinished(flush: true)
        XCTAssertEqual(utterance?.seconds ?? 0, 0.4 + 0.5, accuracy: 0.01)
    }

    func testPreRollIsLimitedByWhatWasHeard() {
        var buffer = UtteranceBuffer()
        buffer.append(tone(0.1))
        buffer.beginHold()
        buffer.append(tone(0.3))
        buffer.endHold()
        buffer.append(tone(0.2))
        XCTAssertEqual(buffer.takeFinished()?.seconds ?? 0, 0.1 + 0.3 + 0.15, accuracy: 0.01)
    }

    func testMemoryIsBoundedWhileIdle() {
        var buffer = UtteranceBuffer()
        for _ in 0..<600 { buffer.append(tone(1)) }
        buffer.beginHold()
        buffer.endHold()
        XCTAssertLessThan(buffer.takeFinished(flush: true)?.seconds ?? 99, 0.5)
    }

    func testAnOverlongHoldIsCutOff() {
        var buffer = UtteranceBuffer(config: .init(maxHoldSeconds: 2))
        buffer.beginHold()
        for _ in 0..<5 { buffer.append(tone(1)) }
        XCTAssertFalse(buffer.isHolding)
        XCTAssertEqual(buffer.takeFinished(flush: true)?.seconds ?? 0, 2, accuracy: 0.02)
    }

    func testSilenceIsDetected() {
        var buffer = UtteranceBuffer()
        buffer.beginHold()
        buffer.append([Float](repeating: 0, count: rate))
        buffer.endHold()
        let quiet = buffer.takeFinished(flush: true)
        XCTAssertTrue(quiet.map(buffer.isSilent) ?? false)

        buffer.beginHold()
        buffer.append(tone(1))
        buffer.endHold()
        let loud = buffer.takeFinished(flush: true)
        XCTAssertFalse(loud.map(buffer.isSilent) ?? true)
    }

    func testResetForgetsTheHold() {
        var buffer = UtteranceBuffer()
        buffer.append(tone(1))
        buffer.beginHold()
        buffer.reset()
        XCTAssertFalse(buffer.isHolding)
        XCTAssertNil(buffer.takeFinished(flush: true))
    }
}
