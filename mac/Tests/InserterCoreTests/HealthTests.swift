import XCTest
@testable import InserterCore

final class HealthTests: XCTestCase {
    func snap(listen: [String] = ["100.84.99.99:47821", "127.0.0.1:47821"], accessibility: Bool = true, locked: Bool = false,
              secure: Bool = false, key: Bool = true, version: String = "0.1.0") -> DaemonSnapshot {
        DaemonSnapshot(name: "m", version: version, listen: listen, accessibility: accessibility, screenLocked: locked,
                       secureInput: secure, keyConfigured: key, executable: nil, pid: 42)
    }
    let local = HealthSubject.local(port: 47821)
    let remote = HealthSubject.remote(alias: "book", host: "book.ts.net", port: 47821)

    func checks(_ o: SnapshotOutcome, _ s: HealthSubject? = nil) -> [HealthCheck] {
        snapshotChecks(o, subject: s ?? local, localVersion: "0.1.0")
    }
    func status(_ cs: [HealthCheck], _ id: String) -> HealthCheck.Status? { cs.first { $0.id == id }?.status }

    func testAllGoodIsHealthy() {
        let cs = checks(.ok(snap()))
        XCTAssertTrue(isHealthy(cs))
        XCTAssertEqual(cs.map(\.id), ["daemon", "listening", "key", "accessibility", "unlocked", "secure-input", "version"])
        XCTAssertTrue(formatHealth(label: "mini0", checks: cs).hasPrefix("mini0: HEALTHY"))
    }

    func testEachProblemFailsOnlyItsCheck() {
        XCTAssertEqual(status(checks(.ok(snap(accessibility: false))), "accessibility"), .fail)
        XCTAssertEqual(status(checks(.ok(snap(locked: true))), "unlocked"), .fail)
        XCTAssertEqual(status(checks(.ok(snap(secure: true))), "secure-input"), .fail)
        XCTAssertEqual(status(checks(.ok(snap(key: false))), "key"), .fail)
        XCTAssertEqual(status(checks(.ok(snap(listen: ["127.0.0.1:47821"]))), "listening"), .fail)
        XCTAssertEqual(status(checks(.ok(snap(listen: ["100.84.99.99:47821"]))), "listening"), .fail)
        XCTAssertEqual(status(checks(.ok(snap(listen: ["0.0.0.0:47821", "127.0.0.1:47821", "100.84.99.99:47821"]))), "listening"), .fail)
        for bad in [snap(accessibility: false), snap(locked: true), snap(secure: true), snap(key: false)] {
            XCTAssertFalse(isHealthy(checks(.ok(bad))))
        }
        XCTAssertEqual(status(checks(.ok(snap(accessibility: false))), "daemon"), .pass)
    }

    func testUnreachableSkipsTheRest() {
        let cs = checks(.unreachable("connection refused"))
        XCTAssertEqual(status(cs, "daemon"), .fail)
        XCTAssertTrue(cs.dropFirst().allSatisfy { $0.status == .skip })
        XCTAssertFalse(isHealthy(cs))
    }

    func testAuthProblemsOnRemote() {
        XCTAssertEqual(status(checks(.unauthorized, remote), "key"), .fail)
        XCTAssertTrue(checks(.unauthorized, remote).first { $0.id == "key" }!.fix.contains("macs add book"))
        XCTAssertEqual(status(checks(.keyNotSet, remote), "key"), .fail)
        XCTAssertEqual(status(checks(.unauthorized, remote), "daemon"), .pass)
    }

    func testOlderDaemonIsExplained() {
        let c = checks(.unexpected(404)).first { $0.id == "key" }!
        XCTAssertTrue(c.detail.contains("older version"))
        XCTAssertTrue(c.fix.contains("make -C mac install"))
    }

    func testVersionMismatchWarnsOnlyForRemote() {
        XCTAssertEqual(status(checks(.ok(snap(version: "0.0.9")), remote), "version"), .warn)
        XCTAssertEqual(status(checks(.ok(snap(version: "0.0.9"))), "version"), .pass)
    }

    func testEveryFailureHasWhatWhyAndFix() {
        let outcomes: [(SnapshotOutcome, HealthSubject)] = [
            (.ok(snap(accessibility: false, locked: true, secure: true, key: false, version: "9")), remote),
            (.ok(snap(listen: ["0.0.0.0:1"])), local), (.unreachable("x"), local), (.unreachable("x"), remote),
            (.unauthorized, remote), (.keyNotSet, remote), (.unexpected(500), local), (.forbidden, local),
        ]
        for (o, s) in outcomes {
            for c in snapshotChecks(o, subject: s, localVersion: "0.1.0") where c.status == .fail || c.status == .warn {
                XCTAssertFalse(c.detail.isEmpty, c.id); XCTAssertFalse(c.why.isEmpty, c.id); XCTAssertFalse(c.fix.isEmpty, c.id)
            }
        }
    }

    func testDoctorOutputExplains() {
        let out = formatDoctor(label: "book", checks: checks(.ok(snap(accessibility: false)), remote))
        XCTAssertTrue(out.contains("1 problem found"))
        XCTAssertTrue(out.contains("wrong:")); XCTAssertTrue(out.contains("why:")); XCTAssertTrue(out.contains("fix:"))
        XCTAssertTrue(out.contains("Privacy & Security > Accessibility"))
        XCTAssertTrue(formatDoctor(label: "x", checks: checks(.ok(snap()))).contains("all 7 checks passed"))
    }

    func testParseSnapshot() {
        let body = #"{"version":"0.1.0","name":"m","listen":["127.0.0.1:1"],"accessibility":true,"screen_locked":false,"secure_input":true,"key_configured":false,"pid":7,"executable":"/x"}"#
        let s = DaemonSnapshot.parse(Data(body.utf8))
        XCTAssertEqual(s?.secureInput, true); XCTAssertEqual(s?.keyConfigured, false)
        XCTAssertEqual(s?.pid, 7); XCTAssertEqual(s?.executable, "/x")
        XCTAssertEqual(DaemonSnapshot.parse(Data(#"{"version":"1","accessibility":true}"#.utf8))?.keyConfigured, true)  // /status implies a key
        XCTAssertNil(DaemonSnapshot.parse(Data("nope".utf8)))
    }

    // MARK: host checks

    func facts(_ edit: (inout HostFacts) -> Void = { _ in }) -> HostFacts {
        var f = HostFacts(tailnetIPv4: "100.84.99.99", plistPath: "/h/Library/LaunchAgents/x.plist", plistText: "<plist/>",
                          launchdLoaded: true, launchdPid: 123, installedBinary: "/h/.local/share/greenfield-inserter/greenfield-inserter",
                          binaryExecutable: true, configDir: "/h/.config/greenfield-inserter", dirMode: 0o700,
                          keyFile: "/h/.config/greenfield-inserter/key", keyFileExists: true, keyFileMode: 0o600,
                          keyFormatValid: true)
        edit(&f)
        return f
    }

    func testHostAllGood() {
        let cs = hostChecks(facts(), daemonExecutable: facts().installedBinary)
        XCTAssertTrue(isHealthy(cs), "\(cs.filter { $0.status != .pass })")
    }

    func testHostProblems() {
        func failing(_ edit: (inout HostFacts) -> Void, exe: String? = nil) -> [String] {
            hostChecks(facts(edit), daemonExecutable: exe).filter { $0.status == .fail }.map(\.id)
        }
        XCTAssertEqual(failing { $0.tailnetIPv4 = nil }, ["tailnet"])
        XCTAssertEqual(failing { $0.binaryExecutable = false }, ["binary"])
        XCTAssertEqual(failing { $0.plistText = nil }, ["plist"])
        XCTAssertEqual(failing { $0.launchdLoaded = false; $0.launchdPid = nil }, ["launchd"])
        XCTAssertEqual(failing { $0.launchdPid = nil }, ["launchd"])
        XCTAssertEqual(failing { $0.keyFileExists = false }, ["keyfile"])
        XCTAssertEqual(failing { $0.keyFormatValid = false }, ["keyfile"])
        XCTAssertEqual(failing { $0.keyFileMode = 0o644 }, ["keyfile"])
        XCTAssertEqual(failing { $0.dirMode = 0o755 }, ["keyfile"])
        XCTAssertEqual(failing({ _ in }, exe: "/tmp/other/greenfield-inserter"), ["path"])
    }

    func testHostFailuresExplainThemselves() {
        let bad = facts { $0.tailnetIPv4 = nil; $0.binaryExecutable = false; $0.plistText = nil; $0.launchdLoaded = false
            $0.launchdPid = nil; $0.keyFileExists = false }
        for c in hostChecks(bad, daemonExecutable: "/other") where c.status == .fail {
            XCTAssertFalse(c.why.isEmpty, c.id); XCTAssertFalse(c.fix.isEmpty, c.id)
        }
    }

    func testPeerChecks() {
        let mac = KnownMac(alias: "book", host: "book.ts.net", key: "SECRET")
        let good = MacReport(mac: mac, state: .ready, name: "b", version: "0.1.0", listen: ["127.0.0.1:1"])
        let bad = MacReport(mac: mac, state: .unreachable("timeout"), name: nil, version: nil)
        XCTAssertEqual(peerChecks([good], localVersion: "0.1.0").first?.status, .pass)
        XCTAssertEqual(peerChecks([bad], localVersion: "0.1.0").first?.status, .fail)
    }

    func testNothingEverPrintsAKey() {
        let secret = "SECRET-KEY-VALUE"
        let mac = KnownMac(alias: "book", host: "book.ts.net", key: secret)
        let reports = [MacReport(mac: mac, state: .unauthorized, name: nil, version: nil)]
        var all = peerChecks(reports, localVersion: "0.1.0")
        for o: SnapshotOutcome in [.unauthorized, .keyNotSet, .unreachable("x"), .ok(snap(key: false))] {
            all += snapshotChecks(o, subject: .remote(alias: "book", host: "book.ts.net", port: 1), localVersion: "0.1.0")
        }
        all += hostChecks(facts { $0.keyFileExists = false }, daemonExecutable: nil)
        let text = formatDoctor(label: "x", checks: all) + formatHealth(label: "x", checks: all)
        XCTAssertFalse(text.contains(secret))
    }
}
