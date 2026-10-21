import XCTest
@testable import InserterCore

/// The daemon's half of the contract with the phone app (docs in mac/docs/contract.md):
/// - `Tests/Fixtures/status-*.json` are what the daemon answers; the phone's tests parse every file there.
///   They are produced by the real handler, and this test fails if the handler's answer drifts from them.
///   Re-record deliberately with `RECORD_FIXTURES=1 swift test --filter ContractTests`.
/// - `App/Tests/Fixtures/request-*.json` are what the phone sends; the daemon must accept exactly that shape.
final class ContractTests: XCTestCase {
    static let fixtures: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let appFixtures: URL = {
        if let o = ProcessInfo.processInfo.environment["APP_FIXTURES"] { return URL(fileURLWithPath: o) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Tests/Fixtures")
    }()

    final class Identity: TailnetIdentity {
        func identify(_ address: String) -> PeerIdentity { .sameUser(login: "me@example") }
        func selfLogin() -> String? { "me@example" }
    }
    final class Evidence: DeliveryRecord {
        var state: CanInsert.State
        init(_ s: CanInsert.State) { state = s }
        func recordSuccess(source: String) {}
        func recordFailure(source: String, detail: String) {}
        func canInsert() -> CanInsert {
            let at = Date(timeIntervalSince1970: 1_800_000_000)
            return state == .ok ? CanInsert(state: .ok, at: at, source: "selftest", detail: "text was read back from the focused field")
                                : CanInsert(state: .unknown, at: nil, source: nil, detail: "no delivery has been confirmed since this daemon started")
        }
    }
    final class Seen: ClientRecord {
        var versions: [String]
        init(_ v: [String]) { versions = v }
        func saw(version: String) { versions.insert(version, at: 0) }
        func recent() -> [ClientSighting] { versions.enumerated().map { ClientSighting(version: $0.element, at: Date(timeIntervalSince1970: 1_800_000_000 - Double($0.offset) * 60)) } }
    }

    struct Logs: LogSource {
        var available: Bool { true }
        func read(_ query: LogQuery, now: Date) -> [String] { [] }
    }

    func makeHandler(accessibility: Bool = true, evidence: CanInsert.State = .ok, clients: [String] = []) -> RequestHandler {
        let probe = StubProbe(); probe.accessibilityTrusted = accessibility
        return RequestHandler(keys: StubKeys(), probe: probe, inserter: SpyInserter(), name: { "Example Mac" },
                              listening: { ["100.64.0.10:47821", "127.0.0.1:47821"] }, identity: Identity(),
                              record: Evidence(evidence), clients: Seen(clients), version: "0.2.0", minClientVersion: "0.2.0", logSource: Logs())
    }

    /// Volatile values replaced so a recorded file is stable.
    func normalized(_ data: Data) -> [String: Any] {
        var o = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if o["uptime_s"] != nil { o["uptime_s"] = 3600 }
        if var b = o["build"] as? [String: Any] { b["commit"] = "abc1234"; b["binary_sha"] = "0123456789abcdef"; b["started_at"] = "2027-01-15T08:00:00Z"; b["version"] = "0.2.0"; o["build"] = b }
        if var c = o["clients"] as? [[String: Any]] { c = c.enumerated().map { var e = $0.element; e["at"] = "2027-01-15T08:0\(9 - $0.offset):00Z"; return e }; o["clients"] = c }
        if let m = (o["app_compatible"] as? [String: Any])?["message"] as? String {
            var a = o["app_compatible"] as! [String: Any]
            a["message"] = m.replacingOccurrences(of: #"\d+ (seconds|minutes|hours|days) ago"#, with: "2 minutes ago", options: .regularExpression)
            o["app_compatible"] = a
        }
        if var d = o["delivery"] as? [String: Any], let f = d["fix"] as? String {
            let f2 = f.replacingOccurrences(of: NSHomeDirectory(), with: "/Users/example")
            d["fix"] = f2; d["at"] = d["at"] == nil ? nil : "2027-01-15T08:00:00Z"; o["delivery"] = d
            o["delivery_fix"] = f2
        }
        if let at = (o["evidence"] as? [String: Any])?["at"] { _ = at; var e = o["evidence"] as! [String: Any]; e["at"] = "2027-01-15T08:00:00Z"; o["evidence"] = e
            var d = o["delivery"] as? [String: Any] ?? [:]; if d["at"] != nil { d["at"] = "2027-01-15T08:00:00Z"; o["delivery"] = d } }
        return o
    }

    func status(_ h: RequestHandler, app: String? = "0.2.0") -> HTTPResponse {
        var headers: [String: String] = [:]
        if let app = app { headers["X-Greenfield-App"] = app }
        return h.handle(HTTPRequest(method: "GET", path: "/status", headers: headers, peerAddress: "100.64.0.20"))
    }

    var scenarios: [(String, () -> HTTPResponse)] {
        [
            ("status-ready", { self.status(self.makeHandler(clients: ["0.2.0"])) }),
            ("status-no-app-seen-yet", { self.status(self.makeHandler(evidence: .unknown), app: nil) }),
            ("status-needs-accessibility", { self.status(self.makeHandler(accessibility: false, evidence: .unknown)) }),
            ("status-app-too-old-seen", { self.status(self.makeHandler(clients: ["0.1.0"]), app: nil) }),
            ("status-426-app-too-old", { self.status(self.makeHandler(), app: "0.1.9") }),
            ("status-426-app-too-new", { self.status(self.makeHandler(), app: "0.3.0") }),
        ]
    }

    func testRecordedStatusSamplesMatchWhatTheDaemonAnswers() throws {
        let record = ProcessInfo.processInfo.environment["RECORD_FIXTURES"] != nil
        if record { try FileManager.default.createDirectory(at: Self.fixtures, withIntermediateDirectories: true) }
        for (name, make) in scenarios {
            let response = make()
            let actual = normalized(response.body)
            let url = Self.fixtures.appendingPathComponent("\(name).json")
            if record {
                var wrapped: [String: Any] = ["_comment": "Recorded from the real handler by ContractTests (RECORD_FIXTURES=1). HTTP status \(response.status). The phone's tests parse this file.",
                                              "_http_status": response.status]
                for (k, v) in actual { wrapped[k] = v }
                let data = try JSONSerialization.data(withJSONObject: wrapped, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: url)
                continue
            }
            let recorded = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            XCTAssertEqual(recorded["_http_status"] as? Int, response.status, name)
            var expected = recorded; expected["_comment"] = nil; expected["_http_status"] = nil
            XCTAssertEqual(NSDictionary(dictionary: expected), NSDictionary(dictionary: actual), "\(name): the daemon's answer drifted from the recorded sample; re-record deliberately")
        }
    }

    func testRecordedPeersSampleMatches() throws {
        final class Two: ComputerDiscovery {
            func computers() -> [DiscoveredComputer] {
                [DiscoveredComputer(name: "Example Mac", address: "example.tail1234.ts.net", version: "0.2.0", isSelf: true),
                 DiscoveredComputer(name: "Studio Mac", address: "studio.tail1234.ts.net", version: "0.2.1", isSelf: false)]
            }
        }
        let h = RequestHandler(keys: StubKeys(), probe: StubProbe(), inserter: SpyInserter(), name: { "Example Mac" },
                               identity: Identity(), discovery: Two(), version: "0.2.0", minClientVersion: "0.2.0")
        let r = h.handle(HTTPRequest(method: "GET", path: "/peers", peerAddress: "100.64.0.20"))
        XCTAssertEqual(r.status, 200)
        let actual = (try JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:]
        let url = Self.fixtures.appendingPathComponent("peers-two-macs.json")
        if ProcessInfo.processInfo.environment["RECORD_FIXTURES"] != nil {
            var wrapped: [String: Any] = ["_comment": "GET /peers from the real handler (ContractTests, RECORD_FIXTURES=1). The phone reads peers[].name, address, version.", "_http_status": 200]
            for (k, v) in actual { wrapped[k] = v }
            try JSONSerialization.data(withJSONObject: wrapped, options: [.prettyPrinted, .sortedKeys]).write(to: url)
            return
        }
        var recorded = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        recorded["_comment"] = nil; recorded["_http_status"] = nil
        XCTAssertEqual(NSDictionary(dictionary: recorded), NSDictionary(dictionary: actual))
    }

    func testEverySampleCarriesTheVersionsThePhoneRequires() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.fixtures, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("status-") }
        XCTAssertGreaterThanOrEqual(files.count, 5)
        for f in files {
            let o = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as! [String: Any]
            XCTAssertNotNil(Semver(o["version"] as? String ?? ""), f.lastPathComponent)
            XCTAssertNotNil(Semver(o["min_client_version"] as? String ?? ""), f.lastPathComponent)
        }
    }

    func testTheDaemonAcceptsExactlyWhatThePhoneRecordsItSends() throws {
        let dir = Self.appFixtures
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix("request-") }
        try XCTSkipIf(files.isEmpty, "no App/Tests/Fixtures/request-*.json here (they live on the phone branch); set APP_FIXTURES to run this")
        let h = makeHandler()
        for f in files {
            let o = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as! [String: Any]
            var headers = (o["headers"] as? [String: String] ?? [:]).filter { !$0.key.hasPrefix("_") }
            // placeholders in angle brackets stand for values that vary
            headers["X-Greenfield-App"] = "0.2.4"
            headers["X-Dictation-Key"] = nil
            var body = Data()
            if var b = o["body"] as? [String: Any] {
                for (k, v) in b { if let s = v as? String, s.hasPrefix("<") { b[k] = k == "id" ? UUID().uuidString : "hello" } }
                body = try JSONSerialization.data(withJSONObject: b)
            }
            let r = h.handle(HTTPRequest(method: o["method"] as! String, path: o["path"] as! String, headers: headers, body: body, peerAddress: "100.64.0.20"))
            XCTAssertEqual(r.status, 200, "\(f.lastPathComponent): \(String(data: r.body, encoding: .utf8) ?? "")")
        }
    }
}
