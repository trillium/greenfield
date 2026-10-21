import XCTest

/// The redactor and the support-file builder. This file and the two sources it tests are shared byte for byte with the sibling
/// project (docs/parity.md); the test target compiles them itself (project.yml), so it imports no app module.
final class LogRedactorTests: XCTestCase {
    private let redactor = LogRedactor()
    // Built at run time so no secret scanner mistakes a test canary for a real credential.
    private let canary = "canary-" + String(repeating: "7f3a9c", count: 7)

    func testHeadersFieldsAndBearerTokensAreMasked() {
        let leaks = ["X-Example-Key: \(canary)", "authorization=Bearer \(canary)", "Authorization: Basic \(canary)",
                     "token=\(canary)", "{\"password\":\"\(canary)\"}", "key=\(canary)", "api_key: \(canary)"]
        for leak in leaks {
            let out = redactor.redact("2026-10-20T10:00:00Z got \(leak) done")
            XCTAssertFalse(out.contains(canary), "\(leak) -> \(out)")
        }
    }

    func testKnownTokenShapesAreMasked() {
        let samples = ["tskey-auth-kABCDEF123456-XYZ", "sk-" + String(repeating: "a1", count: 12),
                       "ghp_" + String(repeating: "A1", count: 14), "AKIA" + String(repeating: "B2", count: 8),
                       "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc123",
                       "http://user:" + canary + "@host/path", String(repeating: "0123456789abcdef", count: 4)]
        for sample in samples {
            let out = redactor.redact("line \(sample) end")
            XCTAssertTrue(out.contains(LogRedactor.mask), "\(sample) -> \(out)")
            XCTAssertFalse(out.contains(sample), "\(sample) -> \(out)")
        }
    }

    func testIdsTimingsAndPlainErrorTextSurvive() {
        let line = "2026-10-20T10:00:00Z [send] sent to Mac mini in 212 ms, 41 characters id=6F1C2E0A-5B7D-4E8B-9C41-0A2D3B4C5D6E"
        XCTAssertEqual(redactor.redact(line), line)
        let error = "could not reach macbook: The request timed out. (code -1001)"
        XCTAssertEqual(redactor.redact(error), error)
        XCTAssertEqual(redactor.redact("key_configured=true inserted_count=3"), "key_configured=true inserted_count=3")
    }

    func testUrlCredentialsQueriesLaunchArgumentsAndKnownSecretsAreMasked() {
        let url = LogRedactor.clean("bad url https://admin:hunter2@host.example.ts.net:1234/path?token=abc#frag failed")
        XCTAssertEqual(url, "bad url https://\(LogRedactor.mask)@host.example.ts.net:1234/path failed")
        let plain = "http://100.64.0.1:1234/path ok"
        XCTAssertEqual(LogRedactor.clean(plain), plain)
        let launch = LogRedactor.clean("launch -live-key abc123def456 -live-files u01")
        XCTAssertEqual(launch, "launch -live-key \(LogRedactor.mask) -live-files u01")
        let known = "plain-value-without-a-pattern"
        XCTAssertEqual(LogRedactor.clean("sent \(known) now", secrets: [known]), "sent \(LogRedactor.mask) now")
        XCTAssertEqual(LogRedactor.clean("\"page down\" in 412 ms"), "\"page down\" in 412 ms")
    }

    func testOneShortLinePerEntry() {
        XCTAssertEqual(LogRedactor.clean("two\nlines"), "two / lines")
        let out = redactor.redact("a\r\nb\tc" + String(repeating: "z ", count: 400))
        XCTAssertFalse(out.contains("\n") || out.contains("\r") || out.contains("\t"))
        XCTAssertLessThanOrEqual(out.count, LogRedactor.maxLineLength)
    }

    func testTheBundleRedactsEveryLineAndKeepsTheNewestWhenFull() {
        let long = String(repeating: "ab ", count: 126)
        let lines = (0..<2000).map { "2026-10-20T10:00:00Z entry \($0) \(long)" } + ["2026-10-20T10:00:01Z token=\(canary)"]
        let text = LogBundle(header: ["app: v1 (2)"], sections: [.init(title: "events", lines: lines)]).render()
        XCTAssertLessThanOrEqual(text.utf8.count, LogBundle.maxBytes)
        XCTAssertFalse(text.contains(canary))
        XCTAssertTrue(text.contains("token=" + LogRedactor.mask))
        XCTAssertTrue(text.contains("entry 1999"), "the newest lines are the ones kept")
        XCTAssertFalse(text.contains("entry 0 "), "the oldest lines go first")
        XCTAssertTrue(text.contains("older lines left out"))
        XCTAssertTrue(text.hasPrefix("# app: v1 (2)\n"))
    }
}
