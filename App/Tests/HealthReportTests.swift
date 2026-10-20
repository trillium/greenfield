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

final class DeliveryLineTests: XCTestCase {
    private func status(_ extra: [String: Any]) -> ReceiverClient.MacStatus? {
        var body: [String: Any] = ["ok": true, "name": "mini0", "version": "0.3.0", "accessibility": true]
        body.merge(extra) { _, new in new }
        guard case .ready(let status) = ReceiverClient.interpretHealth(status: 200, data: json(body)) else { return nil }
        return status
    }

    func testAnOldAgentSaysNothingAboutDelivery() {
        XCTAssertNil(status([:])?.delivery)
    }

    func testTheDeliveryObjectIsReadLeniently() {
        let works = status(["delivery": ["ok": true, "message": "Can actually insert text"]])?.delivery
        XCTAssertEqual(works, .init(works: true, message: "Can actually insert text", fix: nil))
        let broken = status(["delivery": ["can_insert": false, "text": "Pasting is blocked", "fix": "Grant Accessibility"]])?.delivery
        XCTAssertEqual(broken, .init(works: false, message: "Pasting is blocked", fix: "Grant Accessibility"))
        XCTAssertEqual(status(["can_insert": true])?.delivery?.message, "Can actually insert text")
        XCTAssertNil(status(["delivery": "weird"])?.delivery)
    }

    func testHealthShowsTheLineAndItsFixPerComputer() {
        func item(_ line: ReceiverClient.DeliveryLine?) -> HealthItem {
            var status = ReceiverClient.MacStatus(name: "mini0", version: "0.3.0")
            status.delivery = line
            let computer = HealthInputs.Computer(name: "mini0", address: "mini0.example.ts.net", isActive: true, hasKey: false,
                                                 answer: .ready(status))
            return HealthReport.computer(computer)
        }
        let good = item(.init(works: true, message: "Can actually insert text", fix: nil))
        XCTAssertEqual(good.level, .ok)
        XCTAssertTrue(good.detail.contains("Can actually insert text"))
        let bad = item(.init(works: false, message: "the paste could not be set up", fix: "Run greenfield-inserter doctor"))
        XCTAssertEqual(bad.level, .problem)
        XCTAssertEqual(bad.fix, "Run greenfield-inserter doctor")
        XCTAssertEqual(item(nil).level, .ok, "absent on old agents: not a problem")
    }

    @MainActor
    func testSendEvidenceIsKeptOnTheOutboxItem() {
        XCTAssertEqual(ReceiverClient.interpret(status: 200, data: json(["ok": true, "delivery": "unconfirmed"])),
                       .delivered(duplicate: false, macMs: nil, delivery: "unconfirmed"))
        let outbox = Outbox(url: nil)
        let id = outbox.add(text: "x").id
        outbox.markSent(id, networkMs: 5, macMs: nil, delivery: "unconfirmed")
        XCTAssertEqual(outbox.item(id)?.delivery, "unconfirmed")
    }
}
