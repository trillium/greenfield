import XCTest
@testable import InserterCore

/// `GET /logs`: who may read, how much, what can never be in it. The redaction tests feed secrets and dictated text through the real
/// request handler and the real file logger, then read the answer back the way `make logs` does.
final class LogsTests: XCTestCase {
    var dir: URL!
    var file: URL!
    var keys = StubKeys()
    var probe = StubProbe()
    var inserter = SpyInserter()
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    let identity = HandlerTests.StubIdentity()

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("logs-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("inserter.log")
        keys = StubKeys(); probe = StubProbe(); inserter = SpyInserter()
        FileManager.default.createFile(atPath: file.path, contents: Data("2026-10-20T09:00:00Z starting\n".utf8))   // a daemon logs this first
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func makeHandler(limiter: LogRateLimiter = LogRateLimiter(limit: 100)) -> RequestHandler {
        RequestHandler(keys: keys, probe: probe, inserter: inserter, name: { "Test Mac" }, identity: identity,
                       logger: FileLogger(file: file, echoToStderr: false), logSource: FileLogSource(file: file), logLimiter: limiter,
                       now: { self.clock })
    }

    func get(_ h: RequestHandler, _ query: String = "", key: String? = nil, loopback: Bool = false, peer: String? = "100.64.0.9") -> HTTPResponse {
        var headers: [String: String] = [:]
        if let key = key { headers["x-dictation-key"] = key }
        return h.handle(HTTPRequest(method: "GET", path: "/logs", headers: headers, fromLoopback: loopback, peerAddress: peer, query: query))
    }

    func body(_ r: HTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:] }
    func lines(_ r: HTTPResponse) -> [String] { body(r)["lines"] as? [String] ?? [] }

    // MARK: who may read

    func testSameTailnetUserAndLoopbackMayRead() {
        let h = makeHandler()
        XCTAssertEqual(get(h).status, 200)
        identity.result = .unknown("tailscale is not running")
        XCTAssertEqual(get(h, loopback: true, peer: nil).status, 200)
    }

    func testAnotherTailnetUserIsRefused() {
        identity.result = .otherUser(login: "stranger@example")
        XCTAssertEqual(get(makeHandler()).status, 401)
    }

    func testFailsClosedWhenTailscaleCannotSayWhoIsCalling() {
        identity.result = .unknown("tailscale is not running")
        let r = get(makeHandler())
        XCTAssertEqual(r.status, 503)
        XCTAssertEqual(body(r)["error"] as? String, "identity_unavailable")
        XCTAssertNil(body(r)["lines"])
    }

    func testNoPeerAddressFailsClosed() {
        XCTAssertEqual(get(makeHandler(), peer: nil).status, 503)
    }

    func testTheOptionalKeyDoesNotOpenTheLogs() {
        identity.result = .otherUser(login: "stranger@example")
        let r = get(makeHandler(), key: "good")
        XCTAssertEqual(r.status, 403)
        XCTAssertEqual(body(r)["error"] as? String, "logs_need_same_user")
    }

    func testWrongMethodIsRefused() {
        let r = makeHandler().handle(HTTPRequest(method: "POST", path: "/logs", fromLoopback: true))
        XCTAssertEqual(r.status, 405)
    }

    func testAnOldAppVersionStillGetsTheLogs() {
        let h = makeHandler()
        let r = h.handle(HTTPRequest(method: "GET", path: "/logs", headers: ["x-greenfield-app": "0.0.1"], peerAddress: "100.64.0.9"))
        XCTAssertEqual(r.status, 200)
    }

    func testNoLogFileIsNotFound() {
        let h = RequestHandler(keys: keys, probe: probe, inserter: inserter, name: { "Test Mac" }, identity: identity,
                               logSource: FileLogSource(file: dir.appendingPathComponent("missing.log")))
        XCTAssertEqual(get(h).status, 404)
    }

    // MARK: limits

    func testSizeIsCappedAndNewestLinesWin() {
        let long = String(repeating: "x", count: 380)
        let text = (0..<2000).map { "2026-10-20T10:00:00Z entry \($0) \(long)" }.joined(separator: "\n") + "\n"
        try? text.write(to: file, atomically: true, encoding: .utf8)
        let r = get(makeHandler(), "tail=2000")
        XCTAssertEqual(r.status, 200)
        XCTAssertLessThanOrEqual(body(r)["bytes"] as? Int ?? .max, LogPage.maxBytes)
        XCTAssertLessThanOrEqual(r.body.count, LogPage.maxBytes + 4096)
        XCTAssertEqual(body(r)["truncated"] as? Bool, true)
        XCTAssertTrue(lines(r).last?.contains("entry 1999") ?? false)
    }

    func testTailAndSinceAreBounded() {
        let h = makeHandler()
        for bad in ["tail=0", "tail=2001", "tail=abc", "since=0m", "since=8d", "since=5x", "since=-3m", "other=1", "tail", "tail=5&since="] {
            XCTAssertEqual(get(h, bad).status, 400, bad)
        }
        XCTAssertEqual(get(h, "tail=2000&since=7d").status, 200)
    }

    func testTailAndSinceSelectLines() {
        let old = ISO8601DateFormatter().string(from: clock.addingTimeInterval(-7200))
        let recent = ISO8601DateFormatter().string(from: clock.addingTimeInterval(-60))
        try? "\(old) old one\n\(old) old two\n\(recent) recent one\n\(recent) recent two\n".write(to: file, atomically: true, encoding: .utf8)
        let h = makeHandler()
        XCTAssertEqual(lines(get(h, "since=30m")).filter { $0.hasSuffix("recent one") || $0.hasSuffix("recent two") }.count, 2)
        XCTAssertFalse(lines(get(h, "since=30m")).contains { $0.hasSuffix("old one") })
        XCTAssertEqual(lines(get(h, "tail=1")).count, 1)
    }

    func testRateLimitAnswers429WithRetryAfterAndRefusedCallersDoNotUseIt() {
        let limiter = LogRateLimiter(limit: 2, window: 60)
        let h = makeHandler(limiter: limiter)
        identity.result = .otherUser(login: "stranger@example")
        for _ in 0..<5 { XCTAssertEqual(get(h).status, 401) }            // refused callers cannot burn the allowance
        identity.result = .sameUser(login: "me@example")
        XCTAssertEqual(get(h).status, 200)
        XCTAssertEqual(get(h).status, 200)
        let third = get(h)
        XCTAssertEqual(third.status, 429)
        XCTAssertNotNil(third.headers["Retry-After"])
        clock = clock.addingTimeInterval(61)
        XCTAssertEqual(get(h).status, 200)
    }

    // MARK: nothing sensitive can be in the answer

    let dictated = "my bank password is hunter2-ZEBRA and the card is 4111-1111-1111-1111"
    // built at run time so no scanner mistakes a test canary for a real credential
    let secretKey = "canary-" + String(repeating: "7f3a9c", count: 7)
    let tokenValue = String(repeating: "q", count: 12)

    func testDictatedTextAndKeysNeverReachTheLog() {
        let h = makeHandler()
        keys.result = .ok
        // a real insert, a duplicate, refusals, a hostile id / source / path / method, a wrong key
        let hostileID = "id-with-\(dictated)"
        let bodyJSON: (String, String, String) -> Data = { id, text, source in
            try! JSONSerialization.data(withJSONObject: ["id": id, "text": text, "source": source])
        }
        _ = h.handle(HTTPRequest(method: "POST", path: "/text", body: bodyJSON("11111111-2222-3333-4444-555555555555", dictated, "phone"), fromLoopback: true))
        _ = h.handle(HTTPRequest(method: "POST", path: "/text", body: bodyJSON("11111111-2222-3333-4444-555555555555", dictated, "phone"), fromLoopback: true))
        _ = h.handle(HTTPRequest(method: "POST", path: "/text", body: bodyJSON(hostileID, dictated, dictated), fromLoopback: true))
        probe.screenLocked = true
        _ = h.handle(HTTPRequest(method: "POST", path: "/text", body: bodyJSON("locked-1", dictated, "phone"), fromLoopback: true))
        probe.screenLocked = false
        inserter.error = InsertError.failed("could not post Cmd+V")
        _ = h.handle(HTTPRequest(method: "POST", path: "/text", body: bodyJSON("failed-1", dictated, "phone"), fromLoopback: true))
        _ = h.handle(HTTPRequest(method: "GET", path: "/status/\(dictated)", fromLoopback: true))
        _ = h.handle(HTTPRequest(method: "GET", path: "/status", headers: ["x-dictation-key": secretKey, "authorization": "Bearer \(secretKey)"], peerAddress: "100.64.0.9"))
        identity.result = .otherUser(login: "stranger@example")
        _ = h.handle(HTTPRequest(method: "POST", path: "/text", headers: ["x-dictation-key": secretKey], body: bodyJSON("wrongkey", dictated, "phone"), peerAddress: "100.64.0.9"))
        _ = get(h, "tail=5&text=\(dictated)&key=\(secretKey)", key: secretKey)
        identity.result = .sameUser(login: "me@example")

        let raw = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        XCTAssertFalse(raw.isEmpty)
        for needle in ["hunter2", "ZEBRA", "4111", "bank password", secretKey, "7f3a9c7f3a9c"] {
            XCTAssertFalse(raw.contains(needle), "the log file contains \(needle)")
        }
        let served = String(data: get(h, "tail=2000").body, encoding: .utf8) ?? ""
        XCTAssertTrue(served.contains("sent chars="), "the served log should still say what happened")
        for needle in ["hunter2", "ZEBRA", "4111", "bank password", secretKey, "7f3a9c7f3a9c"] {
            XCTAssertFalse(served.contains(needle), "GET /logs contains \(needle)")
        }
    }

    func testCredentialsThatReachTheLogAnywayAreMaskedOnTheWayOut() {
        let leaks = [
            "2026-10-20T10:00:00Z header X-Dictation-Key: \(secretKey)",
            "2026-10-20T10:00:01Z got Authorization: Bearer abc.def.ghi",
            "2026-10-20T10:00:02Z url http://user:hunter2@host/path token=\(tokenValue)",
            "2026-10-20T10:00:03Z tailscale tskey-auth-kABCDEF123456-XYZ and sk-ant-api03-abcdefghijklmnop",
            "2026-10-20T10:00:04Z hash 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "2026-10-20T10:00:05Z jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc123",
            "2026-10-20T10:00:06Z json {\"password\":\"hunter2\",\"key\":\"abc\"}",
        ]
        try? (leaks.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let served = lines(get(makeHandler(), "tail=50")).joined(separator: "\n")
        for needle in [secretKey, "abc.def.ghi", "hunter2", tokenValue, "tskey-auth", "sk-ant", "0123456789abcdef0123", "eyJhbGci", "\"abc\""] {
            XCTAssertFalse(served.contains(needle), "served log still contains \(needle):\n\(served)")
        }
        XCTAssertTrue(served.contains("<redacted>"))
    }

    func testIdsStaySoTheyCanBeMatchedToTheOutbox() {
        try? "2026-10-20T10:00:00Z text id=6F1C2E0A-5B7D-4E8B-9C41-0A2D3B4C5D6E source=phone sent chars=12 method=paste delivery=confirmed\n"
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(lines(get(makeHandler())).first?.contains("6F1C2E0A-5B7D-4E8B-9C41-0A2D3B4C5D6E") ?? false)
    }

    func testLongLinesAreCutAndControlCharactersRemoved() {
        let r = LogRedactor()
        let out = r.redact("a\r\nb\tc" + String(repeating: "z ", count: 400))
        XCTAssertFalse(out.contains("\n") || out.contains("\r") || out.contains("\t"))
        XCTAssertLessThanOrEqual(out.count, LogRedactor.maxLineLength)
    }

    func testStatusSaysLogsAreAvailable() {
        try? "2026-10-20T10:00:00Z hello\n".write(to: file, atomically: true, encoding: .utf8)
        let r = makeHandler().handle(HTTPRequest(method: "GET", path: "/status", peerAddress: "100.64.0.9"))
        XCTAssertEqual(body(r)["logs_available"] as? Bool, true)
        let snapshot = DaemonSnapshot.parse(r.body)
        XCTAssertEqual(snapshot?.logsAvailable, true)
        let check = logsCheck(snapshot?.logsAvailable, remote: false, onThatMac: "On this Mac", bin: "greenfield-inserter")
        XCTAssertEqual(check.status, .pass)
        XCTAssertEqual(check.title, "Logs available")
        XCTAssertEqual(logsCheck(nil, remote: true, onThatMac: "On that Mac", bin: "b").status, .skip)
        XCTAssertEqual(logsCheck(false, remote: true, onThatMac: "On that Mac", bin: "b").status, .warn)
        XCTAssertTrue(isHealthy([logsCheck(false, remote: false, onThatMac: "x", bin: "b")]), "missing logs must not make a delivering Mac unhealthy")
    }

    // MARK: the CLI side

    func testClientReadsTheAnswerAndRedactsAgain() {
        let json = try! JSONSerialization.data(withJSONObject: ["ok": true, "lines": ["x token=abc123"], "truncated": true])
        XCTAssertEqual(InserterClient.interpretLogs(httpStatus: 200, body: json, alias: "m"), .lines(["x token=<redacted>"], truncated: true))
        for (code, word) in [(401, "same tailnet user"), (403, "tailnet user"), (429, "rate limiting"), (503, "verify who is calling")] {
            guard case .failed(let why) = InserterClient.interpretLogs(httpStatus: code, body: Data("{}".utf8), alias: "m") else { return XCTFail("\(code)") }
            XCTAssertTrue(why.contains(word), why)
        }
        guard case .failed(let old) = InserterClient.interpretLogs(httpStatus: 404, body: Data("{}".utf8), alias: "m") else { return XCTFail() }
        XCTAssertTrue(old.contains("predates"))
    }

    func testQueryParsing() {
        XCTAssertEqual(try? LogQuery.parse(query: "").get(), LogQuery())
        XCTAssertEqual(try? LogQuery.parse(query: "tail=50&since=30m").get(), LogQuery(tail: 50, since: 1800))
        XCTAssertEqual(LogQuery.parseDuration("90s"), 90)
        XCTAssertEqual(LogQuery.parseDuration("2h"), 7200)
        XCTAssertNil(LogQuery.parseDuration("m"))
    }

    func testRotatedFileIsUsedWhenTheCurrentOneIsShort() {
        try? "2026-10-20T09:00:00Z from the rotated file\n".write(to: file.appendingPathExtension("1"), atomically: true, encoding: .utf8)
        try? "2026-10-20T10:00:00Z from the current file\n".write(to: file, atomically: true, encoding: .utf8)
        let all = lines(get(makeHandler(), "tail=10"))
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.first?.contains("rotated") ?? false)
    }
}
