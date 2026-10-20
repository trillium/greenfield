import XCTest
@testable import InserterCore

final class HTTPParserTests: XCTestCase {
    func parse(_ s: String) -> HTTPParseResult { HTTPParser.parse(Data(s.utf8)) }

    func testParsesPostWithBody() {
        let raw = "POST /text?x=1 HTTP/1.1\r\nHost: a\r\nX-Dictation-Key: k\r\nContent-Length: 5\r\n\r\nhello"
        guard case .complete(let r) = parse(raw) else { return XCTFail("not complete") }
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/text")
        XCTAssertEqual(r.headers["x-dictation-key"], "k")
        XCTAssertEqual(String(data: r.body, encoding: .utf8), "hello")
    }

    func testWaitsForRestOfBody() {
        XCTAssertEqual(parse("POST /text HTTP/1.1\r\nContent-Length: 5\r\n\r\nhel"), .incomplete)
        XCTAssertEqual(parse("GET /status HTTP/1.1\r\nHost: a"), .incomplete)
    }

    func testGetNeedsNoLength() {
        guard case .complete(let r) = parse("GET /status HTTP/1.1\r\n\r\n") else { return XCTFail() }
        XCTAssertEqual(r.path, "/status")
    }

    func testRejections() {
        func status(_ s: String) -> Int? { if case .invalid(let r) = parse(s) { return r.status }; return nil }
        XCTAssertEqual(status("POST /text HTTP/1.1\r\n\r\n"), 411)
        XCTAssertEqual(status("POST /text HTTP/1.1\r\nContent-Length: x\r\n\r\n"), 400)
        XCTAssertEqual(status("POST /text HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n"), 413)
        XCTAssertEqual(status("POST /text HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"), 501)
        XCTAssertEqual(status("garbage\r\n\r\n"), 400)
        XCTAssertEqual(status(String(repeating: "a", count: HTTPParser.maxHeaderBytes + 10)), 431)
    }

    func testResponseSerialization() {
        let text = String(data: HTTPResponse.json(423, ["ok": false]).serialized(), encoding: .utf8)!
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 423 Locked\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 12\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"ok\":false}"))
    }
}
