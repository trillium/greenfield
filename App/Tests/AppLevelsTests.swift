import KitHealth
import ParrotKit
import XCTest
@testable import DictationApp

/// concept: S3. The trigger levels in this app: what the detector is built with, what a change on the Levels screen does to what the
/// rules hear, and where the settings live. The kit tests its own side (the settings, the catalogue, the model, the screen); these run the
/// real detector over the recorded clip staged by `make core`.
@MainActor
final class AppLevelsTests: XCTestCase {
    /// What a sound looked like, without the event's random id, so two runs can be compared.
    private struct Heard: Equatable {
        let time: Double
        let pattern: String
        let topClass: String
        let probability: Double
        let power: Double
    }

    private func clip() throws -> [Float] {
        guard let url = Bundle(for: AppLevelsTests.self).url(forResource: "session_clip", withExtension: "wav") else {
            throw XCTSkip("session_clip.wav is not in the test bundle: run make core")
        }
        return try WavFile.readMonoFloat(url: url)
    }

    private func replay(_ samples: [Float], patterns: String?, gain: Double = 1) throws -> [Heard] {
        let detector = try SoundDetector(model: try ParrotModelStore.bundledModel(), patternsJSON: patterns)
        var scaled: [Float] = []
        var heard: [Heard] = []
        var position = 0
        while position < samples.count {
            let chunk = Array(samples[position..<min(position + 1_600, samples.count)])
            if gain == 1 { scaled = chunk } else { chunk.withUnsafeBufferPointer { InputGain.apply($0, gain: gain, into: &scaled) } }
            heard += detector.push(scaled).map {
                Heard(time: $0.time, pattern: $0.pattern, topClass: $0.topClass, probability: $0.probability, power: $0.power)
            }
            position += 1_600
        }
        return heard
    }

    private func appLevels(store: NoiseLevelsStoring = InMemoryNoiseLevelsStore()) -> AppLevels {
        AppLevels(models: .app(directory: temporaryFile()), store: store)
    }

    private func source() throws -> ParrotModelStore.Source { try ParrotModelStore.app(directory: temporaryFile()).source() }

    // MARK: the catalogue the shipped model comes with

    func testTheShippedPatternsAreInTheBundleAndMatchTheBundledModelsSounds() throws {
        let catalogue = try PatternCatalogue(json: try AppLevels.bundledPatterns())
        XCTAssertEqual(Set(catalogue.names), Set(ParrotModelStore.bundledPatterns + ["suppress_clicks"]))
        XCTAssertEqual(catalogue.names.count, 8)
    }

    func testAtTheDefaultsTheRenderedPatternsDetectExactlyWhatTheBuiltInSetDoes() throws {
        let samples = try clip()
        let catalogue = try PatternCatalogue(json: try AppLevels.bundledPatterns())
        let builtIn = try replay(samples, patterns: nil)
        let rendered = try replay(samples, patterns: try catalogue.rendered(NoiseLevels.defaults(for: catalogue)))
        XCTAssertFalse(builtIn.isEmpty, "the clip has sounds in it")
        XCTAssertEqual(rendered, builtIn, "a level nobody touched cannot change what the app detects")
    }

    func testRaisingOneLevelSilencesOnlyThatSound() throws {
        let samples = try clip()
        let catalogue = try PatternCatalogue(json: try AppLevels.bundledPatterns())
        var levels = NoiseLevels.defaults(for: catalogue)
        let baseline = try replay(samples, patterns: try catalogue.rendered(levels))
        XCTAssertGreaterThan(baseline.filter { $0.pattern == "tongue-click" }.count, 0)
        levels.setThreshold(NoiseLevels.thresholdRange.upperBound, for: "tongue-click")
        let raised = try replay(samples, patterns: try catalogue.rendered(levels))
        XCTAssertTrue(raised.allSatisfy { $0.pattern != "tongue-click" }, "a level of 400 is unreachable")
        XCTAssertEqual(raised.filter { $0.pattern == "hiss" }, baseline.filter { $0.pattern == "hiss" })
    }

    func testSwitchingASoundOffTakesItOutOfTheDetectionPath() throws {
        let samples = try clip()
        let catalogue = try PatternCatalogue(json: try AppLevels.bundledPatterns())
        var levels = NoiseLevels.defaults(for: catalogue)
        let baseline = try replay(samples, patterns: try catalogue.rendered(levels))
        levels.setEnabled(false, for: "lip-pop")
        let off = try replay(samples, patterns: try catalogue.rendered(levels))
        XCTAssertTrue(off.allSatisfy { $0.pattern != "lip-pop" })
        XCTAssertGreaterThan(baseline.filter { $0.pattern == "lip-pop" }.count, 0)
    }

    /// The gain is the only knob that reaches a sound quieter than the detector's gate.
    func testTheInputGainMovesTheWholeSignalAgainstTheGate() throws {
        let samples = try clip()
        let catalogue = try PatternCatalogue(json: try AppLevels.bundledPatterns())
        let patterns = try catalogue.rendered(NoiseLevels.defaults(for: catalogue))
        let normal = try replay(samples, patterns: patterns).count
        let quieter = try replay(samples, patterns: patterns, gain: 0.25).count
        XCTAssertLessThan(quieter, normal, "attenuating the same clip must lose sounds under the gate")
    }

    // MARK: what the detector is built with

    func testAFreshInstallBuildsTheDetectorAtTheCatalogueDefaultsWithUnityGain() throws {
        let levels = appLevels()
        let setup = levels.setup(for: try source())
        XCTAssertEqual(setup.gain, 1)
        let catalogue = try XCTUnwrap(levels.catalogue)
        XCTAssertEqual(setup.patternsJSON, try catalogue.rendered(NoiseLevels.defaults(for: catalogue)))
        XCTAssertEqual(levels.levels, NoiseLevels.defaults(for: catalogue))
    }

    func testSavedLevelsAndGainReachTheDetector() throws {
        let saved = NoiseLevels(inputGain: 3, levels: ["tongue-click": NoiseLevel(isEnabled: false), "hiss": NoiseLevel(threshold: 90)])
        let store = InMemoryNoiseLevelsStore(saved)
        let setup = appLevels(store: store).setup(for: try source())
        XCTAssertEqual(setup.gain, 3)
        let rendered = try XCTUnwrap(setup.patternsJSON)
        XCTAssertFalse(PatternCatalogue.topLevelKeys(of: rendered).contains("tongue-click"), "a switched-off sound is not in the set")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: [String: Any]])
        XCTAssertEqual((root["hiss"]?["threshold"] as? [String: Any])?[">power"] as? Double, 90)
    }

    func testWithoutAPatternFileTheModelsOwnPatternsAreUsedAndTheGainStillApplies() throws {
        let store = InMemoryNoiseLevelsStore(NoiseLevels(inputGain: 2))
        let levels = AppLevels(models: .app(directory: temporaryFile()), store: store) {
            throw PatternCatalogue.Failure.unavailable("No file.")
        }
        XCTAssertNil(levels.catalogue)
        XCTAssertEqual(levels.unavailable, "No file.")
        let setup = levels.setup(for: try source())
        XCTAssertNil(setup.patternsJSON, "the bundled model builds from the library's built-in set, as it always did")
        XCTAssertEqual(setup.gain, 2)
        XCTAssertNotNil(levels.makeModel().unavailable)
    }

    func testAModelPackBringsItsOwnSoundsAndTheLevelsFollow() throws {
        let packs = ParrotModelStore.app(directory: temporaryFile(), validator: ClosureModelValidator { _, _ in ["silence", "cough"] },
                                         bundled: { [] })
        let json = #"{"cough":{"sounds":["cough"],"threshold":{">power":20,">probability":0.9}}}"#
        _ = try packs.install(try ParrotModelPack.encode(model: ParrotModelPack.modelMagic + [1, 2, 3], labels: ["silence", "cough"],
                                                         name: "Mine", patternsJSON: json))
        let store = InMemoryNoiseLevelsStore(NoiseLevels(levels: ["tongue-click": NoiseLevel(threshold: 90)]))
        let levels = AppLevels(models: packs, store: store)
        XCTAssertEqual(levels.catalogue?.names, ["cough"])
        XCTAssertEqual(levels.levels.levels.keys.sorted(), ["cough"], "the old model's sounds go, the new one's start at their own level")
        XCTAssertEqual(levels.levels.level("cough").threshold, 20)
    }

    func testApplyingLevelsRebuildsTheDetector() {
        let levels = appLevels()
        var rebuilds = 0
        levels.rebuild = { rebuilds += 1 }
        levels.apply(NoiseLevels(inputGain: 2))
        XCTAssertEqual(rebuilds, 1)
        XCTAssertEqual(levels.levels.inputGain, 2)
    }

    // MARK: where they live

    func testTheLevelsAreKeptInAFileInTheAppsOwnSandboxNotInTheSharedDefaults() throws {
        XCTAssertTrue(AppLevels.standardURL.path.hasSuffix("Sounds/levels.json"))
        XCTAssertTrue(AppLevels.standardURL.path.contains("Application Support"))
        let url = temporaryFile().appendingPathComponent("levels.json")
        let store = AppLevels.standardStore(url: url)
        XCTAssertNil(store.load())
        store.save(NoiseLevels(inputGain: 2.5))
        XCTAssertEqual(AppLevels.standardStore(url: url).load()?.inputGain, 2.5)
        XCTAssertNil(UserDefaults.standard.data(forKey: UserDefaultsNoiseLevelsStore.key), "nothing goes in the defaults domain")
    }

    func testTheSupportLogNeverCarriesTheLevels() throws {
        let log = EventLog(url: nil)
        let (flow, _) = try flow(store: InMemoryNoiseLevelsStore(), log: log)
        let model = flow.levels.makeModel()
        model.raiseGain()
        model.raiseThreshold(for: "hiss")
        XCTAssertFalse(log.export().lowercased().contains("level"), log.export())
    }

    // MARK: the rules hear what the levels allow

    private func flow(store: NoiseLevelsStoring, log: EventLog = EventLog(url: nil)) throws -> (FlowController, DictationSession) {
        let session = DictationSession(transcriber: ParakeetTranscriber())
        let targets = TargetStore(defaults: isolatedDefaults(), keys: MemoryKeyStore())
        let client = ReceiverClient(session: StubURLProtocol.session(), tailnetConnected: { true })
        let delivery = DeliveryService(outbox: Outbox(url: nil), targets: targets, client: client)
        let flow = FlowController(session: session, delivery: delivery, models: .app(directory: temporaryFile()),
                                  ruleStore: RuleStore(defaults: isolatedDefaults()), log: log, levelsStore: store)
        return (flow, session)
    }

    private func play(_ samples: [Float], on session: DictationSession) async throws {
        var position = 0
        while position < samples.count {
            session.capture.bus.publish(Array(samples[position..<min(position + 1_600, samples.count)]))
            position += 1_600
        }
        for _ in 0..<50 { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// How many times the log says this sound was heard (the list on screen keeps only the last hundred, mostly the model's own noise).
    private func heardCount(_ pattern: String, in flow: FlowController) -> Int {
        flow.log.export().components(separatedBy: "[sound] \(pattern) ").count - 1
    }

    func testASoundSwitchedOffOnTheLevelsScreenNeverReachesTheRules() async throws {
        let samples = try clip()
        let store = InMemoryNoiseLevelsStore()
        let (flow, session) = try flow(store: store)
        flow.startDetector()
        try await play(samples, on: session)
        let clicks = heardCount("tongue-click", in: flow)
        let hisses = heardCount("hiss", in: flow)
        XCTAssertGreaterThan(clicks, 0, "at the defaults the clip's clicks are heard")

        let screen = flow.levels.makeModel()
        screen.setEnabled(false, for: "tongue-click")
        XCTAssertEqual(store.stored?.level("tongue-click").isEnabled, false, "saved")
        try await play(samples, on: session)
        XCTAssertEqual(heardCount("tongue-click", in: flow), clicks, "the detector was rebuilt without it, so no rule can fire on it")
        XCTAssertGreaterThan(heardCount("hiss", in: flow), hisses, "the rest are still heard")
    }

    func testTheMeterOnTheLevelsScreenFollowsTheMicrophoneAfterTheGain() async throws {
        let (flow, session) = try flow(store: InMemoryNoiseLevelsStore(NoiseLevels(inputGain: 4)))
        flow.startDetector()
        let screen = flow.levels.makeModel()
        var readings: [LevelReading] = []
        flow.levels.startReadings { readings.append($0) }
        session.capture.bus.publish([Float](repeating: 0.01, count: 1_600))
        for _ in 0..<50 where readings.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let reading = try XCTUnwrap(readings.first)
        XCTAssertEqual(reading.power, 40, accuracy: 0.01, "0.01 is power 10; the gain of 4 makes it 40")
        XCTAssertEqual(screen.levels.inputGain, 4)
        flow.levels.stopReadings()
    }

    func testThePhoneIsListeningOnlyWhenTheDetectorAndTheMicrophoneAre() throws {
        let (flow, _) = try flow(store: InMemoryNoiseLevelsStore())
        XCTAssertFalse(flow.levels.isListening, "nothing is listening yet")
        flow.startDetector()
        XCTAssertFalse(flow.levels.isListening, "the detector is up but the microphone is not")
    }
}
