import XCTest
@testable import InserterCore

/// A target field that behaves like a multi-line text view: typed text and Return key presses build its contents, a paste inserts
/// the text as it is. Nothing here posts a real key event.
final class RecordingField {
    var contents = ""
    var events: [String] = []

    var sink: TypingKeySink { Sink(field: self) }

    private struct Sink: TypingKeySink {
        let field: RecordingField
        func typeText(_ text: String) throws { field.events.append("text:\(text)"); field.contents += text }
        func pressReturn() throws { field.events.append("return"); field.contents += "\n" }
    }

    func flow() -> InsertionFlow {
        InsertionFlow(
            readFocusedText: { self.contents },
            readAfter: { _, _ in self.contents },
            paste: { text in self.events.append("paste:\(text)"); self.contents += text },
            type: { text in try typeWithKeys(text, using: self.sink) })
    }
}

/// An inserter over a `RecordingField`: the real insertion flow, the real typing plan, a recording sink instead of key events.
final class FieldInserter: TextInserter {
    let field = RecordingField()
    func insert(_ text: String, method: InsertMethod?) throws -> InsertOutcome { try field.flow().run(text, method: method) }
}

final class NewlineTests: XCTestCase {
    // MARK: normalising

    func testLineEndingsBecomeLineFeeds() {
        XCTAssertEqual(normalizeNewlines("a\r\nb\rc\nd"), "a\nb\nc\nd")
        XCTAssertEqual(normalizeNewlines("a\u{2028}b\u{2029}c\u{85}d"), "a\nb\nc\nd")
        XCTAssertEqual(normalizeNewlines("a\r\n\r\nb"), "a\n\nb")          // an empty line stays an empty line
        XCTAssertEqual(normalizeNewlines("end\r\n"), "end\n")               // a trailing newline stays
        XCTAssertEqual(normalizeNewlines("plain"), "plain")
    }

    // MARK: the typing plan

    func testEveryNewlineIsAReturnKeyPress() throws {
        let sink = RecordingField()
        try typeWithKeys("one\ntwo", using: sink.sink)
        XCTAssertEqual(sink.events, ["text:one", "return", "text:two"])
    }

    func testEmptyLinesAndTrailingNewlineAreKept() throws {
        let sink = RecordingField()
        try typeWithKeys("a\n\nb\n", using: sink.sink)
        XCTAssertEqual(sink.events, ["text:a", "return", "return", "text:b", "return"])
        XCTAssertEqual(sink.contents, "a\n\nb\n")
    }

    func testABareNewlineIsOneReturn() throws {
        let sink = RecordingField()
        try typeWithKeys("\n", using: sink.sink)
        XCTAssertEqual(sink.events, ["return"])
    }

    func testCRLFTypesOneReturnNotTwo() throws {
        let sink = RecordingField()
        try typeWithKeys("a\r\nb\r\n", using: sink.sink)
        XCTAssertEqual(sink.events, ["text:a", "return", "text:b", "return"])
    }

    func testTypedTextNeverContainsALineBreak() throws {
        let sink = RecordingField()
        try typeWithKeys("a\nb\r\nc\rd\u{2028}e", using: sink.sink)
        for event in sink.events where event.hasPrefix("text:") {
            XCTAssertFalse(event.contains { $0.isNewline }, event)
        }
    }

    // MARK: delivery read-back

    func testReadBackComparesTextWithItsNewlines() {
        XCTAssertEqual(judgeDelivery(before: "", after: "a\nb", text: "a\nb"), .confirmed)
        // the words are there but the line break is not: not proof of the text that was sent
        XCTAssertEqual(judgeDelivery(before: "", after: "a b", text: "a\nb"), .unconfirmed)
        XCTAssertEqual(judgeDelivery(before: "", after: "ab", text: "a\nb"), .unconfirmed)
    }

    func testReadBackAcceptsAnotherLineEndingFromTheField() {
        XCTAssertEqual(judgeDelivery(before: "", after: "a\r\nb", text: "a\nb"), .confirmed)
        XCTAssertEqual(judgeDelivery(before: "", after: "a\u{2028}b", text: "a\nb"), .confirmed)
    }

    func testTrailingNewlineIsConfirmedWhenTheFieldShowsIt() {
        XCTAssertEqual(judgeDelivery(before: "", after: "hello\n", text: "hello\n"), .confirmed)
    }

    func testAFieldThatSubmittedOnReturnIsNotACloseCall() {
        // a one-line field takes the final Return as "submit" and may clear itself: that is not a lost delivery
        XCTAssertEqual(judgeDelivery(before: "", after: "", text: "hello\n"), .unconfirmed)
        XCTAssertEqual(judgeDelivery(before: "", after: "hello", text: "hello\n"), .unconfirmed)
    }

    func testUnchangedFieldStillMeansNotDeliveredWithoutATrailingNewline() {
        XCTAssertEqual(judgeDelivery(before: "x", after: "x", text: "a\nb"), .notDelivered)
    }

    // MARK: through the daemon

    var inserter = FieldInserter()
    var handler: RequestHandler!

    override func setUp() {
        inserter = FieldInserter()
        handler = RequestHandler(keys: StubKeys(), probe: StubProbe(), inserter: inserter, name: { "Test Mac" },
                                 listening: { ["127.0.0.1:4001"] }, logger: SpyLogger())
    }

    func post(_ object: [String: Any]) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return handler.handle(HTTPRequest(method: "POST", path: "/text", headers: ["X-Dictation-Key": "good"], body: body))
    }

    func testMultiLineTextTypedThroughTheDaemonArrivesWithItsLineBreaks() {
        let text = "Dear team,\n\nThe build is green.\nThanks\n"
        let r = post(["id": "a", "text": text, "method": "type"])
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(inserter.field.contents, text)
        XCTAssertEqual(inserter.field.events, ["text:Dear team,", "return", "return", "text:The build is green.", "return", "text:Thanks", "return"])
    }

    func testMultiLineTextPastedThroughTheDaemonKeepsItsNewlines() {
        let text = "one\ntwo\n\nthree\n"
        let r = post(["id": "a", "text": text, "method": "paste"])
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(inserter.field.events, ["paste:\(text)"])
        XCTAssertEqual(inserter.field.contents, text)
    }

    func testCRLFFromAnyClientIsInsertedAsLineFeeds() {
        let r = post(["id": "a", "text": "one\r\ntwo\r\n", "method": "paste"])
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(inserter.field.contents, "one\ntwo\n")
    }

    func testABareNewlineSentOnItsOwnIsStillARequest() {
        let r = post(["id": "a", "text": "\n", "method": "type"])
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(inserter.field.events, ["return"])
    }

    func testTheDaemonLogNeverHoldsTheText() {
        let logger = SpyLogger()
        handler = RequestHandler(keys: StubKeys(), probe: StubProbe(), inserter: inserter, name: { "Test Mac" },
                                 listening: { [] }, logger: logger)
        _ = post(["id": "a", "text": "secret line one\nsecret line two"])
        XCTAssertFalse(logger.lines.joined().contains("secret"))
    }
}
