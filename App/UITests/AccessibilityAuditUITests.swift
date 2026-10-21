import XCTest

/// Apple's accessibility audit on every screen a person reaches from the tab bar, and on the first-run screen (AccessibilityAudit.swift).
@MainActor
final class AccessibilityAuditUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = true
    }

    private func launch(onboarded: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-onboarding.done", onboarded ? "YES" : "NO", "-ui-test-isolated", "YES"]
        app.launch()
        return app
    }

    private func auditTab(_ name: String, test: String = #function) throws {
        let app = launch(onboarded: true)
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "the \(name) tab is missing")
        tab.tap()
        try AccessibilityAudit.run(app, in: self, name: test.replacingOccurrences(of: "()", with: ""))
    }

    func testFirstRunScreenPassesTheAccessibilityAudit() throws {
        let app = launch(onboarded: false)
        XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: 10))
        try AccessibilityAudit.run(app, in: self, name: "testFirstRunScreenPassesTheAccessibilityAudit")
    }

    func testDictateTabPassesTheAccessibilityAudit() throws { try auditTab("Dictate") }
    func testSoundsTabPassesTheAccessibilityAudit() throws { try auditTab("Sounds") }
    func testAssistTabPassesTheAccessibilityAudit() throws { try auditTab("Assist") }
    func testComputersTabPassesTheAccessibilityAudit() throws { try auditTab("Computers") }
    func testHelpTabPassesTheAccessibilityAudit() throws { try auditTab("Help") }
}
