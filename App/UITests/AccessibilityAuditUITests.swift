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

    /// Runs the audit. Every finding is attached to the result (what it is, and which element: scripts/audit-findings.sh prints them)
    /// and then still fails the test; nothing is filtered out.
    private func audit(_ app: XCUIApplication) throws {
        try app.performAccessibilityAudit { [self] issue in
            let element = issue.element?.debugDescription ?? "no element"
            let note = XCTAttachment(string: "\(issue.compactDescription) | \(issue.detailedDescription) | \(element)")
            note.name = "AUDIT FINDING"
            note.lifetime = .keepAlways
            add(note)
            return false
        }
    }

    private func auditTab(_ name: String) throws {
        let app = launch(onboarded: true)
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "the \(name) tab is missing")
        tab.tap()
        try audit(app)
    }

    func testFirstRunScreenPassesTheAccessibilityAudit() throws {
        let app = launch(onboarded: false)
        XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: 10))
        try audit(app)
    }

    func testDictateTabPassesTheAccessibilityAudit() throws { try auditTab("Dictate") }
    func testSoundsTabPassesTheAccessibilityAudit() throws { try auditTab("Sounds") }
    func testComputersTabPassesTheAccessibilityAudit() throws { try auditTab("Computers") }
    func testHelpTabPassesTheAccessibilityAudit() throws { try auditTab("Help") }
}
