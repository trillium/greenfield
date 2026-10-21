import XCTest
@testable import DictationApp

final class SpikeMathTests: XCTestCase {
    func testNormalizeSpellsDigitsAndDropsPunctuation() {
        XCTAssertEqual(SpikeMath.normalize("It costs $23.45, OK?"), ["it", "costs", "twenty", "three", "forty", "five", "ok"])
        XCTAssertEqual(SpikeMath.normalize("Let\u{2019}s go!"), ["let's", "go"])
        XCTAssertEqual(SpikeMath.normalize("9:30"), ["nine", "thirty"])
    }

    func testWordsForNumbers() {
        XCTAssertEqual(SpikeMath.words(for: 0), "zero")
        XCTAssertEqual(SpikeMath.words(for: 115), "one hundred fifteen")
        XCTAssertEqual(SpikeMath.words(for: 2026), "two thousand twenty six")
    }

    func testWordErrorsCountsEachKind() {
        let exact = SpikeMath.wordErrors(reference: "Hello, world.", hypothesis: "hello world")
        XCTAssertEqual(exact.errors, 0)
        let mixed = SpikeMath.wordErrors(reference: "the quick brown fox", hypothesis: "the quack brown fox jumps")
        XCTAssertEqual(mixed.substitutions, 1)
        XCTAssertEqual(mixed.insertions, 1)
        XCTAssertEqual(mixed.deletions, 0)
        XCTAssertEqual(mixed.rate, 0.5, accuracy: 0.001)
        let dropped = SpikeMath.wordErrors(reference: "one two three", hypothesis: "one three")
        XCTAssertEqual(dropped.deletions, 1)
    }

    func testEmptyHypothesisIsAllDeletions() {
        let empty = SpikeMath.wordErrors(reference: "one two", hypothesis: "")
        XCTAssertEqual(empty.deletions, 2)
        XCTAssertEqual(empty.rate, 1, accuracy: 0.001)
    }

    func testWordErrorsAdd() {
        let sum = SpikeMath.wordErrors(reference: "a b", hypothesis: "a c") + SpikeMath.wordErrors(reference: "d", hypothesis: "d")
        XCTAssertEqual(sum.referenceWords, 3)
        XCTAssertEqual(sum.errors, 1)
    }

    func testPercentileUsesNearestRank() {
        let values = [10.0, 20, 30, 40, 50, 60, 70, 80, 90, 100]
        XCTAssertEqual(SpikeMath.percentile(values, 50), 50)
        XCTAssertEqual(SpikeMath.percentile(values, 95), 100)
        XCTAssertEqual(SpikeMath.percentile([], 50), 0)
    }

    func testLooksFormatted() {
        XCTAssertTrue(SpikeMath.looksFormatted("Hello, world."))
        XCTAssertFalse(SpikeMath.looksFormatted("hello world"))
        XCTAssertFalse(SpikeMath.looksFormatted("Hello world"))
        XCTAssertFalse(SpikeMath.looksFormatted(""))
    }

    func testThePhraseFileDecodes() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Spike/Phrases/phrases.json")
        let phrases = try SpikePhrases.decode(Data(contentsOf: url))
        XCTAssertEqual(phrases.phrases.count, 12)
        XCTAssertEqual(Set(phrases.phrases.map(\.id)).count, 12)
        XCTAssertGreaterThan(SpikeMath.normalize(phrases.long.text).count, 150)
    }
}
