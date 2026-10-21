import XCTest
import CryptoKit
import KitAssist
@testable import InserterCore

final class FakeListener: PointerListener {
    var starts = 0, stops = 0
    var canStart = true
    var endpoint: (address: String, port: UInt16)? { open ? ("100.64.0.10", 47821) : nil }
    private var open = false
    func start() -> Bool { guard canStart else { return false }; starts += 1; open = true; return true }
    func stop() { stops += 1; open = false }
    var isOpen: Bool { open }
}

/// Everything the pointer receiver does, with a RecordingSink: no test here posts a real pointer event.
final class AssistPointerTests: XCTestCase {
    static let caller = "100.64.0.20"

    var settings = MutableSettings(AssistSettings(enabled: true, pointer: true))
    var probe = StubProbe()
    var sink = RecordingSink()
    var listener = FakeListener()
    var logger = SpyLogger()
    var clock = ManualClock()
    var limits = PointerLimits()
    var nextSession: UInt32 = 0x0102_0304
    var keyOffset: UInt8 = 0
    var service: PointerService!
    var handler: RequestHandler!

    override func setUp() {
        settings = MutableSettings(AssistSettings(enabled: true, pointer: true))
        probe = StubProbe(); sink = RecordingSink(); listener = FakeListener(); logger = SpyLogger(); clock = ManualClock()
        limits = PointerLimits(); nextSession = 0x0102_0304; keyOffset = 0
        build()
    }

    func build() {
        service = PointerService(settings: settings, probe: probe, sink: sink, listener: listener, limits: limits, logger: logger, random: { [unowned self] count in
            if count == 4 { defer { nextSession &+= 1 }; return Data([UInt8(nextSession >> 24), UInt8(nextSession >> 16 & 255), UInt8(nextSession >> 8 & 255), UInt8(nextSession & 255)]) }
            defer { keyOffset &+= 1 }
            return Data((0..<count).map { UInt8($0) &+ keyOffset })
        })
        let assist = AssistEndpoints(settings: settings, windows: nil, pointer: service, endpoint: { [listener] in listener.endpoint }, logger: logger,
                                     clock: { [clock] in clock.now })
        handler = RequestHandler(keys: StubKeys(), probe: probe, inserter: SpyInserter(), name: { "Studio Mac" }, identity: FakeIdentity(), assist: assist,
                                 version: "0.4.0", minClientVersion: "0.2.0", logger: logger)
    }

    func open(_ caller: String = caller) throws -> PointerSessionOffer {
        switch service.open(caller: caller, now: clock.now) {
        case .success(let offer): return offer
        case .failure(let error): XCTFail("open failed: \(error)"); throw CancellationError()
        }
    }

    func wire(_ offer: PointerSessionOffer, seq: UInt32, _ body: TPT1.Body, session: UInt32? = nil) -> Data {
        TPT1.encode(TPT1.Packet(session: session ?? offer.session, seq: seq, timestamp: 0, body: body), authenticator: PointerAuthenticator(key: offer.key))
    }

    func send(_ data: Data, from source: String = caller) -> Data? { service.receive(data, from: source, now: clock.now) }

    func frame(moveX: Int32 = 0, moveY: Int32 = 0, buttons: UInt8 = 0, events: [TPT1.Event] = []) -> TPT1.Body {
        .frame(TPT1.Frame(moveX: moveX, moveY: moveY, buttons: buttons, events: events))
    }

    func reply(_ data: Data?, _ offer: PointerSessionOffer) throws -> TPT1.Packet {
        try TPT1.decode(XCTUnwrap(data), authenticator: PointerAuthenticator(key: offer.key))
    }

    // MARK: The tag

    func testTheTagMatchesAnIndependentKnownAnswer() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let datagram = Data([0x54, 0x50, 0x54, 0x31, 0x05, 0x00, 0x01, 0x02, 0x03, 0x04, 0, 0, 0, 1, 0, 0, 0, 0])
        let tag = PointerAuthenticator(key: key).tag(for: datagram)
        XCTAssertEqual(tag.map { String(format: "%02x", $0) }.joined(), "97b9dada3fe4445daeb8aee2ce65ff2d", "computed with Python's hmac, outside this code")
        XCTAssertTrue(PointerAuthenticator(key: key).isValid(tag: tag, for: datagram))
        var bad = tag; bad[0] ^= 1
        XCTAssertFalse(PointerAuthenticator(key: key).isValid(tag: bad, for: datagram))
        XCTAssertFalse(PointerAuthenticator(key: key).isValid(tag: tag.dropLast(), for: datagram))
        XCTAssertFalse(PointerAuthenticator(key: Data(repeating: 9, count: 32)).isValid(tag: tag, for: datagram))
    }

    // MARK: Opening a session over HTTP

    func openOverHTTP(peer: String = caller, headers: [String: String] = [:]) -> HTTPResponse {
        handler.handle(HTTPRequest(method: "POST", path: "/assist/pointer/session", headers: headers, body: Data("{}".utf8), peerAddress: peer))
    }

    func testTheHandshakeHandsOutAFreshSessionAndKey() throws {
        let r = openOverHTTP()
        XCTAssertEqual(r.status, 200)
        let o = jsonObject(r)
        XCTAssertEqual(o["session"] as? Int, 0x0102_0304)
        let key = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(o["key"] as? String)))
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual((o["tag"] as? [String: Any])?["algorithm"] as? String, "hmac-sha256")
        XCTAssertEqual((o["tag"] as? [String: Any])?["length"] as? Int, 16)
        XCTAssertEqual((o["udp"] as? [String: Any])?["port"] as? Int, 47821)
        XCTAssertEqual((o["udp"] as? [String: Any])?["address"] as? String, "100.64.0.10")
        XCTAssertEqual(o["idle_timeout_s"] as? Int, 30)
        XCTAssertEqual(o["capabilities"] as? Int, 0)
        let second = jsonObject(openOverHTTP(peer: "100.64.0.20"))
        XCTAssertNotEqual(second["key"] as? String, o["key"] as? String, "every session has its own key")
        XCTAssertNotEqual(second["session"] as? Int, o["session"] as? Int)
        XCTAssertEqual(service.activeSessions, 1, "the same caller replaces its old session")
    }

    func testTheKeyIsNeverLogged() throws {
        let r = openOverHTTP()
        let key = try XCTUnwrap(jsonObject(r)["key"] as? String)
        _ = send(wire(try open(), seq: 1, .bye))
        for line in logger.lines { XCTAssertFalse(line.contains(key), line) }
        XCTAssertTrue(logger.lines.contains { $0.hasPrefix("assist pointer session opened") })
    }

    func testOnlyTheAuthenticatedUserMayOpenOne() {
        XCTAssertEqual(openOverHTTP(peer: "100.64.0.99", headers: ["X-Dictation-Key": "good"]).status, 403, "a key alone is refused")
        XCTAssertEqual(openOverHTTP(peer: "100.64.0.99").status, 401)
        XCTAssertEqual(openOverHTTP(peer: "100.64.0.5").status, 503)
        XCTAssertEqual(service.activeSessions, 0)
        XCTAssertEqual(listener.starts, 0, "no socket was opened for a refused caller")
    }

    func testOffByDefaultAndTheKillSwitch() {
        settings.settings = .off
        XCTAssertEqual(openOverHTTP().status, 404)
        settings.settings = AssistSettings(enabled: true)
        XCTAssertEqual(openOverHTTP().status, 404, "assist is on but the pointer has its own switch, off by default")
        XCTAssertEqual(AssistSettings.off.pointer, false)
        XCTAssertEqual(AssistSettings().enabled, false)
        XCTAssertEqual(listener.starts, 0)
    }

    func testNoSessionOnALockedScreenAndTheOpenRateIsLimited() throws {
        probe.screenLocked = true
        let locked = openOverHTTP()
        XCTAssertEqual(locked.status, 423)
        probe.screenLocked = false
        for peer in 0..<3 { XCTAssertNotNil(try? open("caller-\(peer)")) }
        let r = service.open(caller: "caller-9", now: clock.now)
        XCTAssertEqual(r, .failure(.rateLimited(retryAfter: 5)))
        let http = openOverHTTP()
        XCTAssertEqual(http.status, 429)
        XCTAssertEqual(http.headers["Retry-After"], "5")
    }

    func testAtMostSomeSessions() throws {
        limits.maxSessions = 2; limits.openBurst = 10
        build()
        _ = try open("a"); _ = try open("b")
        XCTAssertEqual(service.open(caller: "c", now: clock.now), .failure(.tooManySessions))
        _ = try open("a")
        XCTAssertEqual(service.activeSessions, 2)
    }

    func testTheSocketOpensOnlyWhileASessionExists() throws {
        limits.openBurst = 10
        build()
        XCTAssertFalse(listener.isOpen)
        let one = try open("a"), two = try open("b")
        XCTAssertEqual(listener.starts, 1)
        _ = send(wire(one, seq: 1, .bye), from: "a")
        XCTAssertTrue(listener.isOpen, "another session is still open")
        _ = send(wire(two, seq: 1, .bye), from: "b")
        XCTAssertFalse(listener.isOpen)
        listener.canStart = false
        XCTAssertEqual(service.open(caller: "a", now: clock.now), .failure(.noListener))
        XCTAssertEqual(openOverHTTP().status, 503)
    }

    // MARK: Datagrams that pass

    func testAnAuthenticatedPhoneMovesAndClicks() throws {
        let offer = try open()
        var sender = TPT1Sender(session: offer.session)
        sender.push(.move(dx: 10, dy: -5))
        sender.push(.click(.left, count: 1))
        var replies: [TPT1.Packet] = []
        for packet in sender.packets(now: 1) { if let r = send(TPT1.encode(packet, authenticator: PointerAuthenticator(key: offer.key))) { replies.append(try reply(r, offer)) } }
        XCTAssertEqual(sink.events, [.move(dx: 10, dy: -5), .click(.left, count: 1)])
        guard case let .ack(ack)? = replies.first?.body else { return XCTFail("a frame with an event is acknowledged") }
        XCTAssertEqual(ack.eventId, 1)
    }

    func testButtonDownMoveUpIsADrag() throws {
        let offer = try open()
        var sender = TPT1Sender(session: offer.session)
        sender.push(.button(.left, down: true)); sender.push(.move(dx: 4, dy: 0)); sender.push(.button(.left, down: false))
        for packet in sender.packets(now: 1) { _ = send(TPT1.encode(packet, authenticator: PointerAuthenticator(key: offer.key))) }
        XCTAssertEqual(sink.events, [.button(.left, down: true), .move(dx: 4, dy: 0), .button(.left, down: false)])
    }

    func testHelloIsAnsweredWithWhatThisMacCanDo() throws {
        let offer = try open()
        let r = try reply(send(wire(offer, seq: 1, .hello(nonce: 0xA1B2_C3D4))), offer)
        XCTAssertEqual(r.body, .helloAck(nonce: 0xA1B2_C3D4, capabilities: []))
        XCTAssertEqual(r.session, offer.session)
    }

    func testTheKitsVectorsGiveTheKitsEventsThroughThisPath() throws {
        let file = try KitFixtures.object("tpt1/vectors.json")
        let vectors = try XCTUnwrap(file["vectors"] as? [[String: Any]])
        XCTAssertGreaterThan(vectors.count, 5)
        for vector in vectors {
            let name = vector["name"] as? String ?? "?"
            let bytes = Data(hexString: try XCTUnwrap(vector["hex"] as? String))
            let packet = try TPT1.decode(bytes)
            guard packet.body.isFromThePhone else { continue }
            nextSession = packet.session
            build()
            clock.advance(1)
            let offer = try open()
            XCTAssertEqual(offer.session, packet.session)
            sink.clear()
            var reference = TPT1Receiver(session: packet.session, capabilities: [])
            let expected = reference.receive(packet, now: clock.now)
            let tagged = bytes + PointerAuthenticator(key: offer.key).tag(for: bytes)
            let answer = send(tagged)
            XCTAssertEqual(sink.events, expected.events, name)
            XCTAssertEqual(answer != nil, expected.reply != nil, name)
        }
    }

    func testTheKitsRejectedDatagramsDoNothingEvenWithAValidTag() throws {
        let rejected = try XCTUnwrap(try KitFixtures.object("tpt1/vectors.json")["rejected"] as? [[String: Any]])
        XCTAssertGreaterThan(rejected.count, 8)
        let offer = try open()
        for vector in rejected {
            let bytes = Data(hexString: try XCTUnwrap(vector["hex"] as? String))
            XCTAssertNil(send(bytes + PointerAuthenticator(key: offer.key).tag(for: bytes)), vector["name"] as? String ?? "")
        }
        XCTAssertEqual(sink.events, [])
        XCTAssertEqual(service.activeSessions, 1)
    }

    // MARK: Datagrams that do not

    func testNothingUnauthenticatedGetsAnythingBack() throws {
        let offer = try open()
        let good = wire(offer, seq: 1, frame(moveX: 160, events: [TPT1.Event(id: 1, action: .click(.left, count: 1))]))
        var flipped = good; flipped[flipped.count - 1] ^= 0x80
        var bodyChanged = good; bodyChanged[20] ^= 0x01
        let otherKey = TPT1.encode(TPT1.Packet(session: offer.session, seq: 1, body: frame(moveX: 160)), authenticator: PointerAuthenticator(key: Data(repeating: 7, count: 32)))
        let noTag = Data(good.dropLast(16))
        let attempts: [(String, Data, String)] = [
            ("flipped tag", flipped, Self.caller), ("changed body", bodyChanged, Self.caller), ("another key", otherKey, Self.caller),
            ("no tag", noTag, Self.caller), ("empty", Data(), Self.caller), ("garbage", Data(repeating: 0xAB, count: 64), Self.caller),
            ("too big", good + Data(repeating: 0, count: 600), Self.caller), ("wrong magic", Data("XXXX".utf8) + good.dropFirst(4), Self.caller),
            ("unknown session", wire(offer, seq: 1, frame(moveX: 160), session: offer.session &+ 5), Self.caller),
            ("another address", good, "100.64.0.99"),
        ]
        for (name, data, source) in attempts { XCTAssertNil(send(data, from: source), name) }
        XCTAssertEqual(sink.events, [], "nothing reached the sink")
        XCTAssertGreaterThanOrEqual(service.dropCount(.authentication), 3)
        XCTAssertEqual(service.dropCount(.wrongSource), 1)
        XCTAssertEqual(service.dropCount(.unknownSession), 1)
        XCTAssertNotNil(send(good), "the genuine datagram still works afterwards")
        XCTAssertEqual(sink.events, [.move(dx: 10, dy: 0), .click(.left, count: 1)])
    }

    func testAReplayedDatagramIsDroppedAndAnOldSessionKeyIsUseless() throws {
        let offer = try open()
        let first = wire(offer, seq: 5, frame(moveX: 160))
        XCTAssertNil(send(first))
        XCTAssertEqual(sink.events, [.move(dx: 10, dy: 0)])
        _ = send(first)
        _ = send(wire(offer, seq: 4, frame(moveX: 320)))
        XCTAssertEqual(sink.events, [.move(dx: 10, dy: 0)], "neither the replay nor the late datagram moved anything")
        XCTAssertEqual(service.dropCount(.rejected), 2)
        // a new session by the same phone replaces the old one; the old key and id no longer work
        _ = try open()
        _ = send(wire(offer, seq: 6, frame(moveX: 480)))
        XCTAssertEqual(sink.events.filter { if case .move = $0 { return true }; return false }.count, 1)
    }

    func testTheSessionOfAnotherPhoneIsNotUsable() throws {
        let mine = try open("100.64.0.20"), other = try open("100.64.0.30")
        XCTAssertNil(send(wire(mine, seq: 1, frame(moveX: 160)), from: "100.64.0.30"))
        XCTAssertEqual(sink.events, [])
        _ = other
    }

    func testRateLimitedPerSession() throws {
        limits.datagramsPerSecond = 10; limits.datagramBurst = 20
        build()
        let offer = try open()
        for seq in 1...100 { _ = send(wire(offer, seq: UInt32(seq), frame(moveX: Int32(seq) * 16))) }
        XCTAssertEqual(sink.events.count, 20, "only the burst got through at one instant")
        XCTAssertEqual(service.dropCount(.rateLimited), 80)
        clock.advance(1)
        _ = send(wire(offer, seq: 101, frame(moveX: 101 * 16)))
        XCTAssertEqual(sink.events.count, 21)
    }

    // MARK: Ending

    func testSilenceEndsASessionAfterThirtySeconds() throws {
        let offer = try open()
        _ = send(wire(offer, seq: 1, frame(buttons: 1)))
        XCTAssertEqual(sink.events, [.button(.left, down: true)])
        clock.advance(29); service.tick(now: clock.now)
        XCTAssertEqual(service.activeSessions, 1)
        clock.advance(2); service.tick(now: clock.now)
        XCTAssertEqual(service.activeSessions, 0)
        XCTAssertFalse(listener.isOpen)
        XCTAssertEqual(sink.events.last, .releaseAll, "what the phone held is let go")
        XCTAssertNil(send(wire(offer, seq: 2, frame(moveX: 160))), "the session is gone")
        XCTAssertTrue(logger.lines.contains("assist pointer session closed reason=idle active=0"))
    }

    func testActivityKeepsASessionAlive() throws {
        let offer = try open()
        for seq in 1...8 { clock.advance(20); _ = send(wire(offer, seq: UInt32(seq), .hello(nonce: 1))); service.tick(now: clock.now) }
        XCTAssertEqual(service.activeSessions, 1)
    }

    func testAHeldButtonIsReleasedWhenThePhoneVanishes() throws {
        let offer = try open()
        _ = send(wire(offer, seq: 1, frame(buttons: 1)))
        clock.advance(1.1); service.tick(now: clock.now)
        XCTAssertEqual(sink.events, [.button(.left, down: true), .button(.left, down: false), .releaseAll])
        XCTAssertEqual(service.activeSessions, 1, "the dead-man releases; the session itself lives to its idle limit")
    }

    func testTheLockedScreenEndsEverySession() throws {
        let one = try open("a"), two = try open("b")
        _ = send(wire(one, seq: 1, frame(buttons: 1)), from: "a")
        probe.screenLocked = true
        clock.advance(0.3); service.tick(now: clock.now)
        XCTAssertEqual(service.activeSessions, 0)
        XCTAssertEqual(sink.events.last, .releaseAll)
        probe.screenLocked = false
        XCTAssertNil(send(wire(two, seq: 1, frame(moveX: 160)), from: "b"), "unlocking does not bring the session back")
        XCTAssertTrue(logger.lines.contains { $0.contains("reason=screen locked") })
    }

    func testALockDuringADatagramStreamStopsIt() throws {
        let offer = try open()
        _ = send(wire(offer, seq: 1, frame(moveX: 160)))
        probe.screenLocked = true
        clock.advance(0.3)
        XCTAssertNil(send(wire(offer, seq: 2, frame(moveX: 320))))
        XCTAssertEqual(sink.events.filter { $0 == .move(dx: 10, dy: 0) }.count, 1)
        XCTAssertEqual(service.activeSessions, 0)
    }

    func testTheKillSwitchEndsEverySessionAtOnce() throws {
        let offer = try open()
        _ = send(wire(offer, seq: 1, frame(buttons: 1)))
        settings.settings.enabled = false
        clock.advance(0.3); service.tick(now: clock.now)
        XCTAssertEqual(service.activeSessions, 0)
        XCTAssertFalse(listener.isOpen)
        XCTAssertEqual(sink.events.last, .releaseAll)
        XCTAssertTrue(logger.lines.contains { $0.contains("reason=assist off") })
        settings.settings = AssistSettings(enabled: true, pointer: false)
        XCTAssertEqual(service.open(caller: Self.caller, now: clock.now), .failure(.disabled))
    }

    func testGoodbyeAndTheLifetimeEndASession() throws {
        let offer = try open()
        _ = send(wire(offer, seq: 1, frame(buttons: 2)))
        _ = send(wire(offer, seq: 2, .bye))
        XCTAssertEqual(service.activeSessions, 0)
        XCTAssertEqual(sink.events, [.button(.right, down: true), .button(.right, down: false), .releaseAll])
        let again = try open()
        for _ in 0..<130 { clock.advance(30); _ = send(wire(again, seq: 1, .hello(nonce: 1))); service.tick(now: clock.now) }
        XCTAssertEqual(service.activeSessions, 0, "an hour is the most a session lives, however busy")
    }

    func testDropCountsAreLoggedAsCountsOnly() throws {
        let offer = try open()
        for _ in 0..<5 { _ = send(Data(repeating: 1, count: 40)) }
        var flipped = wire(offer, seq: 1, frame(moveX: 16)); flipped[flipped.count - 1] ^= 1
        _ = send(flipped)
        clock.advance(11); service.tick(now: clock.now)
        let line = try XCTUnwrap(logger.lines.first { $0.hasPrefix("assist pointer datagrams dropped") })
        XCTAssertTrue(line.contains("malformed=5") && line.contains("authentication=1"), line)
    }

    // MARK: The transport

    func testTheSocketNeverListensOnEveryInterface() {
        XCTAssertEqual(UDPPointerTransport.validate("0.0.0.0"), .wildcard)
        XCTAssertEqual(UDPPointerTransport.validate("::"), .notAnIPv4Address)
        XCTAssertEqual(UDPPointerTransport.validate("not an address"), .notAnIPv4Address)
        XCTAssertNil(UDPPointerTransport.validate("100.64.0.10"))
        let wildcard = UDPPointerTransport(address: { "0.0.0.0" }, port: 0)
        XCTAssertFalse(wildcard.start())
        XCTAssertNil(wildcard.endpoint)
        let none = UDPPointerTransport(address: { nil }, port: 0)
        XCTAssertFalse(none.start(), "no tailnet address, no socket")
    }

    func testRealDatagramsOverTheLoopback() throws {
        let transport = UDPPointerTransport(address: { "127.0.0.1" }, port: 0)
        let live = PointerService(settings: settings, probe: probe, sink: sink, listener: transport, limits: limits)
        transport.service = live
        guard case let .success(offer) = live.open(caller: "loopback", now: ProcessInfo.processInfo.systemUptime) else { return XCTFail("open") }
        defer { live.endAll(reason: "test over") }
        let target = try XCTUnwrap(transport.endpoint)
        XCTAssertEqual(target.address, "127.0.0.1")
        XCTAssertNotEqual(target.port, 0)

        let client = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(client) }
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); sin.sin_family = sa_family_t(AF_INET); sin.sin_port = target.port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &sin.sin_addr)
        func exchange(_ data: Data) -> Data? {
            let bytes = [UInt8](data)
            _ = withUnsafePointer(to: &sin) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(client, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            var buffer = [UInt8](repeating: 0, count: 1024)
            let n = recv(client, &buffer, buffer.count, 0)
            return n > 0 ? Data(buffer[0..<n]) : nil
        }
        let auth = PointerAuthenticator(key: offer.key)
        let hello = TPT1.encode(TPT1.Packet(session: offer.session, seq: 1, body: .hello(nonce: 77)), authenticator: auth)
        let answer = try TPT1.decode(XCTUnwrap(exchange(hello)), authenticator: auth)
        XCTAssertEqual(answer.body, .helloAck(nonce: 77, capabilities: []))

        var forged = hello; forged[forged.count - 1] ^= 1
        XCTAssertNil(exchange(forged), "an unauthenticated datagram gets no answer, not even an error")
        let click = TPT1.encode(TPT1.Packet(session: offer.session, seq: 2, body: frame(events: [TPT1.Event(id: 1, action: .click(.right, count: 1))])), authenticator: auth)
        XCTAssertNotNil(exchange(click))
        XCTAssertEqual(sink.events, [.click(.right, count: 1)])

        live.endAll(reason: "test")
        XCTAssertNil(transport.endpoint, "the socket is gone with the last session")
        XCTAssertNil(exchange(wire(offer, seq: 3, .hello(nonce: 1))))
    }

    // MARK: Guard rails

    func testNoTestConstructsTheRealSink() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let marker = "CGEventPointer" + "Sink("
        for file in try FileManager.default.contentsOfDirectory(at: tests, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains(marker), "\(file.lastPathComponent) must not make the real sink")
        }
    }
}

extension TPT1.Body {
    var isFromThePhone: Bool {
        switch self {
        case .hello, .frame, .bye: return true
        case .helloAck, .ack: return false
        }
    }
}

extension Data {
    init(hexString hex: String) {
        self.init()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<next], radix: 16) { append(byte) }
            index = next
        }
    }
}
