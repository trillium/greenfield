import XCTest
@testable import DictationApp

final class ParrotModelTests: XCTestCase {
    private let labels = ["background_noise_talking", "alviolar_tongue_click", "kitty_cmere_tongue_click"]
    private let patterns = """
    {"tongue-click": {"sounds": ["alviolar_tongue_click"], "threshold": {">power": 10}},
     "kitty-cmere": {"sounds": ["kitty_cmere_tongue_click"], "threshold": {">power": 10}}}
    """
    private var model: [UInt8] { ParrotModelPack.modelMagic + [UInt8](repeating: 7, count: 64) }

    private func pack(name: String = "Test model") throws -> Data {
        try ParrotModelPack.encode(model: model, labels: labels, name: name, patternsJSON: patterns, created: "2026-10-20")
    }

    func testAPackRoundTrips() throws {
        let parsed = try ParrotModelPack(data: try pack())
        XCTAssertEqual(parsed.manifest.name, "Test model")
        XCTAssertEqual(parsed.manifest.labels, labels)
        XCTAssertEqual(parsed.model, model)
        XCTAssertEqual(parsed.patternNames, ["kitty-cmere", "tongue-click"])
    }

    func testAChangedByteIsDetected() throws {
        var data = try pack()
        data[data.count / 2] ^= 0xFF
        XCTAssertThrowsError(try ParrotModelPack(data: data)) { XCTAssertEqual($0 as? ParrotModelPack.Failure, .damaged) }
    }

    func testNonPacksAreRefused() {
        XCTAssertThrowsError(try ParrotModelPack(data: Data("hello".utf8)))
        XCTAssertThrowsError(try ParrotModelPack(data: Data()))
    }

    func testAModelThatIsNotAModelIsRefused() {
        XCTAssertThrowsError(try ParrotModelPack.encode(model: [1, 2, 3], labels: labels, name: "x", patternsJSON: patterns))
    }

    func testPatternsMustUseKnownSoundsAndLabelsNeedABaseline() {
        let unknown = #"{"x": {"sounds": ["nope"]}}"#
        XCTAssertThrowsError(try ParrotModelPack.encode(model: model, labels: labels, name: "x", patternsJSON: unknown))
        let onlyA = #"{"x": {"sounds": ["a"]}}"#
        XCTAssertThrowsError(try ParrotModelPack.encode(model: model, labels: ["a", "b"], name: "x", patternsJSON: onlyA))
        XCTAssertThrowsError(try ParrotModelPack.encode(model: model, labels: ["a"], name: "x", patternsJSON: patterns))
    }
}

final class ParrotModelStoreTests: XCTestCase {
    private let labels = ["background_noise_talking", "alviolar_tongue_click"]
    private let patterns = #"{"tongue-click": {"sounds": ["alviolar_tongue_click"]}}"#

    private func pack(_ name: String, filler: UInt8) throws -> Data {
        try ParrotModelPack.encode(model: ParrotModelPack.modelMagic + [UInt8](repeating: filler, count: 32), labels: labels, name: name,
                                   patternsJSON: patterns)
    }

    private func store(validator: @escaping ParrotModelStore.Validator = { _, _ in
        ["background_noise_talking", "alviolar_tongue_click"]
    }) -> ParrotModelStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ParrotModelStore(directory: directory, validator: validator, bundled: { [1, 2, 3] })
    }

    func testTheBundledModelIsTheFallback() throws {
        let source = try store().source()
        XCTAssertTrue(source.isBundled)
        XCTAssertEqual(source.model, [1, 2, 3])
        XCTAssertNil(source.patternsJSON, "the bundled model uses the library's built-in patterns")
    }

    func testInstallingActivatesAndSwapsTheModel() throws {
        let store = store()
        let entry = try store.install(try pack("Mine", filler: 9))
        XCTAssertEqual(store.activeID, entry.id)
        let source = try store.source()
        XCTAssertFalse(source.isBundled)
        XCTAssertEqual(source.name, "Mine")
        XCTAssertEqual(source.patternsJSON, patterns)
        XCTAssertEqual(store.activePatterns(), ["tongue-click"])
        try store.activate(nil)
        XCTAssertTrue(try store.source().isBundled)
        XCTAssertEqual(store.activePatterns(), ParrotModelStore.bundledPatterns)
    }

    func testAModelTheDetectorRefusesNeverBecomesActive() throws {
        let store = store(validator: { _, _ in throw ParrotModelStore.Failure.detectorRefused("bad weights") })
        XCTAssertThrowsError(try store.install(try pack("Bad", filler: 1)))
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertNil(store.activeID)
    }

    func testAModelWhoseLabelsDisagreeWithItsPackIsRefused() throws {
        let store = store(validator: { _, _ in ["something", "else"] })
        XCTAssertThrowsError(try store.install(try pack("Liar", filler: 2)))
        XCTAssertTrue(store.list().isEmpty)
    }

    func testRemovingTheActiveModelGoesBackToTheBundledOne() throws {
        let store = store()
        let entry = try store.install(try pack("Mine", filler: 3))
        try store.remove(entry.id)
        XCTAssertTrue(try store.source().isBundled)
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertThrowsError(try store.remove("nope"))
    }

    func testTwoModelsCanBeInstalledAndSwitched() throws {
        let store = store()
        let first = try store.install(try pack("One", filler: 4))
        let second = try store.install(try pack("Two", filler: 5), activate: false)
        XCTAssertEqual(store.activeID, first.id)
        try store.activate(second.id)
        XCTAssertEqual(try store.source().name, "Two")
        XCTAssertEqual(store.list().count, 2)
    }

    func testTheBundledModelRunsInTheDetector() throws {
        let model = try ParrotModelStore.bundledModel()
        let detector = try SoundDetector(model: model)
        XCTAssertTrue(detector.labels.contains { $0.contains("tongue_click") }, "labels: \(detector.labels)")
        let silence = [Float](repeating: 0, count: 16_000)
        XCTAssertTrue(detector.push(silence).isEmpty)
    }
}
