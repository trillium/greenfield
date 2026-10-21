import KitHealth
import ParrotKit
import SwiftUI
import UIKit
import XCTest
@testable import DictationApp

/// Line breaks in the text box survive from the box to the request body, and the box shows them with a return marker that is never sent.
final class DictationTextTests: XCTestCase {
    func testEveryLineEndingBecomesALineFeed() {
        XCTAssertEqual(DictationText.normalizingNewlines("a\r\nb\rc\nd"), "a\nb\nc\nd")
        XCTAssertEqual(DictationText.normalizingNewlines("a\u{2028}b\u{2029}c\u{85}d"), "a\nb\nc\nd")
        XCTAssertEqual(DictationText.normalizingNewlines("a\r\n\r\nb\r\n"), "a\n\nb\n", "empty lines and a trailing newline stay")
    }

    func testSendingKeepsTheLineBreaksAndTrimsOnlySpacesAtTheEnds() {
        XCTAssertEqual(DictationText.forSending("one\ntwo"), "one\ntwo")
        XCTAssertEqual(DictationText.forSending("one\n\nthree\n"), "one\n\nthree\n", "an empty line and the trailing newline are kept")
        XCTAssertEqual(DictationText.forSending("  one\r\ntwo \t"), "one\ntwo")
        XCTAssertEqual(DictationText.forSending("\nstart"), "\nstart", "a leading newline is a line break too")
    }

    func testSomethingIsSendableWhenItHasAVisibleCharacter() {
        XCTAssertFalse(DictationText.isSendable(""))
        XCTAssertFalse(DictationText.isSendable("   \t"))
        XCTAssertFalse(DictationText.isSendable("  \n \n"), "only blanks and line breaks sends nothing")
        XCTAssertTrue(DictationText.isSendable("hi"))
        XCTAssertTrue(DictationText.isSendable("\n\nhi\n"))
    }

    func testDictatedWordsJoinWithASpaceExceptAfterALineBreak() {
        XCTAssertEqual(DictationText.joining("", "hello"), "hello")
        XCTAssertEqual(DictationText.joining("one", "two"), "one two")
        XCTAssertEqual(DictationText.joining("one\n", "two"), "one\ntwo", "no stray space at the start of a new line")
        XCTAssertEqual(DictationText.joining("one ", "two"), "one two")
        XCTAssertEqual(DictationText.joining("one\n\n", "two"), "one\n\ntwo")
    }

    func testTheMarkerIsDisplayOnly() {
        XCTAssertEqual(DictationText.displayed("a\n\nb\n"), "a\(DictationText.marker)\n\(DictationText.marker)\nb\(DictationText.marker)\n")
        XCTAssertFalse(DictationText.forSending(DictationText.normalizingNewlines("a\nb\n")).contains(DictationText.marker))
        XCTAssertEqual(DictationText.lineBreakOffsets(in: "a\n\nb\n"), [1, 2, 4])
        XCTAssertEqual(DictationText.lineBreakOffsets(in: "😀\nx"), [2], "offsets count UTF-16 units, like NSString")
    }

    func testSpokenFormNamesEachLineBreak() {
        XCTAssertEqual(DictationText.spoken("a\nb"), "a, new line, b")
        XCTAssertEqual(DictationText.spoken("a\n\nb\n"), "a, new line, new line, b, new line")
        XCTAssertEqual(DictationText.spoken("plain"), "plain")
    }

    func testTheLineEnderKeepsTheLineBreaksAroundIt() {
        let phrases = ["send it"]
        XCTAssertEqual(LineEnder.match("first line\nsecond line, send it.", phrases: phrases)?.remaining, "first line\nsecond line.")
        XCTAssertEqual(LineEnder.match("a\n\nb send it", phrases: phrases)?.remaining, "a\n\nb", "an empty line is not tidied away")
        XCTAssertEqual(LineEnder.match("last line\nsend it", phrases: phrases)?.remaining, "last line\n", "the break before it stays")
        XCTAssertEqual(LineEnder.match("hello\nSend it", phrases: phrases)?.phrase, "send it", "a phrase on its own line still ends it")
    }
}

@MainActor
final class NewlineFlowTests: XCTestCase {
    private struct Rig {
        let flow: FlowController
        let session: DictationSession
        let outbox: Outbox
    }

    private func rig(outboxURL: URL? = nil) throws -> Rig {
        StubURLProtocol.install { _ in (200, json(["ok": true, "status": "inserted", "duplicate": false])) }
        let session = DictationSession(transcriber: ParakeetTranscriber())
        let store = TargetStore(defaults: isolatedDefaults(), keys: MemoryKeyStore())
        try store.save(MacTarget(name: "MacBook", address: "macbook.ts.net"), key: nil)
        let outbox = Outbox(url: outboxURL)
        let client = ReceiverClient(session: StubURLProtocol.session(), tailnetConnected: { true })
        let delivery = DeliveryService(outbox: outbox, targets: store, client: client)
        let flow = FlowController(session: session, delivery: delivery, models: testStore(),
                                  ruleStore: RuleStore(defaults: isolatedDefaults()), log: EventLog(url: nil),
                                  phraseStore: PhraseStore(defaults: isolatedDefaults()))
        return Rig(flow: flow, session: session, outbox: outbox)
    }

    private func submitted(_ rig: Rig) async throws -> OutboxItem {
        rig.flow.submit()
        for _ in 0..<100 where rig.outbox.items.first?.status != .sent { try await Task.sleep(for: .milliseconds(20)) }
        return try XCTUnwrap(rig.outbox.items.first)
    }

    func testAMultiLineBoxGoesToTheOutboxAndTheRequestBodyUnchanged() async throws {
        let outbox = temporaryFile("outbox.json")
        let rig = try rig(outboxURL: outbox)
        let text = "Dear team,\n\nThe build is green.\nThanks\n"
        rig.flow.text = text
        let item = try await submitted(rig)
        XCTAssertEqual(item.text, text, "empty lines and the trailing newline reach the outbox")
        // the saved outbox file
        let reloaded = Outbox(url: outbox)
        XCTAssertEqual(reloaded.items.first?.text, text)
        let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: outbox)) as? [[String: Any]]
        XCTAssertEqual(onDisk?.first?["text"] as? String, text)
        // the request body the Mac receives
        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(bodyJSON(request)["text"] as? String, text)
        let raw = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(raw.contains("\\n"), "the body is JSON with escaped line feeds: \(raw)")
        XCTAssertEqual(rig.flow.text, "", "the box is cleared after the send")
    }

    func testTheBodyMatchesTheRecordedMultiLineSample() async throws {
        let rig = try rig()
        let sample = try fixture("request-text-multiline.json")
        let expected = try XCTUnwrap((sample["body"] as? [String: Any])?["text"] as? String)
        rig.flow.text = expected
        _ = try await submitted(rig)
        let body = bodyJSON(try XCTUnwrap(StubURLProtocol.requests.last))
        XCTAssertEqual(body["text"] as? String, expected)
        XCTAssertEqual(Set(body.keys), Set((sample["body"] as? [String: Any] ?? [:]).keys))
    }

    func testCRLFInTheBoxIsSentAsLineFeeds() async throws {
        let rig = try rig()
        rig.flow.text = "one\r\ntwo\r\n"
        let item = try await submitted(rig)
        XCTAssertEqual(item.text, "one\ntwo\n")
        XCTAssertEqual(bodyJSON(try XCTUnwrap(StubURLProtocol.requests.last))["text"] as? String, "one\ntwo\n")
    }

    func testTheMarkerGlyphIsNeverInTheSentText() async throws {
        let rig = try rig()
        rig.flow.text = "one\n\ntwo\n"
        let item = try await submitted(rig)
        XCTAssertFalse(item.text.contains(DictationText.marker))
        let raw = String(data: StubURLProtocol.requests.last?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains(DictationText.marker))
    }

    func testABoxOfOnlyBlanksAndLineBreaksCannotBeSubmitted() throws {
        let flow = try rig().flow
        flow.text = "\n"
        XCTAssertFalse(flow.canSubmit)
        flow.text = "\n  word\n"
        XCTAssertTrue(flow.canSubmit)
    }

    func testDictationAppendsOnANewLineWithoutAStraySpace() throws {
        let rig = try rig()
        rig.flow.text = "First line\n"
        rig.session.onTranscript?("second line", 5)
        XCTAssertEqual(rig.flow.text, "First line\nsecond line")
    }

    func testAnEndingPhraseOnTheLastLineSubmitsAllTheLines() async throws {
        let rig = try rig()
        rig.flow.text = "First line\n"
        rig.session.onTranscript?("second line, send it.", 5)
        for _ in 0..<100 where rig.outbox.items.first?.status != .sent { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(rig.outbox.items.first?.text, "First line\nsecond line.")
        XCTAssertEqual(bodyJSON(try XCTUnwrap(StubURLProtocol.requests.last))["text"] as? String, "First line\nsecond line.")
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let url = folder.appendingPathComponent(name)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

/// The text box itself: a multi-line view that draws a return marker at each line break and leaves the text alone.
@MainActor
final class MarkedTextViewTests: XCTestCase {
    private func box(_ text: String) -> MarkedTextView {
        let view = MarkedTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        view.text = text
        view.layoutIfNeeded()
        return view
    }

    func testTheMarkerIsDrawnAtEachLineBreakAndTheTextIsUntouched() {
        let view = box("one\n\ntwo\n")
        var drawn: [(index: Int, glyph: String)] = []
        view.markerLayoutManager.markerDrawer = { index, glyph, _, _ in drawn.append((index, glyph)) }
        _ = UIGraphicsImageRenderer(size: view.bounds.size).image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        XCTAssertEqual(drawn.map(\.index), [3, 4, 8])
        XCTAssertEqual(Set(drawn.map(\.glyph)), [DictationText.marker])
        XCTAssertEqual(view.text, "one\n\ntwo\n", "the marker is not a character of the text")
    }

    func testTheMarkerIsInTheSecondaryColour() {
        let view = box("a\nb")
        XCTAssertEqual(view.markerLayoutManager.markerColor, UIColor.secondaryLabel)
    }

    func testTheLineBreakIsACharacterYouCanDelete() {
        let view = box("ab\ncd")
        view.selectedRange = NSRange(location: 3, length: 0)
        view.deleteBackward()
        XCTAssertEqual(view.text, "abcd")
    }

    func testReturnInsertsALineBreak() {
        let view = box("ab")
        view.selectedRange = NSRange(location: 2, length: 0)
        view.insertText("\n")
        XCTAssertEqual(view.text, "ab\n")
    }

    func testVoiceOverIsToldAboutEachLineBreak() {
        let view = box("one\ntwo")
        XCTAssertEqual(view.accessibilityValue, "one, new line, two")
        XCTAssertEqual(view.text, "one\ntwo")
    }

    func testTheBindingFollowsTheViewAndKeepsPastedLineEndingsAsLineFeeds() {
        var bound = ""
        let editor = MarkedTextEditor(text: Binding(get: { bound }, set: { bound = $0 }))
        let coordinator = editor.makeCoordinator()
        let view = box("")
        view.delegate = coordinator
        view.insertText("hello")
        view.insertText("\n")
        XCTAssertEqual(bound, "hello\n")
        // a paste arrives with CRLF
        let allowed = coordinator.textView(view, shouldChangeTextIn: NSRange(location: 6, length: 0), replacementText: "a\r\nb")
        XCTAssertFalse(allowed, "the view takes the cleaned text itself")
        XCTAssertEqual(view.text, "hello\na\nb")
        XCTAssertEqual(bound, "hello\na\nb")
    }
}
