import Network
import XCTest
@testable import DictationApp

final class TailnetTests: XCTestCase {
    func testIPv4LiteralsAndTheTailnetRange() {
        XCTAssertTrue(Tailnet.isIPv4Literal("100.84.99.99"))
        XCTAssertFalse(Tailnet.isIPv4Literal("macbook"))
        XCTAssertFalse(Tailnet.isIPv4Literal("100.84.99"))
        XCTAssertFalse(Tailnet.isIPv4Literal("100.84.99.300"))
        XCTAssertTrue(Tailnet.isTailnetAddress("100.64.0.1"))
        XCTAssertTrue(Tailnet.isTailnetAddress("100.127.255.254"))
        XCTAssertFalse(Tailnet.isTailnetAddress("100.128.0.1"))
        XCTAssertFalse(Tailnet.isTailnetAddress("192.168.1.5"))
    }

    func testWhichHostsNeedTheTailnet() {
        XCTAssertTrue(Tailnet.needsTailnet("mini0.example.ts.net"))
        XCTAssertTrue(Tailnet.needsTailnet("MacBook.Example.TS.NET"))
        XCTAssertTrue(Tailnet.needsTailnet("100.84.99.99"))
        XCTAssertFalse(Tailnet.needsTailnet("macbook"), "a short name may be a local host")
        XCTAssertFalse(Tailnet.needsTailnet("192.168.1.5"))
    }
}

private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var sent: [URL] { lock.withLock { urls } }

    func send(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        lock.withLock { urls.append(request.url!) }
        return (200, json(["ok": true, "status": "inserted", "duplicate": false]))
    }
}

final class TransportRoutingTests: XCTestCase {
    func testAddressesGoThroughTheSocketTransportAndNamesThroughURLSession() async {
        StubURLProtocol.install { _ in (200, json(["ok": true])) }
        let socket = RecordingTransport()
        let client = ReceiverClient(session: StubURLProtocol.session(), addressTransport: socket, tailnetConnected: { true })
        _ = await client.send(id: UUID(), text: "x", to: URL(string: "http://100.84.99.99:7788")!, key: "k")
        _ = await client.send(id: UUID(), text: "x", to: URL(string: "http://mini0.example.ts.net:7788")!, key: "k")
        XCTAssertEqual(socket.sent.map(\.host), ["100.84.99.99"])
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.host }, ["mini0.example.ts.net"])
    }

    func testOffTheTailnetTheMessageIsClearAndNothingIsSent() async {
        StubURLProtocol.install { _ in (200, json(["ok": true])) }
        let socket = RecordingTransport()
        let client = ReceiverClient(session: StubURLProtocol.session(), addressTransport: socket, tailnetConnected: { false })
        for host in ["http://100.84.99.99:7788", "http://mini0.example.ts.net:7788"] {
            let (outcome, _) = await client.send(id: UUID(), text: "x", to: URL(string: host)!, key: nil)
            XCTAssertEqual(outcome, .unreachable(Tailnet.notConnectedMessage), host)
            let health = await client.health(of: URL(string: host)!, key: nil)
            XCTAssertEqual(health, .unreachable(Tailnet.notConnectedMessage), host)
        }
        XCTAssertTrue(socket.sent.isEmpty)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testAShortNameIsNotBlockedByTheTailnetCheck() async {
        StubURLProtocol.install { _ in (200, json(["ok": true])) }
        let client = ReceiverClient(session: StubURLProtocol.session(), tailnetConnected: { false })
        let (outcome, _) = await client.send(id: UUID(), text: "x", to: URL(string: "http://macbook:7788")!, key: nil)
        XCTAssertEqual(outcome, .delivered(duplicate: false, macMs: nil))
    }
}

/// The plain TCP transport against a real listener on the loopback.
final class SocketTransportTests: XCTestCase {
    private func serve(reply: String, capture: Box) throws -> NWListener {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                capture.request = String(data: data ?? Data(), encoding: .utf8) ?? ""
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        wait(for: [ready], timeout: 5)
        addTeardownBlock { listener.cancel() }
        return listener
    }

    final class Box: @unchecked Sendable {
        var request = ""
    }

    func testPostRoundTrip() async throws {
        let box = Box()
        let body = #"{"ok":true,"status":"inserted","duplicate":false,"ms":2}"#
        let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let listener = try serve(reply: reply, capture: box)
        let port = try XCTUnwrap(listener.port?.rawValue)
        let client = ReceiverClient(addressTransport: SocketTransport(), tailnetConnected: { true })
        let (outcome, _) = await client.send(id: UUID(), text: "Hello, world.", to: URL(string: "http://127.0.0.1:\(port)")!, key: "s3cret")
        XCTAssertEqual(outcome, .delivered(duplicate: false, macMs: 2))
        XCTAssertTrue(box.request.hasPrefix("POST /text HTTP/1.1\r\n"))
        XCTAssertTrue(box.request.contains("X-Dictation-Key: s3cret"))
        XCTAssertTrue(box.request.contains("Hello, world."))
        XCTAssertTrue(box.request.contains("Connection: close"))
    }

    func testRefusalStatusesComeThrough() async throws {
        let listener = try serve(reply: "HTTP/1.1 423 Locked\r\nContent-Length: 0\r\n\r\n", capture: Box())
        let port = try XCTUnwrap(listener.port?.rawValue)
        let client = ReceiverClient(addressTransport: SocketTransport(), tailnetConnected: { true })
        let (outcome, _) = await client.send(id: UUID(), text: "x", to: URL(string: "http://127.0.0.1:\(port)")!, key: nil)
        XCTAssertEqual(outcome, .refused(.locked))
    }

    func testNothingListeningIsUnreachableNotAHang() async {
        let client = ReceiverClient(addressTransport: SocketTransport(timeout: 3), tailnetConnected: { true })
        let (outcome, _) = await client.send(id: UUID(), text: "x", to: URL(string: "http://127.0.0.1:1")!, key: nil)
        guard case .unreachable = outcome else { return XCTFail("\(outcome)") }
    }

    func testResponseParsing() {
        let raw = Data("HTTP/1.1 200 OK\r\nA: b\r\n\r\nbody".utf8)
        let parsed = SocketTransport.parse(raw)
        XCTAssertEqual(parsed?.status, 200)
        XCTAssertEqual(parsed?.body, Data("body".utf8))
        XCTAssertNil(SocketTransport.parse(Data("HTTP/1.1 200".utf8)))
    }
}
