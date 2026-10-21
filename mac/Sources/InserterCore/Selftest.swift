import Foundation

/// What the selftest saw, step by step. nil means the step was never reached.
public struct SelftestObservations {
    public var preflight: [HealthCheck] = []
    public var windowFocused: Bool?
    public var textSend: InserterClient.SendResult?
    public var textArrived: Bool?
    public var returnSend: InserterClient.SendResult?
    public var returnSeen: Bool?
    public var simulated = false

    public init() {}
}

private let installed = InserterDefaults.installedBinary

private func sendFailure(_ id: String, _ title: String, _ r: InserterClient.SendResult) -> HealthCheck {
    switch r.httpStatus {
    case 401:
        return HealthCheck(id, title, .fail, detail: "the daemon refused the request (HTTP 401)",
            why: "The selftest talks to the daemon over loopback, which is always allowed; a 401 means something other than this Mac's own daemon answered, or an older daemon that still requires a key.",
            fix: "Run `greenfield-inserter doctor`; if the daemon is older, update it with `make -C mac install`.")
    case 409:
        return HealthCheck(id, title, .fail, detail: "refused: secure input is on (HTTP 409)",
            why: "A password field or another app is holding secure input, so the daemon will not type.",
            fix: "Click out of any password field or quit the app that holds secure input, then run the selftest again. `greenfield-inserter doctor` shows how to find it.")
    case 423:
        return HealthCheck(id, title, .fail, detail: "refused: the screen is locked (HTTP 423)",
            why: "Input cannot be delivered to a locked screen.",
            fix: "Unlock this Mac and run the selftest again.")
    case 502:
        return HealthCheck(id, title, .fail, detail: "the daemon sent the keys but saw the focused field stay unchanged (HTTP 502)",
            why: "The keys did not reach the window: Accessibility may belong to a different binary, or the window lost focus.",
            fix: "Run `greenfield-inserter doctor`; if Accessibility looks fine, run the selftest again without touching the keyboard.")
    case 503:
        return HealthCheck(id, title, .fail, detail: r.summary,
            why: "Without Accessibility (or a key) the daemon cannot insert anything.",
            fix: "Run `greenfield-inserter doctor` and follow its fix for Accessibility or the key.")
    case nil:
        return HealthCheck(id, title, .fail, detail: r.summary,
            why: "The daemon stopped answering on loopback.",
            fix: "Run `greenfield-inserter doctor`.")
    default:
        return HealthCheck(id, title, .fail, detail: r.summary,
            why: "The daemon did not accept the request.",
            fix: "Run `greenfield-inserter doctor`; its log is ~/.config/greenfield-inserter/inserter.log.")
    }
}

public func evaluateSelftest(_ o: SelftestObservations) -> [HealthCheck] {
    let titles: [(String, String)] = [
        ("preflight", "Daemon healthy"), ("window", "Test window focused"),
        ("text-send", "Daemon accepted a test string"), ("text-arrival", "Test string arrived in the field"),
        ("return-send", "Daemon accepted a Return key press"), ("return-seen", "Return key press received"),
    ]
    var out: [HealthCheck] = []
    func skipRest(from index: Int) {
        for (id, title) in titles[index...] { out.append(HealthCheck(id, title, .skip, detail: "not run: an earlier step failed")) }
    }
    func step(_ index: Int, _ outcome: HealthCheck) -> Bool {
        out.append(outcome)
        if outcome.status == .fail { skipRest(from: index + 1) }
        return outcome.status != .fail
    }

    if o.simulated {
        out.append(HealthCheck("preflight", "Daemon healthy", .skip, detail: "simulated run: the daemon is bypassed"))
    } else {
        if let bad = o.preflight.first(where: { $0.status == .fail }) {
            if !step(0, HealthCheck("preflight", "Daemon healthy: \(bad.title)", .fail, detail: bad.detail, why: bad.why, fix: bad.fix)) { return out }
        } else {
            out.append(HealthCheck("preflight", "Daemon healthy", .pass, detail: "all \(o.preflight.count) health checks pass"))
        }
    }

    guard let focused = o.windowFocused else { skipRest(from: 1); return out }
    if !step(1, focused
        ? HealthCheck("window", titles[1].1, .pass, detail: "the selftest window has the keyboard focus")
        : HealthCheck("window", titles[1].1, .fail, detail: "the window could not take the keyboard focus",
            why: "Typed input goes to whatever app has focus; without focus there is nothing to measure.",
            fix: "Make sure someone is logged in and the screen is unlocked, close any full-screen app or dialog that grabs focus, and run the selftest again.")) { return out }

    if o.simulated {
        out.append(HealthCheck("text-send", titles[2].1, .skip, detail: "simulated run"))
    } else if let r = o.textSend {
        if !step(2, r.inserted ? HealthCheck("text-send", titles[2].1, .pass, detail: r.summary) : sendFailure("text-send", titles[2].1, r)) { return out }
    } else { skipRest(from: 2); return out }

    guard let arrived = o.textArrived else { skipRest(from: 3); return out }
    if !step(3, arrived
        ? HealthCheck("text-arrival", titles[3].1, .pass, detail: o.simulated ? "simulated" : "read back from the field")
        : HealthCheck("text-arrival", titles[3].1, .fail, detail: "the daemon said it inserted the text, but the field stayed empty",
            why: "The paste never reached this window. Usual causes: the daemon's Accessibility approval belongs to a different file than the one running (for example after a reinstall), the window lost focus, or the daemon is not running in the logged-in desktop session.",
            fix: "Run `greenfield-inserter doctor`. If Accessibility is the problem: run `\(installed) permissions`, switch greenfield-inserter off and on again under Privacy & Security > Accessibility, then re-run the selftest.")) { return out }

    if o.simulated {
        out.append(HealthCheck("return-send", titles[4].1, .skip, detail: "simulated run"))
    } else if let r = o.returnSend {
        if !step(4, r.inserted ? HealthCheck("return-send", titles[4].1, .pass, detail: r.summary) : sendFailure("return-send", titles[4].1, r)) { return out }
    } else { skipRest(from: 4); return out }

    let seen = o.returnSeen ?? false
    _ = step(5, seen
        ? HealthCheck("return-seen", titles[5].1, .pass, detail: o.simulated ? "simulated" : "the field received the Return key")
        : HealthCheck("return-seen", titles[5].1, .fail, detail: "the text arrived but the Return key press did not",
            why: "Submitting (Return) uses typed key events rather than a paste, so it can fail even when pasting works.",
            fix: "Run the selftest again; if it repeats, run `greenfield-inserter doctor` and re-approve Accessibility for \(installed)."))
    return out
}

public func selftestPassed(_ checks: [HealthCheck]) -> Bool {
    !checks.contains { $0.status == .fail } && checks.contains { $0.id == "return-seen" && $0.status == .pass }
}

public func formatSelftest(label: String, checks: [HealthCheck], simulated: Bool) -> String {
    let failed = checks.first { $0.status == .fail }
    var head = "selftest on \(label): "
    if let f = failed { head += "FAIL at \"\(f.title)\"" } else if selftestPassed(checks) { head += "PASS" } else { head += "INCOMPLETE" }
    if simulated { head += " (SIMULATED: the daemon was bypassed, so this proves nothing about delivery)" }
    var lines = [head]
    for c in checks {
        switch c.status {
        case .pass: lines.append("  ok    \(c.title) - \(c.detail)")
        case .skip: lines.append("  skip  \(c.title) - \(c.detail)")
        default: lines.append("  FAIL  \(c.title)")
        }
    }
    if let f = failed {
        lines += ["", "  wrong: \(f.detail)", "  why:   \(f.why)", "  fix:   \(f.fix)"]
    }
    return lines.joined(separator: "\n")
}


/// Writes what a live selftest proved to the delivery ledger the daemon reports from. Only outcomes that
/// say something about delivery count; a window that could not get focus proves nothing either way.
public func recordSelftestEvidence(_ checks: [HealthCheck], ledger: DeliveryRecord) {
    if selftestPassed(checks) { ledger.recordSuccess(source: "selftest"); return }
    guard let failed = checks.first(where: { $0.status == .fail }) else { return }
    if failed.id == "window" { return }
    if failed.id == "preflight", !["accessibility granted", "daemon running"].contains(where: { failed.title.lowercased().contains($0) }) { return }
    ledger.recordFailure(source: "selftest", detail: "\(failed.title): \(failed.detail)")
}
