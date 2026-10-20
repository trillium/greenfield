import XCTest
@testable import InserterCore

final class StubKeys: KeyVerifier {
    var result: KeyCheck = .ok
    var lastPresented: String?
    func verify(_ presented: String?) -> KeyCheck { lastPresented = presented; return presented == "good" ? result : (result == .notConfigured ? .notConfigured : .mismatch) }
}

final class StubProbe: SystemProbe {
    var secureInputEnabled = false
    var screenLocked = false
    var accessibilityTrusted = true
}

final class SpyInserter: TextInserter {
    var inserted: [(String, InsertMethod?)] = []
    var error: Error?
    func insert(_ text: String, method: InsertMethod?) throws -> InsertMethod {
        if let error = error { throw error }
        inserted.append((text, method))
        return method ?? .paste
    }
}

final class SpyLogger: RequestLogger {
    var lines: [String] = []
    func log(_ message: String) { lines.append(message) }
}

final class HandlerTests: XCTestCase {
    var keys = StubKeys()
    var probe = StubProbe()
    var inserter = SpyInserter()
    var logger = SpyLogger()
    var handler: RequestHandler!

    override func setUp() {
        keys = StubKeys(); probe = StubProbe(); inserter = SpyInserter(); logger = SpyLogger()
        handler = RequestHandler(keys: keys, probe: probe, inserter: inserter, name: { "Test Mac" },
                                 listening: { ["100.84.99.99:47821", "127.0.0.1:47821"] }, logger: logger)
    }

    func post(_ json: String, key: String? = "good") -> HTTPResponse {
        var headers: [String: String] = [:]
        if let key = key { headers["X-Dictation-Key"] = key }
        return handler.handle(HTTPRequest(method: "POST", path: "/text", headers: headers, body: Data(json.utf8)))
    }

    func object(_ r: HTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:]
    }

    // MARK: status

    func testStatusReportsNameVersionAndState() {
        let r = handler.handle(HTTPRequest(method: "GET", path: "/status", headers: ["x-dictation-key": "good"]))
        XCTAssertEqual(r.status, 200)
        let o = object(r)
        XCTAssertEqual(o["name"] as? String, "Test Mac")
        XCTAssertEqual(o["version"] as? String, RequestHandler.version)
        XCTAssertEqual(o["service"] as? String, "greenfield-inserter")
        XCTAssertEqual(o["secure_input"] as? Bool, false)
        XCTAssertEqual(o["screen_locked"] as? Bool, false)
        XCTAssertEqual(o["accessibility"] as? Bool, true)
        XCTAssertEqual(o["inserted_count"] as? Int, 0)
    }

    func testStatusReflectsProbe() {
        probe.secureInputEnabled = true; probe.screenLocked = true; probe.accessibilityTrusted = false
        let o = object(handler.handle(HTTPRequest(method: "GET", path: "/status", headers: ["x-dictation-key": "good"])))
        XCTAssertEqual(o["secure_input"] as? Bool, true)
        XCTAssertEqual(o["screen_locked"] as? Bool, true)
        XCTAssertEqual(o["accessibility"] as? Bool, false)
    }

    func testAnyHostHeaderIsAccepted() {
        for host in ["mini0", "mini0.hippo-tilapia.ts.net", "100.84.99.99:47821", "localhost", "anything.example"] {
            let r = handler.handle(HTTPRequest(method: "GET", path: "/status",
                                               headers: ["Host": host, "X-Dictation-Key": "good"]))
            XCTAssertEqual(r.status, 200, host)
        }
    }

    func testStatusReportsListeningAddresses() {
        let o = object(handler.handle(HTTPRequest(method: "GET", path: "/status", headers: ["x-dictation-key": "good"])))
        XCTAssertEqual(o["listen"] as? [String], ["100.84.99.99:47821", "127.0.0.1:47821"])
    }

    // MARK: auth

    func testMissingAndWrongKeyAre401() {
        XCTAssertEqual(post(#"{"id":"a","text":"hi"}"#, key: nil).status, 401)
        XCTAssertEqual(post(#"{"id":"a","text":"hi"}"#, key: "bad").status, 401)
        XCTAssertEqual(handler.handle(HTTPRequest(method: "GET", path: "/status")).status, 401)
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    func testUnconfiguredKeyIs503() {
        keys.result = .notConfigured
        XCTAssertEqual(post(#"{"id":"a","text":"hi"}"#).status, 503)
        XCTAssertEqual(object(post(#"{"id":"a","text":"hi"}"#))["error"] as? String, "key_not_configured")
    }

    func testAuthIsCheckedBeforeMethodAndBody() {
        let r = handler.handle(HTTPRequest(method: "DELETE", path: "/text"))
        XCTAssertEqual(r.status, 401)
    }

    func testUnknownPathIs404AndWrongMethodIs405() {
        XCTAssertEqual(handler.handle(HTTPRequest(method: "GET", path: "/nope")).status, 404)
        let r = handler.handle(HTTPRequest(method: "GET", path: "/text", headers: ["x-dictation-key": "good"]))
        XCTAssertEqual(r.status, 405)
        XCTAssertEqual(r.headers["Allow"], "POST")
    }

    // MARK: validation

    func testBadBodiesAre400() {
        XCTAssertEqual(post("not json").status, 400)
        XCTAssertEqual(post(#"{"text":"hi"}"#).status, 400)               // no id
        XCTAssertEqual(post(#"{"id":"a"}"#).status, 400)                  // no text
        XCTAssertEqual(post(#"{"id":"a","text":""}"#).status, 400)        // empty text
        XCTAssertEqual(post(#"{"id":"a","text":"x","method":"fax"}"#).status, 400)
        XCTAssertEqual(post("{\"id\":\"\(String(repeating: "i", count: 129))\",\"text\":\"x\"}").status, 400)
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    func testRequestIdMayComeFromHeader() {
        let r = handler.handle(HTTPRequest(method: "POST", path: "/text",
                                           headers: ["x-dictation-key": "good", "X-Request-Id": "hdr-1"],
                                           body: Data(#"{"text":"hi"}"#.utf8)))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(inserter.inserted.count, 1)
    }

    func testOversizeTextIs413() {
        let big = String(repeating: "a", count: RequestHandler.maxTextBytes + 1)
        XCTAssertEqual(post("{\"id\":\"a\",\"text\":\"\(big)\"}").status, 413)
    }

    // MARK: insertion and error codes

    func testInsertsAndReportsMetadata() {
        let r = post(#"{"id":"a","text":"héllo 👋","source":"phone"}"#)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(inserter.inserted.first?.0, "héllo 👋")
        let o = object(r)
        XCTAssertEqual(o["ok"] as? Bool, true)
        XCTAssertEqual(o["chars"] as? Int, 7)
        XCTAssertEqual(o["method"] as? String, "paste")
    }

    func testExplicitMethodIsPassedThrough() {
        _ = post(#"{"id":"a","text":"x","method":"type"}"#)
        XCTAssertEqual(inserter.inserted.first?.1, .type)
    }

    func testSecureInputIs409() {
        probe.secureInputEnabled = true
        let r = post(#"{"id":"a","text":"secret"}"#)
        XCTAssertEqual(r.status, 409)
        XCTAssertEqual(object(r)["error"] as? String, "secure_input")
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    func testLockedScreenIs423() {
        probe.screenLocked = true
        XCTAssertEqual(post(#"{"id":"a","text":"x"}"#).status, 423)
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    func testLockedWinsOverSecureInput() {
        probe.screenLocked = true; probe.secureInputEnabled = true
        XCTAssertEqual(post(#"{"id":"a","text":"x"}"#).status, 423)
    }

    func testNoAccessibilityIs503() {
        probe.accessibilityTrusted = false
        let r = post(#"{"id":"a","text":"x"}"#)
        XCTAssertEqual(r.status, 503)
        XCTAssertEqual(object(r)["error"] as? String, "accessibility_not_granted")
    }

    func testInserterFailureIs500() {
        inserter.error = InsertError.failed("boom")
        XCTAssertEqual(post(#"{"id":"a","text":"x"}"#).status, 500)
    }

    // MARK: de-duplication

    func testRetriedIdInsertsOnce() {
        XCTAssertEqual(post(#"{"id":"same","text":"once"}"#).status, 200)
        let again = post(#"{"id":"same","text":"once"}"#)
        XCTAssertEqual(again.status, 200)
        XCTAssertEqual(object(again)["duplicate"] as? Bool, true)
        XCTAssertEqual(inserter.inserted.count, 1)
    }

    func testDuplicateIsAnsweredEvenIfSecureInputStartedMeanwhile() {
        _ = post(#"{"id":"same","text":"once"}"#)
        probe.secureInputEnabled = true
        XCTAssertEqual(post(#"{"id":"same","text":"once"}"#).status, 200)
    }

    func testFailedRequestCanBeRetriedWithSameId() {
        probe.screenLocked = true
        XCTAssertEqual(post(#"{"id":"r","text":"x"}"#).status, 423)
        probe.screenLocked = false
        XCTAssertEqual(post(#"{"id":"r","text":"x"}"#).status, 200)
        XCTAssertEqual(inserter.inserted.count, 1)
    }

    func testDifferentIdsBothInsert() {
        _ = post(#"{"id":"1","text":"a"}"#); _ = post(#"{"id":"2","text":"a"}"#)
        XCTAssertEqual(inserter.inserted.count, 2)
    }

    func testConcurrentRetriesInsertOnce() {
        let group = DispatchGroup()
        for _ in 0..<8 {
            DispatchQueue.global().async(group: group) { _ = self.post(#"{"id":"race","text":"x"}"#) }
        }
        group.wait()
        XCTAssertEqual(inserter.inserted.count, 1)
    }

    func testDedupeEntriesExpireAndAreBounded() {
        var t = Date(timeIntervalSince1970: 0)
        let cache = DedupeCache(ttl: 10, capacity: 2, now: { t })
        let ok = HTTPResponse.json(200, ["ok": true])
        cache.remember("a", ok); cache.remember("b", ok); cache.remember("c", ok)
        XCTAssertNil(cache.lookup("a"))           // evicted by capacity
        XCTAssertNotNil(cache.lookup("c"))
        t = Date(timeIntervalSince1970: 11)
        XCTAssertNil(cache.lookup("c"))           // expired
    }

    // MARK: logging never contains text

    func testLogsNeverContainInsertedText() {
        _ = post(#"{"id":"log-1","text":"TOP-SECRET-PHRASE","source":"phone"}"#)
        _ = post(#"{"id":"log-1","text":"TOP-SECRET-PHRASE","source":"phone"}"#)
        probe.screenLocked = true
        _ = post(#"{"id":"log-2","text":"TOP-SECRET-PHRASE"}"#)
        XCTAssertFalse(logger.lines.isEmpty)
        XCTAssertFalse(logger.lines.joined().contains("TOP-SECRET"))
        XCTAssertFalse(logger.lines.joined().contains("good"))
    }
}
