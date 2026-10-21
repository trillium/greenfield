import XCTest
@testable import InserterCore

final class ReadinessTests: XCTestCase {
    let bin = "/h/.local/share/greenfield-inserter/greenfield-inserter"

    func ok(_ id: String) -> HealthCheck { HealthCheck(id, id, .pass, detail: "fine") }
    func bad(_ id: String, _ detail: String = "broken") -> HealthCheck { HealthCheck(id, id, .fail, detail: detail, why: "w", fix: "f") }

    var allGood: [HealthCheck] {
        ["tailnet", "binary", "plist", "launchd", "launchd-throttle", "running-build", "daemon", "listening", "auth", "accessibility",
         "unlocked", "secure-input", "version", "app-compatible", "can-insert"].map(ok)
    }

    func with(_ replacing: HealthCheck) -> [HealthCheck] { allGood.map { $0.id == replacing.id ? replacing : $0 } }

    func step(_ checks: [HealthCheck]) -> String? { if case .next(let s) = readiness(checks: checks, bin: bin) { return s }; return nil }

    func testEverythingFineIsReady() {
        XCTAssertEqual(readiness(checks: allGood, bin: bin), .ready(notes: []))
    }

    func testEachProblemGivesExactlyOnePlainStep() {
        XCTAssertTrue(step(with(bad("binary")))!.contains("mac/install.sh"))
        XCTAssertTrue(step(with(bad("launchd")))!.contains("restart"))
        XCTAssertTrue(step(with(bad("daemon")))!.contains("restart"))
        XCTAssertTrue(step(with(bad("tailnet")))!.contains("Tailscale"))
        XCTAssertTrue(step(with(bad("auth")))!.contains("Tailscale"))
        XCTAssertTrue(step(with(bad("running-build")))!.contains("restart"))
        XCTAssertTrue(step(with(bad("accessibility")))!.contains("System Settings > Privacy & Security > Accessibility"))
        XCTAssertTrue(step(with(bad("can-insert", "no delivery has been confirmed")))!.contains("selftest"))
        XCTAssertTrue(step(with(bad("can-insert", "the last attempt 1 seconds ago did not arrive: x")))!.contains("doctor"))
        for id in ["binary", "tailnet", "accessibility", "can-insert"] {
            let s = step(with(bad(id)))!
            XCTAssertFalse(s.contains("\n")); XCTAssertEqual(s.filter { $0 == "." }.count > 0, true)
        }
    }

    func testOnlyTheFirstProblemInFixOrderIsShown() {
        // Accessibility and delivery both red: the person should do the Accessibility step first.
        let both = allGood.map { ["accessibility", "can-insert"].contains($0.id) ? bad($0.id) : $0 }
        XCTAssertTrue(step(both)!.contains("Accessibility"))
        XCTAssertFalse(step(both)!.contains("selftest"))
        // not installed beats everything
        let none = allGood.map { bad($0.id) }
        XCTAssertTrue(step(none)!.contains("mac/install.sh"))
    }

    func testAGrantThatArrivedAfterStartSaysWaitNotClickAgain() {
        let s = step(with(bad("accessibility", "granted after the daemon started; this process cannot use it yet")))!
        XCTAssertTrue(s.hasPrefix("Almost there")); XCTAssertFalse(s.contains("Switch on"))
    }

    func testLockedScreenAndSecureInputAreNotesNotSteps() {
        let r = readiness(checks: with(bad("unlocked")), bin: bin)
        if case .ready(let notes) = r { XCTAssertTrue(notes.joined().contains("locked")) } else { XCTFail("a locked screen is not a reason to be not ready") }
        if case .ready(let notes) = readiness(checks: with(bad("secure-input")), bin: bin) { XCTAssertTrue(notes.joined().contains("password")) } else { XCTFail() }
    }

    func testAnAppOutOfRangeIsANote() {
        let warn = HealthCheck("app-compatible", "App compatible", .warn, detail: "the newest app seen is older")
        if case .ready(let notes) = readiness(checks: with(warn), bin: bin) { XCTAssertEqual(notes, ["the newest app seen is older"]) } else { XCTFail() }
    }

    func testChecklistRows() {
        func states(_ cs: [HealthCheck]) -> [SetupRow.State] { setupRows(checks: cs).map(\.state) }
        XCTAssertEqual(states(allGood), [.done, .done, .done, .done])
        XCTAssertEqual(states(with(bad("accessibility"))), [.done, .done, .waiting, .pending])
        XCTAssertEqual(states(with(bad("can-insert"))), [.done, .done, .done, .waiting])
        XCTAssertEqual(states(with(bad("daemon"))), [.waiting, .pending, .pending, .pending])
        XCTAssertEqual(states(with(bad("tailnet"))), [.done, .waiting, .pending, .pending])
        // exactly one row is "waiting" at a time
        XCTAssertEqual(setupRows(checks: allGood.map { bad($0.id) }).filter { $0.state == .waiting }.count, 1)
    }

    func testRenderShowsMarksAndNeverAKey() {
        let text = renderSetup(rows: setupRows(checks: with(bad("accessibility"))), headline: "Next: do the thing")
        XCTAssertTrue(text.contains("✓ Greenfield is installed and running"))
        XCTAssertTrue(text.contains("… Accessibility approved"))
        XCTAssertTrue(text.contains("· Text really reaches apps"))
        XCTAssertTrue(text.hasPrefix("Next: do the thing"))
    }
}
