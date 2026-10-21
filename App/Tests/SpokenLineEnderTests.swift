import ParrotKit
import KitHealth
import XCTest
@testable import DictationApp

private final class PhraseTranscriber: SpeechTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String]
    init(_ texts: [String]) { self.texts = texts }
    func isDownloaded() -> Bool { true }
    func prepare(progress: @escaping @Sendable (SpeechModelProgress) -> Void) async throws {}
    func transcribe(_ samples: [Float]) async throws -> String {
        lock.withLock { texts.count > 1 ? texts.removeFirst() : (texts.first ?? "") }
    }
}

/// The spoken line-ender through the real session, buffer, flow and delivery.
@MainActor
final class SpokenLineEnderTests: XCTestCase {
    private func tone(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16_000)).map { 0.2 * sin(Float($0) * 0.1) } }

    private struct Rig {
        let flow: FlowController
        let session: DictationSession
        let outbox: Outbox
        let log: EventLog
    }

    private func rig(_ transcripts: [String]) async throws -> Rig {
        StubURLProtocol.install { _ in (200, json(["ok": true, "status": "inserted", "duplicate": false])) }
        var machine = ListenMachine()
        _ = machine.handle(.started)
        let session = DictationSession(transcriber: PhraseTranscriber(transcripts), listen: machine)
        await session.prepareModel()
        session.attach()
        let store = TargetStore(defaults: isolatedDefaults(), keys: MemoryKeyStore())
        try store.save(MacTarget(name: "MacBook", address: "macbook.ts.net"), key: nil)
        let outbox = Outbox(url: nil)
        let client = ReceiverClient(session: StubURLProtocol.session(), tailnetConnected: { true })
        let delivery = DeliveryService(outbox: outbox, targets: store, client: client)
        let log = EventLog(url: nil)
        delivery.log = log
        let models = testStore()
        let flow = FlowController(session: session, delivery: delivery, models: models, ruleStore: RuleStore(defaults: isolatedDefaults()),
                                  log: log, phraseStore: PhraseStore(defaults: isolatedDefaults()))
        return Rig(flow: flow, session: session, outbox: outbox, log: log)
    }

    func testAFinalTranscriptEndingWithThePhraseIsStrippedAndSubmitted() async throws {
        let rig = try await rig(["Please move the meeting to Thursday, send it."])
        rig.session.capture.bus.publish(tone(1))
        rig.flow.toggleDictation()
        rig.session.capture.bus.publish(tone(1))
        rig.flow.toggleDictation()
        rig.session.capture.bus.publish(tone(0.3))
        for _ in 0..<150 where rig.outbox.items.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(rig.outbox.items.first?.text, "Please move the meeting to Thursday.", "phrase stripped, text submitted")
        XCTAssertEqual(rig.flow.text, "")
        XCTAssertEqual(rig.flow.state, .idle)
        XCTAssertTrue(rig.log.export().contains("spoken line-ender \"send it\""))
    }

    func testTheHypotheticalSentenceDoesNotSubmit() async throws {
        let rig = try await rig(["I can get it to submit hypothetically speaking"])
        rig.session.capture.bus.publish(tone(1))
        rig.flow.toggleDictation()
        rig.session.capture.bus.publish(tone(1))
        rig.flow.toggleDictation()
        rig.session.capture.bus.publish(tone(0.3))
        for _ in 0..<100 where rig.flow.text.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(rig.flow.text, "I can get it to submit hypothetically speaking")
        XCTAssertTrue(rig.outbox.items.isEmpty, "nothing was submitted")
        XCTAssertEqual(rig.flow.state, .review)
    }

    func testEarlierTextInTheBoxGoesTooWhenThePhraseEndsALaterDictation() async throws {
        let rig = try await rig(["First part.", "And the last part over and out"])
        rig.flow.text = "Already here."
        for _ in 0..<2 {
            rig.session.capture.bus.publish(tone(1))
            rig.flow.toggleDictation()
            rig.session.capture.bus.publish(tone(1))
            rig.flow.toggleDictation()
            rig.session.capture.bus.publish(tone(0.3))
            let before = rig.flow.text
            for _ in 0..<100 where rig.flow.text == before && rig.outbox.items.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        }
        for _ in 0..<100 where rig.outbox.items.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(rig.outbox.items.first?.text, "Already here. First part. And the last part")
    }

    func testSpeakingThePhraseDuringDictationEndsItByVoice() async throws {
        // Probe transcripts come first (the pause after "send it"), then the final transcript of the whole recording.
        let rig = try await rig(["Move it to Thursday send it", "Move it to Thursday send it"])
        rig.session.capture.bus.publish(tone(1))
        rig.flow.toggleDictation()
        XCTAssertTrue(rig.session.isHolding)
        rig.session.capture.bus.publish(tone(1.5))
        rig.session.capture.bus.publish([Float](repeating: 0, count: 16_000))  // the pause after the phrase
        for _ in 0..<150 where rig.session.isHolding { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(rig.session.isHolding, "dictation ended by the spoken phrase, no tap and no click")
        rig.session.capture.bus.publish(tone(0.3))
        for _ in 0..<150 where rig.outbox.items.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(rig.outbox.items.first?.text, "Move it to Thursday")
    }

    func testPhrasesCanBeSwitchedOffAndEdited() async throws {
        let rig = try await rig(["fine, send it"])
        var phrases = rig.flow.phrases
        phrases[0].enabled = false
        rig.flow.setPhrases(phrases)
        XCTAssertEqual(rig.flow.enabledPhrases, ["over and out"])
        rig.flow.setPhrases([.init(text: "that is all")])
        XCTAssertEqual(rig.flow.enabledPhrases, ["that is all"])
        rig.flow.resetPhrases()
        XCTAssertEqual(rig.flow.enabledPhrases, ["send it", "over and out"])
    }
}
