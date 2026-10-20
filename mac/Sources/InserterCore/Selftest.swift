import Foundation

/// What the selftest saw, step by step. nil means the step was never reached.
public struct SelftestObservations {
    public var preflight: [HealthCheck] = []
    public var credentialProblem: String?
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
        return HealthCheck(id, title, .fail, detail: "the daemon rejected the selftest's credential",
            why: "The selftest authenticates with the throwaway token the daemon writes at start-up, or with the key you passed on stdin. This daemon did not accept it: the key may be wrong, or an older daemon may not honour the token. " + keyFileNote,
            fix: "Update the daemon once with `make -C mac install` (then re-approve Accessibility if macOS asks), or run `greenfield-inserter selftest --key-stdin` and give it this Mac's key on stdin.")
    case 409:
        return HealthCheck(id, title, .fail, detail: "refused: secure input is on (HTTP 409)",
            why: "A password field or another app is holding secure input, so the daemon will not type.",
            fix: "Click out of any password field or quit the app that holds secure input, then run the selftest again. `greenfield-inserter doctor` shows how to find it.")
    case 423:
        return HealthCheck(id, title, .fail, detail: "refused: the screen is locked (HTTP 423)",
            why: "Input cannot be delivered to a locked screen.",
            fix: "Unlock this Mac and run the selftest again.")
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
        ("preflight", "Daemon healthy"), ("credential", "Credential for the daemon"), ("window", "Test window focused"),
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
        out.append(HealthCheck("credential", "Credential for the daemon", .skip, detail: "simulated run"))
    } else {
        if let bad = o.preflight.first(where: { $0.status == .fail }) {
            if !step(0, HealthCheck("preflight", "Daemon healthy: \(bad.title)", .fail, detail: bad.detail, why: bad.why, fix: bad.fix)) { return out }
        } else {
            out.append(HealthCheck("preflight", "Daemon healthy", .pass, detail: "all \(o.preflight.count) health checks pass"))
        }
        if let problem = o.credentialProblem {
            if !step(1, HealthCheck("credential", "Credential for the daemon", .fail, detail: problem,
                why: "The selftest needs a way to authenticate to the daemon without showing a key.",
                fix: "Update the daemon once with `make -C mac install` so it writes a local token, or pass this Mac's key on stdin: `greenfield-inserter selftest --key-stdin`.")) { return out }
        } else {
            out.append(HealthCheck("credential", "Credential for the daemon", .pass, detail: "found"))
        }
    }

    guard let focused = o.windowFocused else { skipRest(from: 2); return out }
    if !step(2, focused
        ? HealthCheck("window", titles[2].1, .pass, detail: "the selftest window has the keyboard focus")
        : HealthCheck("window", titles[2].1, .fail, detail: "the window could not take the keyboard focus",
            why: "Typed input goes to whatever app has focus; without focus there is nothing to measure.",
            fix: "Make sure someone is logged in and the screen is unlocked, close any full-screen app or dialog that grabs focus, and run the selftest again.")) { return out }

    if o.simulated {
        out.append(HealthCheck("text-send", titles[3].1, .skip, detail: "simulated run"))
    } else if let r = o.textSend {
        if !step(3, r.inserted ? HealthCheck("text-send", titles[3].1, .pass, detail: r.summary) : sendFailure("text-send", titles[3].1, r)) { return out }
    } else { skipRest(from: 3); return out }

    guard let arrived = o.textArrived else { skipRest(from: 4); return out }
    if !step(4, arrived
        ? HealthCheck("text-arrival", titles[4].1, .pass, detail: o.simulated ? "simulated" : "read back from the field")
        : HealthCheck("text-arrival", titles[4].1, .fail, detail: "the daemon said it inserted the text, but the field stayed empty",
            why: "The paste never reached this window. Usual causes: the daemon's Accessibility approval belongs to a different file than the one running (for example after a reinstall), the window lost focus, or the daemon is not running in the logged-in desktop session.",
            fix: "Run `greenfield-inserter doctor`. If Accessibility is the problem: run `\(installed) permissions`, switch greenfield-inserter off and on again under Privacy & Security > Accessibility, then re-run the selftest.")) { return out }

    if o.simulated {
        out.append(HealthCheck("return-send", titles[5].1, .skip, detail: "simulated run"))
    } else if let r = o.returnSend {
        if !step(5, r.inserted ? HealthCheck("return-send", titles[5].1, .pass, detail: r.summary) : sendFailure("return-send", titles[5].1, r)) { return out }
    } else { skipRest(from: 5); return out }

    let seen = o.returnSeen ?? false
    _ = step(6, seen
        ? HealthCheck("return-seen", titles[6].1, .pass, detail: o.simulated ? "simulated" : "the field received the Return key")
        : HealthCheck("return-seen", titles[6].1, .fail, detail: "the text arrived but the Return key press did not",
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
