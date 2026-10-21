import ParrotKit
import XCTest
@testable import DictationApp

@MainActor
final class SubmitBarConceptTests: XCTestCase {
    private func makeModel() throws -> (AppModel, MacTarget) {
        StubURLProtocol.install { _ in (200, json(["ok": true, "status": "inserted", "duplicate": false, "ms": 3])) }
        let store = TargetStore(defaults: isolatedDefaults(), keys: MemoryKeyStore())
        let desktop = MacTarget(name: "iMac", address: "imac.ts.net")
        try store.save(MacTarget(name: "MacBook", address: "macbook.ts.net"), key: "k")
        try store.save(desktop, key: "k2")
        let model = AppModel(session: DictationSession(transcriber: SubmitStubTranscriber()), outbox: Outbox(url: nil),
                             targets: store, client: ReceiverClient(session: StubURLProtocol.session(), tailnetConnected: { true }),
                             models: testStore(), ruleStore: RuleStore(defaults: isolatedDefaults()))
        return (model, desktop)
    }

    /// // concept: V2
    /// SubmitBar is the always-visible bar under the box: a Retry all row that only exists while something is waiting, and the big
    /// Submit button whose title names the computer the text will go to. It must be reachable by Voice Control and honest with
    /// VoiceOver, so the assertions below walk its states: nothing queued means no retry row, the Submit button's dimmed state really
    /// does refuse the text (so the hint that explains it is true), typing enables it, and its tap queues exactly the box text.
    func testSubmitBarOffersRetryOnlyWhenSomethingWaitsAndSubmitsTheBoxToTheNamedComputer() throws {
        let (model, desktop) = try makeModel()
        XCTAssertNotNil(SubmitBar(model: model).body, "SubmitBar builds against a real AppModel")

        // The Submit button's title is read from the selected computer, so choosing another Mac changes the words Voice Control says.
        XCTAssertEqual(model.targets.selected?.name, "MacBook", "the first computer added becomes the one the bar names")
        model.targets.select(desktop.id)
        XCTAssertEqual(model.targets.selected?.name, "iMac", "the bar names the computer chosen in the Computers tab")

        // Nothing is waiting yet, so the Retry all row is not on screen at all.
        XCTAssertTrue(model.outbox.pending.isEmpty, "a fresh app has nothing waiting to send, so there is no Retry all row")

        // The dimmed Submit state is truthful: empty and whitespace-only text are refused rather than queued as blank.
        XCTAssertFalse(model.flow.canSubmit, "the Submit button is dimmed while the box is empty")
        model.flow.text = "   \n  "
        XCTAssertFalse(model.flow.canSubmit, "a box holding only spaces and line breaks still counts as empty")
        model.flow.submit()
        XCTAssertTrue(model.outbox.pending.isEmpty, "tapping a dimmed Submit queues nothing")

        // Typing is what turns the button on, and its tap sends exactly the trimmed words.
        model.flow.text = "  Remember the milk.  "
        XCTAssertTrue(model.flow.canSubmit, "real words in the box enable the Submit button")
        model.flow.submit()
        XCTAssertEqual(model.outbox.items.first?.text, "Remember the milk.", "Submit queues the box words without their stray spaces")
        XCTAssertEqual(model.flow.text, "", "Submit empties the box so the next thing starts from nothing")

        // Now something is waiting, so the retry row appears and counts what it will resend in words Voice Control can say.
        XCTAssertEqual(model.outbox.pending.count, 1, "the queued text is pending, which is what the retry row is for")
        XCTAssertEqual(SubmitBar.retryLabel(queued: 1), "Retry all, 1 text", "one waiting text is announced as a single text")
        XCTAssertEqual(SubmitBar.retryLabel(queued: 3), "Retry all, 3 texts", "several waiting texts are announced as a count")

        // The bar is honest the whole way round: once the box empties the button dims again, so it never looks sendable when it is not.
        XCTAssertFalse(model.flow.canSubmit, "an empty box dims the Submit button again after a send")
    }
}

/// A speech transcriber that stands in for the real one: the model is already downloaded, so nothing is fetched.
private final class SubmitStubTranscriber: SpeechTranscriber, @unchecked Sendable {
    func isDownloaded() -> Bool { true }
    func prepare(progress: @escaping @Sendable (SpeechModelProgress) -> Void) async throws { progress(.preparing) }
    func transcribe(_ samples: [Float]) async throws -> String { "stub transcript" }
}
