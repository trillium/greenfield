import XCTest
@testable import InserterCore

final class CompatTests: XCTestCase {
    func testSemverParsing() {
        XCTAssertEqual(Semver("1.2.3"), Semver(1, 2, 3))
        XCTAssertEqual(Semver("v0.2.0"), Semver(0, 2, 0))
        XCTAssertEqual(Semver("0.2.1+3.gabc1234.dirty"), Semver(0, 2, 1))
        for bad in ["", "1.2", "1.2.3.4", "a.b.c", "1.2.x", "-1.0.0", "1..3"] { XCTAssertNil(Semver(bad), bad) }
        XCTAssertTrue(Semver(0, 2, 0) < Semver(0, 10, 0))          // numeric, not lexical
        XCTAssertTrue(Semver(1, 0, 0) > Semver(0, 99, 99))
    }

    func testRuleWhileMajorIsZeroMinorMustMatch() {
        func j(_ peer: String, me: String = "0.2.0", min: String = "0.2.0") -> Compat.Verdict { Compat.judge(peer: peer, me: me, minPeer: min) }
        XCTAssertEqual(j("0.2.0"), .compatible)
        XCTAssertEqual(j("0.2.7"), .compatible)                       // patch is free
        XCTAssertEqual(j("0.1.9"), .peerTooOld)
        XCTAssertEqual(j("0.3.0"), .peerTooNew)
        XCTAssertEqual(j("1.0.0"), .peerTooNew)
        XCTAssertEqual(j("nonsense"), .peerUnreadable)
    }

    func testRuleFromOneZeroMajorMustMatch() {
        func j(_ peer: String, me: String = "1.4.0", min: String = "1.2.0") -> Compat.Verdict { Compat.judge(peer: peer, me: me, minPeer: min) }
        XCTAssertEqual(j("1.9.9"), .compatible)                       // minor and patch are free
        XCTAssertEqual(j("1.2.0"), .compatible)
        XCTAssertEqual(j("1.1.9"), .peerTooOld)                       // below the declared minimum although the major matches
        XCTAssertEqual(j("0.9.0"), .peerTooOld)
        XCTAssertEqual(j("2.0.0"), .peerTooNew)
    }

    func testMinimumPeerIsEnforcedEvenWhenTheLineMatches() {
        XCTAssertEqual(Compat.judge(peer: "0.2.0", me: "0.2.5", minPeer: "0.2.3"), .peerTooOld)
    }

    // MARK: apps the daemon has seen

    func sighting(_ v: String, _ ago: TimeInterval) -> ClientSighting { ClientSighting(version: v, at: Date().addingTimeInterval(-ago)) }

    func testNoAppYetIsANoteNotAFailure() {
        let c = AppCompat.evaluate([], me: "0.2.0", minClient: "0.2.0")
        XCTAssertTrue(c.ok); XCTAssertEqual(c.message, "no app has connected yet")
    }

    func testNewestAppDecides() {
        let ok = AppCompat.evaluate([sighting("0.1.0", 9000), sighting("0.2.1", 60)], me: "0.2.0", minClient: "0.2.0")
        XCTAssertTrue(ok.ok)                                          // an old client seen long ago does not count
        let old = AppCompat.evaluate([sighting("0.2.1", 9000), sighting("0.1.0", 60)], me: "0.2.0", minClient: "0.2.0")
        XCTAssertFalse(old.ok); XCTAssertTrue(old.fix.contains("Update the app"))
        let new = AppCompat.evaluate([sighting("0.3.0", 60)], me: "0.2.0", minClient: "0.2.0")
        XCTAssertFalse(new.ok); XCTAssertTrue(new.fix.contains("Update the Mac daemon"))
        XCTAssertFalse(AppCompat.evaluate([sighting("junk", 5)], me: "0.2.0", minClient: "0.2.0").ok)
    }

    func testClientLedgerKeepsTheLastFewDistinctVersions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clients-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var t = Date(timeIntervalSince1970: 1_000_000)
        let l = ClientLedger(paths: InserterPaths(directory: dir), now: { t })
        XCTAssertEqual(l.recent(), [])
        for v in ["0.2.0", "0.2.1", "0.2.0", "0.2.2", "0.2.3", "0.2.4", "0.2.5"] { t += 10; l.saw(version: v) }
        let r = l.recent()
        XCTAssertEqual(r.map(\.version), ["0.2.5", "0.2.4", "0.2.3", "0.2.2", "0.2.0"])   // 5 kept, newest first, repeats merged
        let mode = (try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("clients.json").path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(ClientLedger(paths: InserterPaths(directory: dir)).recent().count, 5)   // survives a restart
    }

    // MARK: the daemon's answer to the app header

    final class Clients: ClientRecord {
        var seen: [String] = []
        func saw(version: String) { seen.append(version) }
        func recent() -> [ClientSighting] { seen.reversed().map { ClientSighting(version: $0, at: Date()) } }
    }

    func handler(_ clients: ClientRecord) -> RequestHandler {
        let keys = StubKeys()
        return RequestHandler(keys: keys, probe: StubProbe(), inserter: SpyInserter(), name: { "m" }, clients: clients,
                              version: "0.2.0", minClientVersion: "0.2.0")
    }

    func get(_ h: RequestHandler, app: String?) -> HTTPResponse {
        var headers = ["x-dictation-key": "good"]
        if let app = app { headers["X-Greenfield-App"] = app }
        return h.handle(HTTPRequest(method: "GET", path: "/status", headers: headers))
    }

    func obj(_ r: HTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:] }

    func testCompatibleAppIsServedAndRemembered() {
        let c = Clients()
        let r = get(handler(c), app: "0.2.3")
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(c.seen, ["0.2.3"])
        XCTAssertEqual(obj(r)["min_client_version"] as? String, "0.2.0")
        XCTAssertEqual(obj(r)["version"] as? String, "0.2.0")
        XCTAssertEqual((obj(r)["app_compatible"] as? [String: Any])?["ok"] as? Bool, true)
    }

    func testIncompatibleAppGets426WithAPlainMessage() {
        for (v, code) in [("0.1.9", "app_too_old"), ("0.3.0", "app_too_new"), ("nope", "app_version_unreadable")] {
            let c = Clients()
            let r = get(handler(c), app: v)
            XCTAssertEqual(r.status, 426, v)
            XCTAssertEqual(obj(r)["error"] as? String, code)
            XCTAssertEqual(obj(r)["version"] as? String, "0.2.0")
            XCTAssertEqual(obj(r)["min_client_version"] as? String, "0.2.0")
            XCTAssertFalse((obj(r)["message"] as? String ?? "").isEmpty)
            XCTAssertEqual(c.seen, [v])                                // even a refused app is remembered, so health can say so
        }
    }

    func testNoHeaderIsAllowedAndNothingIsRecorded() {
        let c = Clients()
        XCTAssertEqual(get(handler(c), app: nil).status, 200)
        XCTAssertTrue(c.seen.isEmpty)
        XCTAssertEqual((obj(get(handler(c), app: nil))["app_compatible"] as? [String: Any])?["message"] as? String, "no app has connected yet")
    }

    func testAnUnauthorizedCallerIsNotRecorded() {
        let c = Clients()
        let h = handler(c)
        let r = h.handle(HTTPRequest(method: "GET", path: "/status", headers: ["X-Greenfield-App": "0.2.0", "x-dictation-key": "bad"]))
        XCTAssertNotEqual(r.status, 200)
        XCTAssertTrue(c.seen.isEmpty)
    }

    // MARK: update with rollback

    final class Fake {
        var running: BuildIdentity?
        var log: [String] = []
        var hasPrevious = true
        var newComesUp = true, previousComesUp = true
        func id(_ sha: String) -> BuildIdentity { BuildIdentity(version: "v", commit: "c", binarySha: sha, startedAt: nil) }
        func flow() -> UpdateFlow {
            var installedNew = false
            return UpdateFlow(
                installNew: { self.log.append("install"); installedNew = true },
                restorePrevious: { self.log.append("restore"); installedNew = false; return self.hasPrevious },
                restart: { self.log.append("restart")
                    self.running = installedNew ? (self.newComesUp ? self.id("new") : self.id("old"))
                                                : (self.previousComesUp ? self.id("old") : nil) },
                waitForRunning: { self.running },
                newSha: "new", previousSha: "old")
        }
    }

    func testUpdateSucceedsOnlyWhenTheRunningBuildIsTheNewFile() {
        let f = Fake()
        XCTAssertEqual(f.flow().run(), .updated(version: "v"))
        XCTAssertEqual(f.log, ["install", "restart"])
    }

    func testUpdateRollsBackWhenTheNewBuildStaysTheOldOne() {
        let f = Fake(); f.newComesUp = false
        if case .rolledBack = f.flow().run() {} else { XCTFail("expected rollback") }
        XCTAssertEqual(f.log, ["install", "restart", "restore", "restart"])
    }

    func testUpdateRollsBackWhenNothingAnswers() {
        let f = Fake()
        let flow = UpdateFlow(installNew: {}, restorePrevious: { true }, restart: { f.log.append("restart") },
                              waitForRunning: { f.log.count >= 2 ? f.id("old") : nil }, newSha: "new", previousSha: "old")
        if case .rolledBack(let why) = flow.run() { XCTAssertTrue(why.contains("did not answer")) } else { XCTFail() }
    }

    func testUpdateFailsLoudlyWithNothingToGoBackTo() {
        let f = Fake(); f.newComesUp = false; f.hasPrevious = false
        if case .failed(let why) = f.flow().run() { XCTAssertTrue(why.contains("no previous binary")) } else { XCTFail() }
        let g = Fake(); g.newComesUp = false; g.previousComesUp = false
        if case .failed = g.flow().run() {} else { XCTFail("a rollback that does not come up is a failure") }
    }

    func testInstallErrorsTriggerARollback() {
        struct Boom: Error {}
        var restored = false
        let flow = UpdateFlow(installNew: { throw Boom() }, restorePrevious: { restored = true; return true }, restart: {},
                              waitForRunning: { BuildIdentity(version: "v", commit: "c", binarySha: "old", startedAt: nil) },
                              newSha: "new", previousSha: "old")
        if case .rolledBack = flow.run() {} else { XCTFail() }
        XCTAssertTrue(restored)
    }
}
