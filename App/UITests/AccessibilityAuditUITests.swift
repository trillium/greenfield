import XCTest

/// Apple's accessibility audit run on every screen a person reaches from the tab bar, and on the first-run screen.
/// A finding fails the test; nothing is filtered out.
@MainActor
final class AccessibilityAuditUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = true
    }

    private func launch(onboarded: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-onboarding.done", onboarded ? "YES" : "NO"]
        app.launch()
        return app
    }

    /// Findings that were already there when the audit was added, one line each in audit-known-findings.txt:
    /// `test | kind of finding (Contrast, Dynamic Type, Text clipped) | how many`. A finding beyond that list fails the test, so
    /// the screens can only get better. `make test-ui STRICT=1` ignores the list and fails on every finding.
    private lazy var known: [String: Int] = {
        guard ProcessInfo.processInfo.environment["AUDIT_STRICT"] != "1",
              let url = Bundle(for: Self.self).url(forResource: "audit-known-findings", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var counts: [String: Int] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 3, let n = Int(parts[2]) { counts[parts[0...1].joined(separator: " | "), default: 0] += n }
        }
        return counts
    }()

    /// The audit words the same problem differently from run to run ("failed" or "nearly passed", "unsupported" or "partially").
    private static func kind(of issue: XCUIAccessibilityAuditIssue) -> String {
        let text = issue.compactDescription
        return text.hasPrefix("Dynamic Type") ? "Dynamic Type" : text.hasPrefix("Contrast") ? "Contrast" : text
    }

    /// Runs the audit. Every finding is attached to the result (what it is, and which element: scripts/audit-findings.sh prints
    /// them). A finding that is not in the known list fails the test.
    private func audit(_ app: XCUIApplication, test: String = #function) throws {
        var remaining = known
        try app.performAccessibilityAudit { [self] issue in
            let element = issue.element?.debugDescription ?? "no element"
            let name = test.replacingOccurrences(of: "()", with: "")
            let key = "\(name) | \(Self.kind(of: issue))"
            let note = XCTAttachment(string: "\(issue.compactDescription) | \(issue.detailedDescription) | \(element)\nkey: \(key)")
            note.name = "AUDIT FINDING"
            note.lifetime = .keepAlways
            add(note)
            if let left = remaining[key], left > 0 {
                remaining[key] = left - 1
                return true
            }
            return false
        }
    }

    private func auditTab(_ name: String, test: String = #function) throws {
        let app = launch(onboarded: true)
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "the \(name) tab is missing")
        tab.tap()
        try audit(app, test: test)
    }

    func testFirstRunScreenPassesTheAccessibilityAudit() throws {
        let app = launch(onboarded: false)
        XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: 10))
        try audit(app)
    }

    func testDictateTabPassesTheAccessibilityAudit() throws { try auditTab("Dictate") }
    func testSoundsTabPassesTheAccessibilityAudit() throws { try auditTab("Sounds") }
    func testAssistTabPassesTheAccessibilityAudit() throws { try auditTab("Assist") }
    func testComputersTabPassesTheAccessibilityAudit() throws { try auditTab("Computers") }
    func testHelpTabPassesTheAccessibilityAudit() throws { try auditTab("Help") }
}
