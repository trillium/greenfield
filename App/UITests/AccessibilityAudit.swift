import XCTest

/// Apple's accessibility audit with a ratchet: the findings an app had when the audit was added are counted in
/// audit-known-findings.txt (one line each: `test | kind of finding | how many`), and a screen may never have more than that.
/// Shared byte for byte with the sibling project (docs/parity.md); the tests that call it and the list of known findings are the app's own.
/// `make test-ui STRICT=1` ignores the list and fails on every finding.
enum AccessibilityAudit {
    /// The audit words the same problem differently from run to run ("failed" or "nearly passed", "unsupported" or "partially").
    static func kind(of issue: XCUIAccessibilityAuditIssue) -> String {
        let text = issue.compactDescription
        return text.hasPrefix("Dynamic Type") ? "Dynamic Type" : text.hasPrefix("Contrast") ? "Contrast" : text
    }

    static func knownFindings(in test: XCTestCase) -> [String: Int] {
        guard ProcessInfo.processInfo.environment["AUDIT_STRICT"] != "1",
              let url = Bundle(for: type(of: test)).url(forResource: "audit-known-findings", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var counts: [String: Int] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 3, let count = Int(parts[2]) { counts[parts[0...1].joined(separator: " | "), default: 0] += count }
        }
        return counts
    }

    /// Runs the audit on `app`. Every finding is attached to the result (what it is, and which element: scripts/audit-findings.sh
    /// prints them); a finding beyond the known list fails the test.
    @MainActor
    static func run(_ app: XCUIApplication, in test: XCTestCase, name: String) throws {
        var remaining = knownFindings(in: test)
        try app.performAccessibilityAudit { issue in
            let element = issue.element?.debugDescription ?? "no element"
            let key = "\(name) | \(kind(of: issue))"
            let note = XCTAttachment(string: "\(issue.compactDescription) | \(issue.detailedDescription) | \(element)\nkey: \(key)")
            note.name = "AUDIT FINDING"
            note.lifetime = .keepAlways
            test.add(note)
            if let left = remaining[key], left > 0 {
                remaining[key] = left - 1
                return true
            }
            return false
        }
    }
}
