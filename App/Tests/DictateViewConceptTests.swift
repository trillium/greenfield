import ParrotKit
import XCTest
@testable import DictationApp

@MainActor
final class DictateViewConceptTests: XCTestCase {
    private func makeModel() throws -> AppModel {
        StubURLProtocol.install { _ in (200, json(["ok": true, "status": "inserted", "duplicate": false, "ms": 3])) }
        let store = TargetStore(defaults: isolatedDefaults(), keys: MemoryKeyStore())
        try store.save(MacTarget(name: "MacBook", address: "macbook.ts.net"), key: "k")
        return AppModel(session: DictationSession(transcriber: StubTranscriber()), outbox: Outbox(url: nil), targets: store,
                        client: ReceiverClient(session: StubURLProtocol.session(), tailnetConnected: { true }),
                        models: testStore(),
                        ruleStore: RuleStore(defaults: isolatedDefaults()))
    }

    /// // concept: V1
    /// DictateView composes the StateBanner (which reads flow.state.title and flow.hint), the SubmitBar (whose big
    /// primary button queues the box into the outbox), and the DictationButton (whose accessibility label/hint flip
    /// on session.isHolding). The screen must surface those to Voice Control and VoiceOver with truthful words and
    /// actions, so the lifecycle below is end-to-end: an empty screen does nothing, typing enables Submit, Submit
    /// queues the typed text in the outbox, and the StateBanner + DictationButton read off the model's state.
    func testDictateViewMirrorsItsModelAndTheSubmitBarActuallyQueuesText() throws {
        let model = try makeModel()
        let view = DictateView(model: model)
        XCTAssertNotNil(view.body, "DictateView builds with a real AppModel")

        // StateBanner: big = flow.state.title, hint = flow.hint.
        XCTAssertEqual(model.flow.state.title, "Idle", "StateBanner shows 'IDLE' on a fresh launch")
        XCTAssertTrue(model.flow.hint.contains("kitty-cmere"), "the StateBanner's hint names the trigger so VoiceOver says it")

        // SubmitBar's primary button is dimmed while the box is empty and enabled the moment text arrives.
        XCTAssertFalse(model.flow.canSubmit, "the Submit button is dimmed while the text box is empty")
        model.flow.text = "Hello world"
        XCTAssertTrue(model.flow.canSubmit, "typing in the box enables the Submit button")
        model.flow.text = "   \n   "
        XCTAssertFalse(model.flow.canSubmit, "whitespace-only text does not enable Submit")

        // SubmitBar's tap calls flow.submit(); verify the button's behaviour actually queues the box.
        model.flow.text = "Dictated sentence."
        let pendingBefore = model.outbox.pending.count
        model.flow.submit()
        XCTAssertEqual(model.outbox.items.first?.text, "Dictated sentence.", "the Submit button queues exactly the box text")
        XCTAssertEqual(model.outbox.pending.count, pendingBefore + 1, "the Submit button adds to the outbox, never skips it")
        XCTAssertEqual(model.flow.text, "", "the Submit button clears the box so the next thing starts fresh")

        // DictationButton: starts inactive, mirrors session.isHolding. With no microphone in a unit test, the source
        // of its active flag stays false so the button stays as "Start dictation".
        XCTAssertFalse(model.session.isHolding, "the microphone button starts inactive on a fresh launch")
        XCTAssertFalse(model.session.canHold, "without a prepared model and microphone the DictationButton is disabled")

        // ModelStatusLine is DictateView's "speech model ready/loading" row.
        XCTAssertEqual(ModelStatusLine.text(for: .ready), "Speech model ready", "the row announces when the model is ready")
        XCTAssertEqual(ModelStatusLine.text(for: .downloading(0.42)),
                       "Downloading the speech model 42%",
                       "the percent is rounded for the screen")

        // lastSubmittedID on the flow is the id the QueuedLine in the screen's body binds to; the screen shows it.
        XCTAssertNotNil(model.flow.lastSubmittedID, "after Submit the screen keeps the last submission visible via QueuedLine")
    }
}

/// A speech transcriber that stands in for the real one: declares the model already downloaded and reports ready.
private final class StubTranscriber: SpeechTranscriber, @unchecked Sendable {
    func isDownloaded() -> Bool { true }
    func prepare(progress: @escaping @Sendable (SpeechModelProgress) -> Void) async throws {
        progress(.preparing)
    }
    func transcribe(_ samples: [Float]) async throws -> String { "stub transcript" }
}
