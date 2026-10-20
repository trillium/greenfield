import XCTest
@testable import DictationApp

final class HealthReportTests: XCTestCase {
    private func healthy() -> HealthInputs {
        var input = HealthInputs()
        input.speechModel = .ready
        input.speechModelOnDisk = true
        input.microphonePermission = .granted
        input.microphoneStatus = .listening
        input.audioFlowing = true
        input.detectorModel = "Bundled model"
        input.detectorListening = true
        input.tailnetConnected = true
        input.computers = [.init(name: "mini0", address: "mini0.example.ts.net", isActive: true, hasKey: true,
                                 answer: .ready(ReceiverClient.MacStatus(name: "mini0", version: "0.1.0", insertedCount: 3)))]
        return input
    }

    private func healthyWithoutKeys() -> HealthInputs {
        var input = healthy()
        input.computers = [.init(name: "mini0", address: "mini0.example.ts.net", isActive: true, hasKey: false,
                                 answer: .ready(ReceiverClient.MacStatus(name: "mini0")))]
        return input
    }

    private func item(_ id: String, _ input: HealthInputs) -> HealthItem? { HealthReport.build(input).first { $0.id == id } }

    func testEverythingWorkingHasNoFixes() {
        let items = HealthReport.build(healthy())
        XCTAssertTrue(items.allSatisfy { $0.level == .ok && $0.fix == nil }, "\(items.filter { $0.level != .ok })")
        XCTAssertEqual(HealthReport.summary(items), "Everything is working")
    }

    func testEveryProblemCarriesAFix() {
        var input = healthy()
        input.speechModel = .failed("boom")
        input.microphonePermission = .denied
        input.microphoneStatus = .interrupted("a call")
        input.detectorProblem = "bad model"
        input.tailnetConnected = false
        input.computers = []
        let problems = HealthReport.build(input).filter { $0.level == .problem }
        XCTAssertGreaterThanOrEqual(problems.count, 5)
        for problem in problems { XCTAssertNotNil(problem.fix, problem.title) }
        XCTAssertTrue(item("permission", input)?.fix?.contains("Settings > Greenfield") ?? false)
        XCTAssertTrue(item("tailnet", input)?.fix?.contains("Tailscale") ?? false)
    }

    func testTheSpeechModelStatesAreExplained() {
        var input = healthy()
        input.speechModel = .downloading(0.42)
        XCTAssertTrue(item("speech", input)?.detail.contains("42%") ?? false)
        input.speechModel = .loading
        XCTAssertEqual(item("speech", input)?.level, .warning)
        input.speechModel = .failed("no network")
        input.speechModelOnDisk = false
        XCTAssertTrue(item("speech", input)?.fix?.contains("internet") ?? false)
    }

    func testTheMicrophoneIsOnButSilentIsAWarning() {
        var input = healthy()
        input.audioFlowing = false
        XCTAssertEqual(item("mic", input)?.level, .warning)
    }

    func testEachComputerStateSaysWhatToDo() {
        func check(_ answer: ReceiverClient.Health?, hasKey: Bool = true) -> HealthItem {
            HealthReport.computer(.init(name: "macbook", address: "macbook.example.ts.net", isActive: true, hasKey: hasKey, answer: answer))
        }
        let keyless = check(.ready(ReceiverClient.MacStatus()), hasKey: false)
        XCTAssertEqual(keyless.level, .ok, "a missing key is never a problem")
        XCTAssertFalse(HealthReport.build(healthyWithoutKeys()).contains { $0.detail.lowercased().contains("no key") })
        XCTAssertTrue(check(.wrongKey, hasKey: false).detail.contains("asks for a key"))
        XCTAssertTrue(check(.wrongKey, hasKey: true).fix?.contains("remove the saved key") ?? false)
        XCTAssertTrue(check(.keyNotSetOnMac).fix?.contains("update and restart") ?? false)
        XCTAssertTrue(check(.ready(ReceiverClient.MacStatus(accessibility: false))).fix?.contains("Accessibility") ?? false)
        XCTAssertEqual(check(.ready(ReceiverClient.MacStatus(locked: true))).level, .warning)
        XCTAssertEqual(check(.ready(ReceiverClient.MacStatus(secureInput: true))).level, .warning)
        XCTAssertEqual(check(.unreachable("timed out")).level, .problem)
        XCTAssertTrue(check(.unreachable("timed out")).fix?.contains("Tailscale") ?? false)
        XCTAssertEqual(check(.ready(ReceiverClient.MacStatus())).level, .ok)
    }

    func testNoActiveComputerAndAQueuedOutboxAreReported() {
        var input = healthy()
        input.computers = [.init(name: "mini0", address: "mini0.example.ts.net", isActive: false, hasKey: true, answer: nil)]
        input.queued = 2
        XCTAssertNotNil(item("active", input))
        XCTAssertTrue(item("outbox", input)?.detail.contains("2 texts") ?? false)
        XCTAssertTrue(HealthReport.summary(HealthReport.build(input)).contains("need"))
    }

    @MainActor
    func testTheLiveModelBuildsAReport() {
        let store = TargetStore(defaults: isolatedDefaults(), keys: MemoryKeyStore())
        let model = AppModel(session: DictationSession(transcriber: ParakeetTranscriber()), outbox: Outbox(url: nil), targets: store)
        let items = model.healthReport()
        XCTAssertTrue(items.contains { $0.id == "computers" && $0.level == .problem })
    }
}
