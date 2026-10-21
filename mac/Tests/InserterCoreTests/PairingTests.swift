import XCTest
@testable import InserterCore

/// One-time pairing of a browser outside the tailnet (the PWA): the book on its own with a fake clock and fake randomness, then
/// the routes, and above all that nothing here weakens the tailnet-identity path.
final class PairingBookTests: XCTestCase {
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var counter: UInt8 = 0

    /// Bytes that change on every call, so two codes or tokens never collide in a test and nothing is truly random.
    func fakeRandom(_ n: Int) -> [UInt8] {
        (0..<n).map { _ in counter &+= 7; return counter }
    }

    func book() -> PairingBook {
        PairingBook(now: { self.clock }, random: fakeRandom, limiter: LogRateLimiter(limit: 1000, window: 60))
    }

    func testCodeIsEightSymbolsFromTheUnambiguousAlphabet() {
        let issued = book().issueCode()
        XCTAssertEqual(issued.code.count, 9)
        XCTAssertEqual(issued.code[issued.code.index(issued.code.startIndex, offsetBy: 4)], "-")
        let symbols = issued.code.replacingOccurrences(of: "-", with: "")
        XCTAssertTrue(symbols.allSatisfy { PairingBook.alphabet.contains($0) })
        XCTAssertFalse(symbols.contains { "01OIL".contains($0) })
        XCTAssertEqual(issued.expiresIn, 300)
    }

    func testCodeWorksOnceAndGivesAToken() {
        let b = book()
        let code = b.issueCode().code
        guard case .paired(let token, let device) = b.redeem(code: code, device: "Ann's iPhone") else { return XCTFail("not paired") }
        XCTAssertEqual(device.name, "Ann's iPhone")
        XCTAssertEqual(device.expiresAt.timeIntervalSince(clock), 24 * 3600)
        XCTAssertEqual(b.verify(token: token)?.id, device.id)
        XCTAssertEqual(b.redeem(code: code, device: "again"), .refused, "a code is single use")
    }

    func testCodeIsReadForgivingly() {
        let b = book()
        let code = b.issueCode().code
        XCTAssertNotEqual(b.redeem(code: " " + code.lowercased().replacingOccurrences(of: "-", with: " ") + " ", device: "x"), .refused)
    }

    func testCodeExpires() {
        let b = book()
        let code = b.issueCode().code
        clock.addTimeInterval(PairingBook.codeTTL + 1)
        XCTAssertEqual(b.redeem(code: code, device: "x"), .refused)
    }

    func testANewCodeReplacesTheOldOne() {
        let b = book()
        let first = b.issueCode().code
        let second = b.issueCode().code
        XCTAssertEqual(b.redeem(code: first, device: "x"), .refused)
        // The wrong guess above counted against the live code, which still works.
        if case .paired = b.redeem(code: second, device: "x") {} else { XCTFail("the newest code should work") }
    }

    func testWrongGuessesBurnTheCode() {
        let b = book()
        let code = b.issueCode().code
        for _ in 0..<PairingBook.maxWrongGuesses { XCTAssertEqual(b.redeem(code: "AAAA-AAAA", device: "x"), .refused) }
        XCTAssertEqual(b.redeem(code: code, device: "x"), .refused, "even the right code is dead after too many wrong guesses")
    }

    func testAttemptsAreRateLimited() {
        let b = PairingBook(now: { self.clock }, random: fakeRandom, limiter: LogRateLimiter(limit: 3, window: 60))
        _ = b.issueCode()
        for _ in 0..<3 { _ = b.redeem(code: "AAAA-AAAA", device: "x") }
        guard case .slowDown(let wait) = b.redeem(code: "AAAA-AAAA", device: "x") else { return XCTFail("expected slow down") }
        XCTAssertGreaterThan(wait, 0)
    }

    func testTokenExpiresAndIsPerDevice() {
        let b = book()
        guard case .paired(let t1, let d1) = b.redeem(code: b.issueCode().code, device: "one"),
              case .paired(let t2, let d2) = b.redeem(code: b.issueCode().code, device: "two") else { return XCTFail("not paired") }
        XCTAssertNotEqual(t1, t2)
        XCTAssertEqual(b.verify(token: t1)?.id, d1.id)
        XCTAssertEqual(b.verify(token: t2)?.id, d2.id)
        clock.addTimeInterval(PairingBook.tokenTTL + 1)
        XCTAssertNil(b.verify(token: t1))
        XCTAssertTrue(b.devices().isEmpty)
    }

    func testRevokeOneAndAll() {
        let b = book()
        guard case .paired(let t1, let d1) = b.redeem(code: b.issueCode().code, device: "one"),
              case .paired(let t2, _) = b.redeem(code: b.issueCode().code, device: "two") else { return XCTFail("not paired") }
        XCTAssertTrue(b.revoke(id: d1.id))
        XCTAssertNil(b.verify(token: t1))
        XCTAssertNotNil(b.verify(token: t2))
        XCTAssertFalse(b.revoke(id: d1.id))
        XCTAssertEqual(b.revokeAll(), 1)
        XCTAssertNil(b.verify(token: t2))
    }

    func testOnlyTheHashIsKept() {
        let b = book()
        guard case .paired(let token, _) = b.redeem(code: b.issueCode().code, device: "one") else { return XCTFail("not paired") }
        let shown = b.devices().map { "\($0.json)" }.joined()
        XCTAssertFalse(shown.contains(token))
        XCTAssertGreaterThanOrEqual(token.count, 43, "256 bits")
        XCTAssertNil(b.verify(token: String(token.dropLast())))
        XCTAssertNil(b.verify(token: ""))
    }

    func testTheNumberOfDevicesIsCapped() {
        let b = book()
        for i in 0..<(PairingBook.maxDevices + 3) { _ = b.redeem(code: b.issueCode().code, device: "d\(i)") }
        XCTAssertEqual(b.devices().count, PairingBook.maxDevices)
        XCTAssertEqual(b.devices().last?.name, "d\(PairingBook.maxDevices + 2)")
    }

    func testDeviceNamesAreOneShortPrintableLine() {
        XCTAssertEqual(PairingBook.cleanName("  a\nb\u{7}c  "), "a b c")
        XCTAssertEqual(PairingBook.cleanName("   "), "browser")
        XCTAssertEqual(PairingBook.cleanName(String(repeating: "x", count: 100)).count, 40)
    }
}

final class PairingRouteTests: XCTestCase {
    var keys = StubKeys()
    var probe = StubProbe()
    var inserter = SpyInserter()
    var logger = SpyLogger()
    var identity = HandlerTests.StubIdentity()
    var book: PairingBook!
    var handler: RequestHandler!

    override func setUp() {
        keys = StubKeys(); probe = StubProbe(); inserter = SpyInserter(); logger = SpyLogger()
        identity = HandlerTests.StubIdentity()
        book = PairingBook()
        handler = RequestHandler(keys: keys, probe: probe, inserter: inserter, name: { "Test Mac" }, identity: identity,
                                 pairing: book, logger: logger)
    }

    func object(_ r: HTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:] }

    func send(_ method: String, _ path: String, _ body: String = "", headers: [String: String] = [:], loopback: Bool = false,
              peer: String? = nil) -> HTTPResponse {
        handler.handle(HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8), fromLoopback: loopback, peerAddress: peer))
    }

    /// Asks for a code as the person at this Mac and exchanges it as a browser would; returns the token.
    func pairedToken(device: String = "Test browser") -> String {
        let code = object(send("POST", "/pair/code", "{}", loopback: true))["code"] as? String ?? ""
        let r = send("POST", "/pair", #"{"code":"\#(code)","device":"\#(device)"}"#)
        return object(r)["token"] as? String ?? ""
    }

    // MARK: asking for a code

    func testOnlyThePersonAtThisMacAsksForACode() {
        XCTAssertEqual(send("POST", "/pair/code", "{}", loopback: true).status, 200)
        // a device of the same tailnet user is not enough: the code is handed out at the Mac
        XCTAssertEqual(send("POST", "/pair/code", "{}", peer: "100.64.0.9").status, 403)
        XCTAssertEqual(send("GET", "/pair/devices", peer: "100.64.0.9").status, 403)
        XCTAssertEqual(send("POST", "/pair/revoke", #"{"all":true}"#, peer: "100.64.0.9").status, 401)
    }

    func testARequestThroughAProxyIsNotThePersonAtThisMac() {
        for header in ["X-Forwarded-For", "Tailscale-User-Login", "Forwarded", "X-Real-IP", "Tailscale-Funnel-Request"] {
            let r = send("POST", "/pair/code", "{}", headers: [header: "1.2.3.4"], loopback: true)
            XCTAssertEqual(r.status, 403, header)
            XCTAssertEqual(object(r)["error"] as? String, "local_only", header)
        }
        XCTAssertEqual(send("GET", "/pair/devices", headers: ["X-Forwarded-For": "1.2.3.4"], loopback: true).status, 403)
    }

    func testTheCodeIsNeverLogged() {
        let code = object(send("POST", "/pair/code", "{}", loopback: true))["code"] as? String ?? "?"
        let token = object(send("POST", "/pair", #"{"code":"\#(code)"}"#))["token"] as? String ?? "?"
        _ = send("POST", "/text", #"{"id":"a","text":"hi"}"#, headers: ["X-Greenfield-Token": token])
        _ = send("POST", "/pair", #"{"code":"WRONG-CODE"}"#)
        let log = logger.lines.joined(separator: "\n")
        XCTAssertFalse(log.contains(code))
        XCTAssertFalse(log.contains(code.replacingOccurrences(of: "-", with: "")))
        XCTAssertFalse(log.contains(token))
        XCTAssertFalse(log.contains("WRONG"))
        XCTAssertTrue(log.contains("pair code issued"))
    }

    // MARK: exchanging it

    func testExchangeGivesATokenThatSendsText() {
        let token = pairedToken()
        XCTAssertFalse(token.isEmpty)
        let r = send("POST", "/text", #"{"id":"a1","text":"hello\nworld","source":"greenfield-pwa"}"#, headers: ["X-Greenfield-Token": token])
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(inserter.inserted.first?.0, "hello\nworld")
        XCTAssertEqual(send("GET", "/status", headers: ["X-Greenfield-Token": token]).status, 200)
    }

    func testWrongBadAndRepeatedCodesAreRefused() {
        XCTAssertEqual(send("POST", "/pair", #"{"code":"AAAA-AAAA"}"#).status, 401, "no code was issued")
        XCTAssertEqual(object(send("POST", "/pair", #"{"code":"AAAA-AAAA"}"#))["error"] as? String, "pair_refused")
        XCTAssertEqual(send("POST", "/pair", "not json").status, 400)
        XCTAssertEqual(send("POST", "/pair", #"{"code":5}"#).status, 400)
        XCTAssertEqual(send("GET", "/pair").status, 405)
        let code = object(send("POST", "/pair/code", "{}", loopback: true))["code"] as? String ?? ""
        XCTAssertEqual(send("POST", "/pair", #"{"code":"\#(code)"}"#).status, 200)
        XCTAssertEqual(send("POST", "/pair", #"{"code":"\#(code)"}"#).status, 401, "single use")
    }

    func testExchangeIsRateLimited() {
        var last = 0
        for _ in 0..<12 { last = send("POST", "/pair", #"{"code":"AAAA-AAAA"}"#).status }
        XCTAssertEqual(last, 429)
    }

    // MARK: what a token may and may not do

    func testATokenReachesStatusAndTextOnly() {
        let t = ["X-Greenfield-Token": pairedToken()]
        XCTAssertEqual(send("GET", "/peers", headers: t).status, 403)
        XCTAssertEqual(send("GET", "/logs", headers: t).status, 403)
        XCTAssertEqual(send("GET", "/assist/windows", headers: t).status, 403)
        XCTAssertEqual(send("POST", "/pair/code", "{}", headers: t).status, 403)
        XCTAssertEqual(send("GET", "/health", headers: t).status, 403)
    }

    func testAnUnknownRevokedOrExpiredTokenIsRefused() {
        XCTAssertEqual(object(send("GET", "/status", headers: ["X-Greenfield-Token": "nope"]))["error"] as? String, "invalid_token")
        let token = pairedToken()
        let id = (book.devices().first?.id) ?? ""
        let revoked = send("POST", "/pair/revoke", "{\"id\":\"\(id)\"}", loopback: true)
        XCTAssertEqual(revoked.status, 200)
        XCTAssertEqual(send("POST", "/text", #"{"id":"a","text":"x"}"#, headers: ["X-Greenfield-Token": token]).status, 401)
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    func testADeviceCanLeaveByItself() {
        let token = pairedToken()
        XCTAssertEqual(send("POST", "/pair/revoke", "{}", headers: ["X-Greenfield-Token": token]).status, 200)
        XCTAssertEqual(send("GET", "/status", headers: ["X-Greenfield-Token": token]).status, 401)
        XCTAssertEqual(send("POST", "/pair/revoke", "{}").status, 401)
    }

    func testRevokeAllAndList() {
        let a = pairedToken(device: "A"), b = pairedToken(device: "B")
        let list = object(send("GET", "/pair/devices", loopback: true))["devices"] as? [[String: Any]] ?? []
        XCTAssertEqual(list.map { $0["name"] as? String ?? "" }, ["A", "B"])
        XCTAssertFalse("\(list)".contains(a) || "\(list)".contains(b))
        XCTAssertEqual(object(send("POST", "/pair/revoke", #"{"all":true}"#, loopback: true))["revoked"] as? Int, 2)
        XCTAssertEqual(send("GET", "/status", headers: ["X-Greenfield-Token": a]).status, 401)
        XCTAssertEqual(send("POST", "/pair/revoke", #"{"id":"nope"}"#, loopback: true).status, 404)
    }

    // MARK: the tailnet-identity path is untouched

    func testIdentityStillDecidesWithoutAToken() {
        XCTAssertEqual(send("GET", "/status", peer: "100.64.0.9").status, 200)
        identity.result = .otherUser(login: "stranger@example")
        XCTAssertEqual(send("GET", "/status", peer: "100.64.0.9").status, 401)
        identity.result = .unknown("tailscale is not running")
        XCTAssertEqual(send("GET", "/status", peer: "100.64.0.9").status, 503)
    }

    func testPairingDoesNotLetAnotherUserInWithoutAToken() {
        _ = pairedToken()
        identity.result = .otherUser(login: "stranger@example")
        XCTAssertEqual(send("POST", "/text", #"{"id":"a","text":"x"}"#, peer: "100.64.0.9").status, 401)
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    func testAProxiedLoopbackRequestIsNotTrustedAsLocal() {
        // `tailscale serve` and the PWA's server reach the daemon from 127.0.0.1: that must not count as "this Mac".
        let proxied = ["X-Forwarded-For": "100.99.1.2"]
        let r = send("POST", "/text", #"{"id":"a","text":"x"}"#, headers: proxied, loopback: true, peer: "127.0.0.1")
        XCTAssertEqual(r.status, 503)
        XCTAssertEqual(object(r)["error"] as? String, "identity_unavailable")
        XCTAssertEqual(send("GET", "/status", headers: ["Tailscale-User-Login": "stranger@example"], loopback: true, peer: "127.0.0.1").status, 503)
        XCTAssertEqual(send("GET", "/health", headers: proxied, loopback: true).status, 403)
        XCTAssertTrue(inserter.inserted.isEmpty)
        // a proxied request with a valid token is let in, and with a wrong one is refused
        let token = pairedToken()
        XCTAssertEqual(send("POST", "/text", #"{"id":"b","text":"x"}"#, headers: proxied.merging(["X-Greenfield-Token": token]) { a, _ in a },
                            loopback: true, peer: "127.0.0.1").status, 200)
        XCTAssertEqual(send("POST", "/text", #"{"id":"c","text":"x"}"#, headers: proxied.merging(["X-Greenfield-Token": "bad"]) { a, _ in a },
                            loopback: true, peer: "127.0.0.1").status, 401)
    }

    func testARequestFromLoopbackWithoutProxyHeadersIsStillLocal() {
        XCTAssertEqual(send("POST", "/text", #"{"id":"a","text":"x"}"#, loopback: true).status, 200)
        XCTAssertEqual(send("GET", "/health", loopback: true).status, 200)
    }

    func testNoTokenBypassesTheKeyPath() {
        // A token is not a key and a key is not a token.
        keys.result = .ok
        XCTAssertEqual(send("GET", "/status", headers: ["X-Greenfield-Token": "good"]).status, 401)
        XCTAssertEqual(send("GET", "/status", headers: ["X-Dictation-Key": "good"], peer: "100.64.0.9").status, 200)
    }
}
