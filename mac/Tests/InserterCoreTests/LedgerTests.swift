import XCTest
@testable import InserterCore

final class LedgerTests: XCTestCase {
    var dir: URL!
    var t = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func ledger(start: Date? = nil) -> DeliveryLedger {
        DeliveryLedger(paths: InserterPaths(directory: dir), daemonStart: start ?? t, now: { self.t })
    }

    func testUnknownUntilEvidence() {
        XCTAssertEqual(ledger().canInsert().state, .unknown)
    }

    func testSuccessThenNewerFailureThenSuccess() {
        let l = ledger()
        t += 10; l.recordSuccess(source: "delivery")
        XCTAssertEqual(l.canInsert().state, .ok); XCTAssertEqual(l.canInsert().source, "delivery")
        t += 10; l.recordFailure(source: "delivery", detail: "no change")
        XCTAssertEqual(l.canInsert().state, .failed); XCTAssertEqual(l.canInsert().detail, "no change")
        t += 10; l.recordSuccess(source: "selftest")
        XCTAssertEqual(l.canInsert().state, .ok); XCTAssertEqual(l.canInsert().source, "selftest")
    }

    func testEvidenceFromBeforeTheDaemonStartedDoesNotCount() {
        let old = ledger()
        t += 10; old.recordSuccess(source: "selftest")
        t += 10
        let restarted = ledger(start: t)            // e.g. after a reinstall
        XCTAssertEqual(restarted.canInsert().state, .unknown)
    }

    func testEvidenceExpires() {
        let l = ledger()
        t += 10; l.recordSuccess(source: "delivery")
        t += DeliveryLedger.maxAge + 1
        XCTAssertEqual(l.canInsert().state, .unknown)
    }

    func testFileIsPrivateAndSharedBetweenInstances() throws {
        let a = ledger(); t += 1; a.recordSuccess(source: "selftest")
        XCTAssertEqual(ledger(start: Date(timeIntervalSince1970: 0)).canInsert().state, .ok)   // another process reading the file
        let mode = (try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("delivery.json").path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
    }

    func testJSONRoundTrip() {
        let c = CanInsert(state: .ok, at: Date(timeIntervalSince1970: 1_000_000), source: "selftest", detail: "d")
        XCTAssertEqual(CanInsert.parse(c.json)?.state, .ok)
        XCTAssertEqual(CanInsert.parse(c.json)?.source, "selftest")
        XCTAssertNil(CanInsert.parse(["state": "nonsense"]))
    }

    // MARK: what a selftest proves

    final class Spy: DeliveryRecord {
        var successes = 0; var failures: [String] = []
        func recordSuccess(source: String) { successes += 1 }
        func recordFailure(source: String, detail: String) { failures.append(detail) }
        func canInsert() -> CanInsert { CanInsert(state: .unknown, at: nil, source: nil, detail: "") }
    }

    func testSelftestEvidence() {
        func good() -> SelftestObservations {
            var o = SelftestObservations()
            o.windowFocused = true; o.textSend = .init(httpStatus: 200, summary: "x", inserted: true); o.textArrived = true
            o.returnSend = .init(httpStatus: 200, summary: "x", inserted: true); o.returnSeen = true
            return o
        }
        var spy = Spy()
        recordSelftestEvidence(evaluateSelftest(good()), ledger: spy)
        XCTAssertEqual(spy.successes, 1)

        spy = Spy(); var o = good(); o.textArrived = false
        recordSelftestEvidence(evaluateSelftest(o), ledger: spy)
        XCTAssertEqual(spy.failures.count, 1); XCTAssertEqual(spy.successes, 0)

        spy = Spy(); o = good(); o.windowFocused = false          // proves nothing about delivery
        recordSelftestEvidence(evaluateSelftest(o), ledger: spy)
        XCTAssertEqual(spy.failures.count + spy.successes, 0)

        spy = Spy(); o = good(); o.preflight = [HealthCheck("accessibility", "Accessibility granted", .fail, detail: "no")]
        recordSelftestEvidence(evaluateSelftest(o), ledger: spy)
        XCTAssertEqual(spy.failures.count, 1)

        spy = Spy(); o = good(); o.preflight = [HealthCheck("unlocked", "Screen not locked", .fail, detail: "locked")]
        recordSelftestEvidence(evaluateSelftest(o), ledger: spy)      // a locked screen is not a delivery failure
        XCTAssertEqual(spy.failures.count, 0)
    }
}
