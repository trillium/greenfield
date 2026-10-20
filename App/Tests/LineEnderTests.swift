import XCTest
@testable import DictationApp

final class LineEnderTests: XCTestCase {
    private let phrases = ["send it", "over and out"]

    private func match(_ text: String, _ list: [String]? = nil) -> LineEnder.Match? { LineEnder.match(text, phrases: list ?? phrases) }

    func testThePhraseAtTheEndIsStripped() {
        let found = match("Please move the meeting to Thursday send it")
        XCTAssertEqual(found, .init(phrase: "send it", remaining: "Please move the meeting to Thursday"))
        XCTAssertEqual(match("Thanks for the update. Over and out.")?.remaining, "Thanks for the update.")
        XCTAssertEqual(match("OVER AND OUT!")?.remaining, "")
        XCTAssertEqual(match("Send it.")?.phrase, "send it")
    }

    func testCaseAndTrailingPunctuationDoNotMatter() {
        XCTAssertNotNil(match("see you tomorrow SEND IT"))
        XCTAssertNotNil(match("see you tomorrow, send it!?"))
        XCTAssertNotNil(match("see you tomorrow Send It..."))
    }

    func testTheJoinerBeforeThePhraseIsTidied() {
        XCTAssertEqual(match("That works for everyone, send it.")?.remaining, "That works for everyone.")
        XCTAssertEqual(match("That works for everyone - send it")?.remaining, "That works for everyone.")
        XCTAssertEqual(match("Is that fine? Send it")?.remaining, "Is that fine?", "an existing sentence mark is kept")
    }

    func testTheHypotheticalSentenceDoesNotSubmit() {
        XCTAssertNil(match("I can get it to submit hypothetically speaking"))
    }

    func testNeverInTheMiddleOfASentence() {
        XCTAssertNil(match("send it to Dana tomorrow morning"))
        XCTAssertNil(match("I will send it to the team and then we are done"))
        XCTAssertNil(match("over and out is what the pilot said at the end of the call today"))
        XCTAssertNil(match("send it again"))
        XCTAssertNil(match("resend it"), "whole words only")
        XCTAssertNil(match("they send its details"))
    }

    func testOnlyTheWholePhraseCounts() {
        XCTAssertNil(match("go ahead and send"))
        XCTAssertNil(match("it"))
        XCTAssertNil(match(""))
        XCTAssertNil(match("over out"))
    }

    func testEditablePhrases() {
        XCTAssertEqual(match("remind me at noon execute order", ["Execute Order"])?.remaining, "remind me at noon")
        XCTAssertNil(match("remind me at noon send it", ["execute order"]))
        XCTAssertNil(match("send it", []), "no phrases, no line-ender")
        XCTAssertNil(match("send it", [""]), "an empty phrase never matches")
    }

    func testTheLongerPhraseWins() {
        XCTAssertEqual(match("okay then send it now", ["it now", "send it now"])?.phrase, "send it now")
    }

    func testPhrasesAreSavedAndDefaultToTheTwoFromTheCaptain() {
        let defaults = UserDefaults(suiteName: "phrases.\(UUID().uuidString)")!
        let store = PhraseStore(defaults: defaults)
        XCTAssertEqual(store.load().map(\.text), ["send it", "over and out"])
        var edited = store.load()
        edited[0].enabled = false
        edited.append(.init(text: "that is all"))
        store.save(edited)
        XCTAssertEqual(store.load(), edited)
    }

    func testEndsQuietNeedsARealPause() {
        let tone = (0..<32_000).map { 0.2 * sin(Float($0) * 0.1) }
        XCTAssertFalse(UtteranceBuffer.endsQuiet(tone, seconds: 0.7))
        XCTAssertTrue(UtteranceBuffer.endsQuiet(tone + [Float](repeating: 0, count: 12_000), seconds: 0.7))
        XCTAssertFalse(UtteranceBuffer.endsQuiet([Float](repeating: 0, count: 100), seconds: 0.7), "too short to judge")
    }
}
