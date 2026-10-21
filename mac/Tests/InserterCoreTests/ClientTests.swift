import XCTest
@testable import InserterCore

final class ClientTests: XCTestCase {
    func status(_ json: String, _ code: Int = 200) -> (MacState, name: String?, version: String?, listen: [String]) {
        InserterClient.classify(httpStatus: code, body: Data(json.utf8))
    }

    func testClassifiesStates() {
        let base = #""name":"m","version":"0.1.0""#
        XCTAssertEqual(status("{\(base),\"accessibility\":true,\"screen_locked\":false,\"secure_input\":false}").0, .ready)
        XCTAssertEqual(status("{\(base),\"accessibility\":true,\"screen_locked\":true,\"secure_input\":false}").0, .locked)
        XCTAssertEqual(status("{\(base),\"accessibility\":true,\"screen_locked\":false,\"secure_input\":true}").0, .secureInput)
        XCTAssertEqual(status("{\(base),\"accessibility\":false,\"screen_locked\":false,\"secure_input\":false}").0, .noAccessibility)
        XCTAssertEqual(status("{}", 401).0, .unauthorized)
        XCTAssertEqual(status(#"{"error":"identity_unavailable"}"#, 503).0, .identityUnavailable)
        XCTAssertEqual(status(#"{"version":"1","accessibility":true,"identity_ok":false}"#).0, .identityUnavailable)
        XCTAssertEqual(status(#"{"error":"key_not_configured"}"#, 503).0, .keyNotSet)
        XCTAssertEqual(status("{}", 500).0, .unexpected(500))
        let ready = status("{\(base),\"accessibility\":true}")
        XCTAssertEqual(ready.name, "m"); XCTAssertEqual(ready.version, "0.1.0")
    }

    func testAttentionOnlyForRealProblems() {
        XCTAssertFalse(MacState.ready.needsAttention)
        XCTAssertFalse(MacState.locked.needsAttention)
        XCTAssertFalse(MacState.secureInput.needsAttention)
        XCTAssertTrue(MacState.noAccessibility.needsAttention)
        XCTAssertTrue(MacState.unreachable("x").needsAttention)
        XCTAssertTrue(MacState.unauthorized.needsAttention)
    }

    func testInterpretSend() {
        func r(_ code: Int, _ body: String = "{}") -> InserterClient.SendResult {
            InserterClient.interpretSend(httpStatus: code, body: Data(body.utf8))
        }
        XCTAssertTrue(r(200, #"{"method":"paste"}"#).inserted)
        XCTAssertFalse(r(409).inserted); XCTAssertTrue(r(409).summary.contains("secure input"))
        XCTAssertTrue(r(423).summary.contains("locked"))
        XCTAssertTrue(r(503, #"{"error":"accessibility_not_granted"}"#).summary.contains("Accessibility"))
        XCTAssertTrue(r(503, #"{"error":"key_not_configured"}"#).summary.contains("no key"))
        XCTAssertTrue(r(503, #"{"error":"identity_unavailable"}"#).summary.contains("Tailscale"))
        XCTAssertTrue(r(401).summary.contains("tailnet user"))
        XCTAssertTrue(r(502).summary.contains("not delivered"))
    }

    func testRegistryRoundTripAndPermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let reg = MacRegistry(paths: InserterPaths(directory: dir))
        XCTAssertEqual(reg.load(), [])
        // an entry with no key (the normal case now) and an older file without a port still load
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"[{"alias":"old","host":"h"}]"#.utf8).write(to: reg.file)
        XCTAssertEqual(reg.load(), [KnownMac(alias: "old", host: "h")])
        try FileManager.default.removeItem(at: reg.file)
        try reg.upsert(KnownMac(alias: "mini0", host: "mini0.example", key: "k1"))
        try reg.upsert(KnownMac(alias: "book", host: "book.example", port: 1234, key: "k2"))
        try reg.upsert(KnownMac(alias: "mini0", host: "mini0.example", key: "k3"))      // replaces
        XCTAssertEqual(reg.load().map(\.alias), ["book", "mini0"])
        XCTAssertEqual(reg.load().last?.key, "k3")
        let attrs = try FileManager.default.attributesOfItem(atPath: reg.file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try reg.remove("book")
        XCTAssertEqual(reg.load().map(\.alias), ["mini0"])
        XCTAssertThrowsError(try reg.upsert(KnownMac(alias: "bad alias!", host: "h", port: 4001, key: "k")))
    }

    func testTableFormatNeverContainsKeys() {
        let mac = KnownMac(alias: "mini0", host: "h", port: 4001, key: "SECRETKEY")
        let out = formatReports([MacReport(mac: mac, state: .ready, name: "Mini", version: "0.1.0")])
        XCTAssertTrue(out.contains("mini0")); XCTAssertTrue(out.contains("ready"))
        XCTAssertFalse(out.contains("SECRETKEY"))
    }

    func testExposurePolicy() {
        XCTAssertTrue(isTailnetOrLoopback("100.84.99.99:4001"))
        XCTAssertTrue(isTailnetOrLoopback("100.127.255.254:1"))
        XCTAssertTrue(isTailnetOrLoopback("127.0.0.1:4001"))
        XCTAssertFalse(isTailnetOrLoopback("0.0.0.0:4001"))
        XCTAssertFalse(isTailnetOrLoopback("192.168.1.5:4001"))
        XCTAssertFalse(isTailnetOrLoopback("100.63.0.1:1"))
        XCTAssertFalse(isTailnetOrLoopback("100.128.0.1:1"))
        let mac = KnownMac(alias: "m", host: "h", port: 4001, key: "k")
        let good = MacReport(mac: mac, state: .ready, name: "m", version: "1", listen: ["100.84.99.99:1", "127.0.0.1:1"])
        let bad = MacReport(mac: mac, state: .ready, name: "m", version: "1", listen: ["100.84.99.99:1", "0.0.0.0:1"])
        XCTAssertFalse(good.needsAttention)
        XCTAssertTrue(bad.needsAttention)
        XCTAssertEqual(bad.exposed, ["0.0.0.0:1"])
        XCTAssertTrue(formatReports([bad]).contains("WARNING"))
        XCTAssertTrue(formatReports([good]).contains("ok"))
    }

    func testStatusListenIsParsed() {
        XCTAssertEqual(status(#"{"accessibility":true,"listen":["127.0.0.1:1"]}"#).listen, ["127.0.0.1:1"])
    }
}
