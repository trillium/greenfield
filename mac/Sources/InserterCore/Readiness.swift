import Foundation

/// "Am I ready?": either everything that matters is fine, or exactly one next step in plain words.
public enum Readiness: Equatable {
    case ready(notes: [String])
    case next(step: String)

    public var isReady: Bool { if case .ready = self { return true }; return false }
}

/// The setup checklist the installer shows live: each row is one thing the captain waits for.
public struct SetupRow: Equatable {
    public enum State: Equatable { case done, waiting, pending }
    public var title: String
    public var state: State
}

/// Checks in the order a person would fix them: the first failing one is THE next step.
private let priority = ["binary", "plist", "launchd", "daemon", "tailnet", "launchd-throttle", "running-build",
                        "auth", "listening", "accessibility", "can-insert"]
/// Passing conditions of a healthy daemon: reported as notes, never as the thing to do next.
private let transient = ["unlocked", "secure-input"]

private func plainStep(_ c: HealthCheck, bin: String) -> String {
    switch c.id {
    case "binary", "plist":
        return "Install it: run `mac/install.sh` from the repository (it installs the signed build and starts it)."
    case "launchd":
        return "Start it: run `\(bin) restart` (the launchd agent is installed but not running)."
    case "daemon":
        return "Start it: run `\(bin) restart`; if that says it is not installed, run `mac/install.sh`."
    case "tailnet":
        return "Open Tailscale and sign in, then run this again: this Mac has no tailnet address yet."
    case "launchd-throttle":
        return "It keeps stopping: run `\(bin) doctor` and read the log it points to."
    case "running-build":
        return "Restart it so the new version is the one running: run `\(bin) restart`."
    case "auth":
        return "Open Tailscale and make sure you are signed in: the daemon cannot ask it who is calling."
    case "listening":
        return "Wait a few seconds for Tailscale to connect; if this stays, run `\(bin) restart`."
    case "accessibility":
        if c.detail.contains("granted after the daemon started") {
            return "Almost there: the daemon restarts itself in a moment to use the approval; if it does not, run `\(bin) restart`."
        }
        return "Switch on \"greenfield-inserter\" in System Settings > Privacy & Security > Accessibility, then enter your password (if it is not listed, press + and add \(bin))."
    case "can-insert":
        if c.detail.contains("did not arrive") {
            return "A test text did not arrive: run `\(bin) doctor` and follow its fix."
        }
        return "Prove it types into apps, once: run `\(bin) selftest` (a small window opens for a few seconds; do not type)."
    default:
        return c.fix.isEmpty ? c.detail : c.fix
    }
}

public func readiness(checks: [HealthCheck], bin: String = InserterDefaults.installedBinary) -> Readiness {
    let failing = checks.filter { $0.status == .fail }
    for id in priority {
        if let c = failing.first(where: { $0.id == id }) { return .next(step: plainStep(c, bin: bin)) }
    }
    // anything else that failed and is not merely transient
    if let other = failing.first(where: { !transient.contains($0.id) && !priority.contains($0.id) }) {
        return .next(step: plainStep(other, bin: bin))
    }
    var notes: [String] = []
    if failing.contains(where: { $0.id == "unlocked" }) { notes.append("the screen is locked right now; text waits until you unlock it") }
    if failing.contains(where: { $0.id == "secure-input" }) { notes.append("a password field has the keyboard right now; text waits until you leave it") }
    if let app = checks.first(where: { $0.id == "app-compatible" && $0.status == .warn }) { notes.append(app.detail) }
    return .ready(notes: notes)
}

public func setupRows(checks: [HealthCheck]) -> [SetupRow] {
    let groups: [(String, [String])] = [
        ("Greenfield is installed and running", ["binary", "plist", "launchd", "daemon", "running-build", "launchd-throttle"]),
        ("Connected to your tailnet", ["tailnet", "auth", "listening"]),
        ("Accessibility approved", ["accessibility"]),
        ("Text really reaches apps", ["can-insert"]),
    ]
    var rows: [SetupRow] = []
    var blocked = false
    for (title, ids) in groups {
        let failed = checks.contains { ids.contains($0.id) && $0.status == .fail }
        if blocked { rows.append(SetupRow(title: title, state: .pending)) }
        else if failed { rows.append(SetupRow(title: title, state: .waiting)); blocked = true }
        else { rows.append(SetupRow(title: title, state: .done)) }
    }
    return rows
}

/// Draws the checklist; the caller redraws in place on a terminal.
public func renderSetup(rows: [SetupRow], headline: String) -> String {
    var lines = [headline, ""]
    for r in rows {
        let mark: String
        switch r.state { case .done: mark = "✓"; case .waiting: mark = "…"; case .pending: mark = "·" }
        lines.append("  \(mark) \(r.title)")
    }
    return lines.joined(separator: "\n")
}
