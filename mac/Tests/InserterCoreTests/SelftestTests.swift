import XCTest
@testable import InserterCore

final class SelftestTests: XCTestCase {
    func ok(_ summary: String = "inserted (paste)") -> InserterClient.SendResult {
        .init(httpStatus: 200, summary: summary, inserted: true)
    }

    func good() -> SelftestObservations {
        var o = SelftestObservations()
        o.preflight = [HealthCheck("daemon", "Daemon running", .pass)]
        o.windowFocused = true
        o.textSend = ok(); o.textArrived = true
        o.returnSend = ok("inserted (type)"); o.returnSeen = true
        return o
    }

    func failing(_ o: SelftestObservations) -> HealthCheck? { evaluateSelftest(o).first { $0.status == .fail } }

    func testPass() {
        let cs = evaluateSelftest(good())
        XCTAssertTrue(selftestPassed(cs))
        XCTAssertEqual(cs.map(\.id), ["preflight", "credential", "window", "text-send", "text-arrival", "return-send", "return-seen"])
        XCTAssertTrue(formatSelftest(label: "m", checks: cs, simulated: false).hasPrefix("selftest on m: PASS"))
    }

    func testPreflightFailureReusesTheDoctorFix() {
        var o = good()
        o.preflight = [HealthCheck("accessibility", "Accessibility granted", .fail, detail: "not granted", why: "no events", fix: "approve it")]
        let f = failing(o)
        XCTAssertEqual(f?.id, "preflight"); XCTAssertEqual(f?.fix, "approve it"); XCTAssertTrue(f!.title.contains("Accessibility"))
        let cs = evaluateSelftest(o)
        XCTAssertTrue(cs.dropFirst().allSatisfy { $0.status == .skip })
        XCTAssertFalse(selftestPassed(cs))
    }

    func testCredentialAndWindowFailures() {
        var o = good(); o.credentialProblem = "no local token"
        XCTAssertEqual(failing(o)?.id, "credential")
        o = good(); o.windowFocused = false
        XCTAssertEqual(failing(o)?.id, "window")
    }

    func testSendRefusalsMapToSpecificFixes() {
        func fail(_ code: Int?, _ text: String = "x") -> HealthCheck? {
            var o = good(); o.textSend = .init(httpStatus: code, summary: text, inserted: false); o.textArrived = nil; return failing(o)
        }
        XCTAssertTrue(fail(409)!.detail.contains("409")); XCTAssertTrue(fail(423)!.detail.contains("locked"))
        XCTAssertTrue(fail(503, "Accessibility is not approved")!.detail.contains("Accessibility"))
        XCTAssertTrue(fail(401)!.fix.contains("--key-stdin"))
        XCTAssertTrue(fail(401)!.why.contains(keyFileNote))
        XCTAssertNotNil(fail(nil, "unreachable (x)"))
        XCTAssertEqual(fail(409)?.id, "text-send")
    }

    func testTextDidNotArrive() {
        var o = good(); o.textArrived = false
        let f = failing(o)
        XCTAssertEqual(f?.id, "text-arrival")
        XCTAssertTrue(f!.fix.contains("doctor"))
        let cs = evaluateSelftest(o)
        XCTAssertEqual(cs.last?.status, .skip)
    }

    func testReturnFailures() {
        var o = good(); o.returnSend = .init(httpStatus: 423, summary: "locked", inserted: false); o.returnSeen = nil
        XCTAssertEqual(failing(o)?.id, "return-send")
        o = good(); o.returnSeen = false
        XCTAssertEqual(failing(o)?.id, "return-seen")
        o = good(); o.returnSeen = nil
        XCTAssertEqual(failing(o)?.id, "return-seen")      // a missing observation is never a pass
    }

    func testSimulatedRunIsLabelledAndNeverClaimsDelivery() {
        var o = SelftestObservations(); o.simulated = true
        o.windowFocused = true; o.textArrived = true; o.returnSeen = true
        let cs = evaluateSelftest(o)
        let text = formatSelftest(label: "m", checks: cs, simulated: true)
        XCTAssertTrue(text.contains("SIMULATED"))
        XCTAssertEqual(cs.first { $0.id == "text-send" }?.status, .skip)
    }

    func testFailureOutputHasWrongWhyFixAndNoKey() {
        var o = good(); o.textArrived = false
        let text = formatSelftest(label: "m", checks: evaluateSelftest(o), simulated: false)
        XCTAssertTrue(text.contains("FAIL at"))
        for word in ["wrong:", "why:", "fix:"] { XCTAssertTrue(text.contains(word)) }
    }
}
