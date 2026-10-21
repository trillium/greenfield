import AVFoundation
import KitOnboarding
import ParrotKit
import XCTest
@testable import DictationApp

/// The app's side of Teach: a take is recorded from the app's one microphone tap (the `SampleBus`) through ParrotKit's `TeachModel`,
/// and the sound rules are held still for exactly the length of the take. The Teach logic itself (plan, library, sound pack, trainer
/// client, discovery, state machine, store swap) is tested in ParrotKit.
@MainActor
final class SessionMicrophoneTests: XCTestCase {
    private var directory: URL!
    private let bus = SampleBus()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("teach-app-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func model(ready: @escaping @MainActor () async -> String? = { nil }) -> TeachModel {
        let defaults = isolatedDefaults()
        let store = ParrotModelStore.app(directory: directory.appendingPathComponent("models"),
                                         validator: ClosureModelValidator { _, _ in [] }, bundled: { [] })
        return TeachModel(library: TeachLibrary(directory: directory.appendingPathComponent("lib")), store: store,
                          microphone: SessionMicrophone(bus: bus, makeReady: ready), addressProvider: FixedTrainerAddress(nil),
                          configuration: TrainerConfiguration(port: 8750), policy: .activateKeepingPrevious, defaults: defaults)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testATakeIsWhateverTheBusCarriedBetweenStartAndStop() async {
        let model = model()
        var states: [Bool] = []
        model.onRecordingChanged = { states.append($0) }
        model.startRecording("silence")
        await waitUntil { !states.isEmpty }
        XCTAssertEqual(model.recording, "silence")
        bus.publish([Float](repeating: 0.2, count: 16_000))
        bus.publish([Float](repeating: -0.2, count: 8_000))
        XCTAssertTrue(model.library.takes("silence").isEmpty, "nothing is saved while the take runs")
        model.stopRecording()
        bus.publish([Float](repeating: 0.9, count: 16_000))
        XCTAssertEqual(model.library.takes("silence").map(\.sampleCount), [24_000], "audio after Stop is not part of the take")
        XCTAssertEqual(states, [true, false], "the rules are held still for exactly the length of the take")
        XCTAssertEqual(bus.subscriberCount, 0, "the take lets go of the microphone tap")
    }

    func testAMicrophoneThatCannotStartSaysWhyAndPausesNothing() async {
        let model = model(ready: { "Microphone access is off." })
        var told = false
        model.onRecordingChanged = { _ in told = true }
        model.startRecording("silence")
        await waitUntil { model.errorMessage != nil }
        XCTAssertEqual(model.errorMessage, "Microphone access is off.")
        XCTAssertNil(model.recording)
        XCTAssertFalse(told)
        XCTAssertEqual(bus.subscriberCount, 0)
    }

    func testAnInterruptionOfTheAudioSessionKeepsWhatWasRecorded() async {
        let model = model()
        model.startRecording("hiss")
        await waitUntil { self.bus.subscriberCount == 1 }
        bus.publish([Float](repeating: 0.3, count: 32_000))
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        await waitUntil { model.recording == nil }
        XCTAssertEqual(model.library.takes("hiss").map(\.sampleCount), [32_000])
    }

    func testTheTrainerPortAndAddressesComeFromConfiguration() {
        XCTAssertEqual(AppTeach.configuration(info: ["ParrotTrainerPort": "8750"]).port, 8750)
        XCTAssertEqual(AppTeach.configuration(info: ["ParrotTrainerPort": "9001"]).port, 9001)
        XCTAssertEqual(AppTeach.configuration().port, 8750, "the shipped build sets PARROT_TRAINER_PORT")
        let client = AppTeach.makeClient(URL(string: "http://100.84.99.99:8750")!)
        XCTAssertNotNil(client.addressTransport, "100.x addresses go over the plain TCP transport")
    }
}

/// The app is built against a kit of the same MINOR (while MAJOR is 0), and its own checks keep the shared frameworks' promises.
/// The kit version the app declares is not typed in: `make generate` reads it from the kit checkout (scripts/kit-version.sh) into
/// Info.plist, so a kit bump needs no edit here and a stale build of an older kit is what this catches.
final class KitCompatibilityTests: XCTestCase {
    private var declared: String? { Bundle.main.object(forInfoDictionaryKey: "GreenfieldKitRequired") as? String }

    func testTheAppIsBuiltAgainstACompatibleKit() throws {
        let required = try XCTUnwrap(declared, "Info.plist has no GreenfieldKitRequired; run make generate")
        XCTAssertFalse(required.isEmpty, "GreenfieldKitRequired is empty; run make generate")
        XCTAssertTrue(ParrotKitInfo.isCompatible(required: required), "kit \(ParrotKitInfo.version): the MINOR must match \(required)")
    }

    func testTheDeclaredKitFollowsTheKitThatIsLinked() throws {
        XCTAssertEqual(declared, ParrotKitInfo.version, "the declared kit version comes from the kit checkout, not from a literal here")
    }

    func testTheRuleStillRefusesAKitOfAnotherLine() {
        XCTAssertFalse(ParrotKitInfo.isCompatible(required: "0.99.0", provided: "0.5.0"))
        XCTAssertFalse(ParrotKitInfo.isCompatible(required: "0.4.0", provided: "0.5.0"))
        XCTAssertTrue(ParrotKitInfo.isCompatible(required: "0.5.0", provided: "0.5.3"))
    }

    func testTheChecklistKeepsTheOnboardingPromises() {
        var states: [OnboardingInputs] = [OnboardingInputs()]
        var denied = OnboardingInputs()
        denied.microphone = .denied
        denied.localNetwork = .denied
        denied.speechModel = .failed("x")
        denied.detectorProblem = "x"
        states.append(denied)
        for input in states {
            let items = AppOnboarding.checklist(input)
            XCTAssertEqual(OnboardingAudit.stepsWithoutAFix(items), [])
            XCTAssertEqual(OnboardingAudit.fixLabelsThatAskToType(items), [])
            XCTAssertEqual(OnboardingAudit.duplicates(items), [])
            XCTAssertEqual(OnboardingAudit.unreadableSteps(items), [])
        }
    }
}
