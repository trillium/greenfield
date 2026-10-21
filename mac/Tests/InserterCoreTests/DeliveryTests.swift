import XCTest
@testable import InserterCore

final class DeliveryTests: XCTestCase {
    func testJudge() {
        XCTAssertEqual(judgeDelivery(before: "a", after: "ahello", text: "hello"), .confirmed)
        XCTAssertEqual(judgeDelivery(before: "a", after: "a", text: "hello"), .notDelivered)
        XCTAssertEqual(judgeDelivery(before: nil, after: nil, text: "hello"), .unconfirmed)
        XCTAssertEqual(judgeDelivery(before: "a", after: nil, text: "hello"), .unconfirmed)
        XCTAssertEqual(judgeDelivery(before: "a", after: "b", text: "hello"), .unconfirmed)   // changed, but not by our text
        // a bare Return is a key press: an unchanged field does not mean it was lost
        XCTAssertEqual(judgeDelivery(before: "a", after: "a", text: "\n"), .unconfirmed)
        XCTAssertEqual(judgeDelivery(before: "a", after: "a", text: "  "), .unconfirmed)
        // text that was already there does not count unless the field changed
        XCTAssertEqual(judgeDelivery(before: "hello", after: "hello", text: "hello"), .notDelivered)
    }

    /// A fake target: `fieldAccepts` says which methods actually change the field; `readable` whether it can be read.
    final class Target {
        var field: String? = ""
        var readable = true
        var pasteWorks = true, typeWorks = true
        var calls: [String] = []
        var pasteThrows = false

        func flow() -> InsertionFlow {
            InsertionFlow(
                readFocusedText: { self.readable ? self.field : nil },
                readAfter: { _, _ in self.readable ? self.field : nil },
                paste: { t in
                    self.calls.append("paste")
                    if self.pasteThrows { throw InsertError.failed("no pasteboard") }
                    if self.pasteWorks { self.field = (self.field ?? "") + t }
                },
                type: { t in self.calls.append("type"); if self.typeWorks { self.field = (self.field ?? "") + t } })
        }
    }

    func testPasteConfirmed() throws {
        let t = Target()
        let o = try t.flow().run("hi", method: nil)
        XCTAssertEqual(o, InsertOutcome(method: .paste, delivery: .confirmed))
        XCTAssertEqual(t.calls, ["paste"])
    }

    func testFallsBackToTypingWhenPasteProvablyDidNotArrive() throws {
        let t = Target(); t.pasteWorks = false
        let o = try t.flow().run("hi", method: nil)
        XCTAssertEqual(o, InsertOutcome(method: .type, delivery: .confirmed))
        XCTAssertEqual(t.calls, ["paste", "type"])
        XCTAssertEqual(t.field, "hi")
    }

    func testNeverClaimsDeliveryWhenNothingArrives() {
        let t = Target(); t.pasteWorks = false; t.typeWorks = false
        XCTAssertThrowsError(try t.flow().run("hi", method: nil)) { XCTAssertEqual($0 as? InsertError, .notDelivered) }
        XCTAssertEqual(t.calls, ["paste", "type"])
    }

    func testUnreadableTargetIsUnconfirmedNotInserted() throws {
        let t = Target(); t.readable = false
        let o = try t.flow().run("hi", method: nil)
        XCTAssertEqual(o.delivery, .unconfirmed)
        XCTAssertEqual(t.calls, ["paste"])            // no blind retry that could type the text twice
    }

    func testExplicitMethodDoesNotFallBack() {
        let t = Target(); t.pasteWorks = false
        XCTAssertThrowsError(try t.flow().run("hi", method: .paste))
        XCTAssertEqual(t.calls, ["paste"])
    }

    func testPasteSetupFailureTypesInstead() throws {
        let t = Target(); t.pasteThrows = true
        let o = try t.flow().run("hi", method: nil)
        XCTAssertEqual(o.method, .type)
        XCTAssertEqual(t.field, "hi")
    }

    func testAccessibilityErrorPropagates() {
        let flow = InsertionFlow(readFocusedText: { nil }, readAfter: { _, _ in nil },
                                 paste: { _ in throw InsertError.accessibilityNotGranted }, type: { _ in })
        XCTAssertThrowsError(try flow.run("x", method: nil)) { XCTAssertEqual($0 as? InsertError, .accessibilityNotGranted) }
    }
}
