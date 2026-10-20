import XCTest
@testable import DictationApp

private final class FakeTranscriber: SpeechTranscriber, @unchecked Sendable {
    var text = "Hello, world."
    var failure: Error?
    var prepareFailure: Error?
    private(set) var transcribed: [Int] = []

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.5)
        if let prepareFailure { throw prepareFailure }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        transcribed.append(samples.count)
        if let failure { throw failure }
        return text
    }
}

private struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }

@MainActor
final class DictationSessionTests: XCTestCase {
    private func utterance(_ seconds: Double = 1) -> UtteranceBuffer.Utterance {
        let pcm = (0..<Int(seconds * 16_000)).map { 0.2 * sin(Float($0) * 0.1) }
        return .init(pcm: pcm, peakDb: UtteranceBuffer.peakDb(pcm))
    }

    func testPreparingTheModelEndsReady() async {
        let session = DictationSession(transcriber: FakeTranscriber())
        XCTAssertEqual(session.model, .notLoaded)
        await session.prepareModel()
        XCTAssertEqual(session.model, .ready)
    }

    func testAFailedModelCanBeRetried() async {
        let fake = FakeTranscriber()
        fake.prepareFailure = Boom()
        let session = DictationSession(transcriber: fake)
        await session.prepareModel()
        XCTAssertEqual(session.model, .failed("boom"))
        fake.prepareFailure = nil
        await session.prepareModel()
        XCTAssertEqual(session.model, .ready)
    }

    func testAnUtteranceBecomesATranscript() async {
        let fake = FakeTranscriber()
        let session = DictationSession(transcriber: fake)
        var received: [(String, Int)] = []
        session.onTranscript = { received.append(($0, $1)) }
        await session.finish(utterance(), silent: false)
        XCTAssertEqual(received.map(\.0), ["Hello, world."])
        XCTAssertEqual(session.lastTranscript, "Hello, world.")
        XCTAssertEqual(session.notice, .none)
        XCTAssertEqual(session.transcribing, 0)
    }

    func testSilenceNeverReachesTheModel() async {
        let fake = FakeTranscriber()
        let session = DictationSession(transcriber: fake)
        await session.finish(utterance(), silent: true)
        XCTAssertEqual(session.notice, .nothingHeard)
        XCTAssertTrue(fake.transcribed.isEmpty)
    }

    func testAnEmptyTranscriptSaysNothingWasHeard() async {
        let fake = FakeTranscriber()
        fake.text = ""
        let session = DictationSession(transcriber: fake)
        var called = false
        session.onTranscript = { _, _ in called = true }
        await session.finish(utterance(), silent: false)
        XCTAssertEqual(session.notice, .nothingHeard)
        XCTAssertFalse(called)
    }

    func testAModelErrorIsShownNotSwallowed() async {
        let fake = FakeTranscriber()
        fake.failure = Boom()
        let session = DictationSession(transcriber: fake)
        await session.finish(utterance(), silent: false)
        XCTAssertEqual(session.notice, .failed("boom"))
    }

    func testHoldIsRefusedUntilModelAndMicrophoneAreReady() async {
        let session = DictationSession(transcriber: FakeTranscriber())
        session.beginHold()
        XCTAssertFalse(session.isHolding)
        XCTAssertFalse(session.canHold)
    }
}

final class UtteranceGateTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var utterances: [(UtteranceBuffer.Utterance, Bool)] = []
    }

    private func tone(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16_000)).map { 0.2 * sin(Float($0) * 0.1) } }

    func testTheHandlerGetsTheUtteranceWhenTheTailArrives() {
        let gate = UtteranceGate()
        let box = Box()
        gate.setHandler { box.utterances.append(($0, $1)) }
        gate.append(tone(1))
        gate.begin()
        gate.append(tone(1))
        XCTAssertTrue(gate.end())
        XCTAssertTrue(box.utterances.isEmpty)
        gate.append(tone(0.3))
        XCTAssertEqual(box.utterances.count, 1)
        XCTAssertFalse(box.utterances[0].1, "a tone is not silence")
        gate.append(tone(0.3))
        XCTAssertEqual(box.utterances.count, 1, "one utterance per hold")
    }

    func testReleasingWithoutAHoldDoesNothing() {
        let gate = UtteranceGate()
        XCTAssertFalse(gate.end())
        XCTAssertNil(gate.flush())
    }

    func testFlushFinishesAnUtteranceWhoseTailNeverCame() {
        let gate = UtteranceGate()
        gate.append(tone(1))
        gate.begin()
        gate.append(tone(0.5))
        gate.end()
        let flushed = gate.flush()
        XCTAssertEqual(flushed?.0.seconds ?? 0, 0.9, accuracy: 0.02)
    }

    func testSilenceIsFlagged() {
        let gate = UtteranceGate()
        let box = Box()
        gate.setHandler { box.utterances.append(($0, $1)) }
        gate.begin()
        gate.append([Float](repeating: 0, count: 16_000))
        gate.end()
        gate.append([Float](repeating: 0, count: 4_000))
        XCTAssertEqual(box.utterances.first?.1, true)
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    private func makeModel() throws -> AppModel {
        StubURLProtocol.install { _ in (200, json(["ok": true, "status": "inserted", "duplicate": false, "ms": 3])) }
        let store = TargetStore(defaults: isolatedDefaults(), keys: MemoryKeyStore())
        try store.save(MacTarget(name: "MacBook", address: "macbook.ts.net"), key: "k")
        return AppModel(session: DictationSession(transcriber: FakeTranscriber()), outbox: Outbox(url: nil), targets: store,
                        client: ReceiverClient(session: StubURLProtocol.session(), tailnetConnected: { true }),
                        models: ParrotModelStore(directory: temporaryFile(), bundled: { [] }),
                        ruleStore: RuleStore(defaults: isolatedDefaults()))
    }

    func testSubmittedTextIsKeptThenSentToTheSelectedMac() async throws {
        let model = try makeModel()
        model.flow.text = "Hello there."
        model.flow.submit()
        XCTAssertEqual(model.outbox.items.first?.text, "Hello there.")
        XCTAssertEqual(model.flow.text, "", "the box is cleared on submit")
        for _ in 0..<50 where model.outbox.items.first?.status != .sent { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.outbox.items.first?.status, .sent)
    }

    func testSubmittingNothingSendsNothing() throws {
        let model = try makeModel()
        model.flow.text = "  \n "
        model.flow.submit()
        XCTAssertTrue(model.outbox.items.isEmpty)
    }

    func testTheModelNoticeCreditsNvidiaAndTheLicence() {
        let notice = ModelInfo.modelNotice
        XCTAssertTrue(notice.contains("NVIDIA"))
        XCTAssertTrue(notice.contains("CC BY 4.0"))
        XCTAssertTrue(notice.contains("Core ML"), "the conversion is a stated change")
        XCTAssertEqual(ModelInfo.modelLicenceURL.absoluteString, "https://creativecommons.org/licenses/by/4.0/")
        XCTAssertTrue(ModelInfo.credits.contains { $0.name == "FluidAudio" && $0.licence.contains("Apache") })
    }
}
