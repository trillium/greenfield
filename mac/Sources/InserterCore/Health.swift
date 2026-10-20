import Foundation

public enum InserterDefaults {
    public static let port = 47821
    public static let launchdLabel = "local.greenfield.inserter"
    public static var installedBinary: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.local/share/greenfield-inserter/greenfield-inserter"
    }
}

/// Said wherever a key problem shows up, because pasting the key file's contents as the key gets a 401.
public let keyFileNote = "The key file stores only a hash of the key. The real key was shown once at `key create` and is kept by the Mac that ran `macs add` (`greenfield-inserter macs show-key ALIAS` there); do not use the file's contents as the key."

/// One yes/no fact about the setup. `why` and `fix` are only shown by `doctor`.
public struct HealthCheck: Equatable {
    public enum Status: Equatable { case pass, fail, warn, skip }
    public var id: String
    public var title: String
    public var status: Status
    public var detail: String
    public var why: String
    public var fix: String

    public init(_ id: String, _ title: String, _ status: Status, detail: String = "", why: String = "", fix: String = "") {
        self.id = id; self.title = title; self.status = status; self.detail = detail; self.why = why; self.fix = fix
    }
}

/// What a running daemon says about itself (from /health on this Mac, or /status from elsewhere).
public struct DaemonSnapshot: Equatable {
    public var name: String
    public var version: String
    public var listen: [String]
    public var accessibility: Bool
    public var screenLocked: Bool
    public var secureInput: Bool
    public var keyConfigured: Bool
    public var executable: String?
    public var pid: Int?

    public static func parse(_ body: Data) -> DaemonSnapshot? {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let version = o["version"] as? String else { return nil }
        return DaemonSnapshot(
            name: o["name"] as? String ?? "?", version: version, listen: o["listen"] as? [String] ?? [],
            accessibility: o["accessibility"] as? Bool ?? false, screenLocked: o["screen_locked"] as? Bool ?? false,
            secureInput: o["secure_input"] as? Bool ?? false,
            // /status only answers when the key matched, so a key must exist.
            keyConfigured: o["key_configured"] as? Bool ?? true,
            executable: (o["executable"] as? String).flatMap { $0.isEmpty ? nil : $0 }, pid: o["pid"] as? Int)
    }
}

public enum SnapshotOutcome: Equatable {
    case ok(DaemonSnapshot)
    case unreachable(String)
    case unauthorized
    case keyNotSet
    case forbidden
    case unexpected(Int)
}

/// Where a snapshot was taken, which changes how problems and fixes are worded.
public enum HealthSubject: Equatable {
    case local(port: Int)
    case remote(alias: String, host: String, port: Int)

    var daemonBinary: String { InserterDefaults.installedBinary }
}

// MARK: - snapshot checks (shared by health and doctor, local and remote)

public func snapshotChecks(_ outcome: SnapshotOutcome, subject: HealthSubject, localVersion: String) -> [HealthCheck] {
    let remote: Bool
    let address: String
    let alias: String
    switch subject {
    case .local(let port): remote = false; address = "127.0.0.1:\(port)"; alias = ""
    case .remote(let a, let host, let port): remote = true; address = "\(host):\(port)"; alias = a
    }
    let onThatMac = remote ? "On that Mac" : "On this Mac"
    let bin = InserterDefaults.installedBinary
    var checks: [HealthCheck] = []

    // 1. daemon running / reachable
    switch outcome {
    case .unreachable(let reason):
        checks.append(HealthCheck("daemon", remote ? "Daemon reachable" : "Daemon running", .fail,
            detail: "no answer from \(address) (\(reason))",
            why: remote
                ? "Text sent from here or from the phone cannot reach that Mac: its daemon is stopped, the Mac is asleep or off, or Tailscale is disconnected on either side."
                : "Nothing on this Mac is accepting text, so everything the phone sends is lost.",
            fix: remote
                ? "Run `tailscale status` here to see if that Mac is online, then on that Mac: `\(bin) doctor` (over ssh if you can)."
                : "If it is installed: `launchctl kickstart -k gui/$(id -u)/\(InserterDefaults.launchdLabel)`. If not: `make -C mac install` from the repo."))
        return checks + ["listening", "key", "accessibility", "unlocked", "secure-input", "version"].map {
            HealthCheck($0, titleFor($0), .skip, detail: "not checked: daemon not reachable")
        }
    case .forbidden:
        checks.append(HealthCheck("daemon", "Daemon running", .fail, detail: "answered 403 on /health",
            why: "The health request did not arrive from this Mac's loopback address.",
            fix: "Run health on the Mac itself, or use `macs health` from another Mac."))
        return checks
    case .unauthorized, .keyNotSet, .unexpected, .ok:
        var detail = "answering on \(address)"
        if case .ok(let s) = outcome, let pid = s.pid { detail += " (pid \(pid))" }
        checks.append(HealthCheck("daemon", remote ? "Daemon reachable" : "Daemon running", .pass, detail: detail))
    }

    // 2.. everything else needs a parsed snapshot, or an auth problem
    switch outcome {
    case .unauthorized:
        checks.append(HealthCheck("key", "Key accepted", .fail, detail: "that Mac rejected the saved key",
            why: "Without the matching key every request is refused (HTTP 401), so nothing can be inserted. " + keyFileNote,
            fix: "Re-enter it here: `greenfield-inserter macs add \(alias) <host>` (key from `macs show-key` on the Mac that holds it). If lost: on that Mac `\(bin) key create --force`, then `macs add` again, and update the phone."))
        return checks + ["listening", "accessibility", "unlocked", "secure-input", "version"].map {
            HealthCheck($0, titleFor($0), .skip, detail: "not checked: key not accepted")
        }
    case .keyNotSet:
        checks.append(HealthCheck("key", "Key set", .fail, detail: "no key configured on that Mac",
            why: "The daemon refuses every request until a key exists.",
            fix: "\(onThatMac): `\(bin) key create` (shows the key once), then `greenfield-inserter macs add \(alias) \(subjectHost(subject))` here and enter it in the phone."))
        return checks + ["listening", "accessibility", "unlocked", "secure-input", "version"].map {
            HealthCheck($0, titleFor($0), .skip, detail: "not checked: no key")
        }
    case .unexpected(let code):
        let older = !remote && code == 404
        checks.append(HealthCheck("key", "Key set", .fail,
            detail: older ? "daemon answered 404 on /health: it is an older version" : "unexpected HTTP \(code)",
            why: older ? "The running daemon predates health checks, so its key, Accessibility and lock state cannot be read."
                       : "Something other than greenfield-inserter may be answering on that port, or the daemon is a different version.",
            fix: older ? "Update it: `make -C mac install` from the repo (then re-approve Accessibility if macOS asks)."
                       : "\(onThatMac): `\(bin) doctor`."))
        return checks
    case .ok(let s):
        return checks + okChecks(s, subject: subject, remote: remote, onThatMac: onThatMac, bin: bin, localVersion: localVersion)
    default:
        return checks
    }
}

private func subjectHost(_ s: HealthSubject) -> String {
    if case .remote(_, let host, _) = s { return host }
    return "<host>"
}

private func titleFor(_ id: String) -> String {
    switch id {
    case "listening": return "Listening on tailnet and loopback only"
    case "key": return "Key set"
    case "accessibility": return "Accessibility granted"
    case "unlocked": return "Screen not locked"
    case "secure-input": return "No secure input"
    case "version": return "Version"
    default: return id
    }
}

private func okChecks(_ s: DaemonSnapshot, subject: HealthSubject, remote: Bool, onThatMac: String,
                      bin: String, localVersion: String) -> [HealthCheck] {
    var out: [HealthCheck] = []
    let hasLoopback = s.listen.contains { $0.hasPrefix("127.") }
    let hasTailnet = s.listen.contains { isTailnetOrLoopback($0) && !$0.hasPrefix("127.") }
    let outside = s.listen.filter { !isTailnetOrLoopback($0) }
    if !outside.isEmpty {
        out.append(HealthCheck("listening", titleFor("listening"), .fail, detail: "also listening on \(outside.joined(separator: ", "))",
            why: "Plain HTTP is only acceptable because the daemon is reachable by tailnet members alone; another interface widens that.",
            fix: "\(onThatMac): relaunch without `--bind` so it serves the tailnet address and loopback only: `launchctl kickstart -k gui/$(id -u)/\(InserterDefaults.launchdLabel)`."))
    } else if hasLoopback && hasTailnet {
        out.append(HealthCheck("listening", titleFor("listening"), .pass, detail: s.listen.joined(separator: ", ")))
    } else {
        let missing = [hasTailnet ? nil : "tailnet address", hasLoopback ? nil : "loopback"].compactMap { $0 }.joined(separator: " and ")
        out.append(HealthCheck("listening", titleFor("listening"), .fail,
            detail: "not listening on \(missing) (serving: \(s.listen.isEmpty ? "nothing" : s.listen.joined(separator: ", ")))",
            why: hasTailnet ? "Local tools cannot reach the daemon." : "The phone and other Macs cannot reach the daemon over the tailnet.",
            fix: "\(onThatMac): make sure Tailscale is connected (`tailscale status`); the daemon rebinds by itself within about 10 seconds. If it does not: `launchctl kickstart -k gui/$(id -u)/\(InserterDefaults.launchdLabel)`."))
    }
    out.append(s.keyConfigured
        ? HealthCheck("key", titleFor("key"), .pass, detail: remote ? "key accepted" : "key file present")
        : HealthCheck("key", titleFor("key"), .fail, detail: "no key configured",
            why: "The daemon refuses every request until a key exists.",
            fix: "`\(bin) key create` (shows the key once; enter it in the phone, then `greenfield-inserter macs add <alias> <host>` on the Mac you check from)."))
    out.append(s.accessibility
        ? HealthCheck("accessibility", titleFor("accessibility"), .pass, detail: "granted")
        : HealthCheck("accessibility", titleFor("accessibility"), .fail, detail: "not granted to the running daemon",
            why: "macOS silently drops the paste and key events of a program without Accessibility, so nothing would be inserted (the daemon answers 503).",
            fix: "\(onThatMac): run `\(bin) permissions`, press \"Open System Settings\" in the prompt, and switch on greenfield-inserter under Privacy & Security > Accessibility (add `\(bin)` with + if it is not listed). The grant belongs to that exact file, so redo it after a reinstall."))
    out.append(!s.screenLocked
        ? HealthCheck("unlocked", titleFor("unlocked"), .pass, detail: "unlocked")
        : HealthCheck("unlocked", titleFor("unlocked"), .fail, detail: "the screen is locked",
            why: "Input cannot be delivered to a locked screen; the daemon refuses text with HTTP 423 until it is unlocked.",
            fix: "Unlock \(remote ? "that Mac" : "this Mac") (touch the keyboard and enter the password or use Touch ID)."))
    out.append(!s.secureInput
        ? HealthCheck("secure-input", titleFor("secure-input"), .pass, detail: "off")
        : HealthCheck("secure-input", titleFor("secure-input"), .fail, detail: "secure input is on",
            why: "A password field (or an app that left secure input on) is capturing the keyboard; the daemon refuses text with HTTP 409 so a password is never typed into the wrong place.",
            fix: "\(onThatMac): click out of the password field or quit the app that holds it; to find it: `ioreg -l -w 0 | grep kCGSSessionSecureInputPID`, then `ps -p <that pid>`."))
    var version = HealthCheck("version", titleFor("version"), .pass, detail: s.version)
    if remote && s.version != localVersion {
        version = HealthCheck("version", titleFor("version"), .warn, detail: "\(s.version) there, \(localVersion) here",
            why: "Different versions may not support the same requests or checks.",
            fix: "Copy the repo's mac/ folder to that Mac and run `make install` there.")
    }
    out.append(version)
    return out
}

// MARK: - host checks (doctor on the Mac itself)

public struct HostFacts: Equatable {
    public var tailnetIPv4: String?
    public var plistPath: String
    public var plistText: String?
    public var launchdLoaded: Bool
    public var launchdPid: Int?
    public var installedBinary: String
    public var binaryExecutable: Bool
    public var configDir: String
    public var dirMode: Int?
    public var keyFile: String
    public var keyFileExists: Bool
    public var keyFileMode: Int?
    public var keyFormatValid: Bool

    public init(tailnetIPv4: String?, plistPath: String, plistText: String?, launchdLoaded: Bool, launchdPid: Int?,
                installedBinary: String, binaryExecutable: Bool, configDir: String, dirMode: Int?, keyFile: String,
                keyFileExists: Bool, keyFileMode: Int?, keyFormatValid: Bool) {
        self.tailnetIPv4 = tailnetIPv4; self.plistPath = plistPath; self.plistText = plistText
        self.launchdLoaded = launchdLoaded; self.launchdPid = launchdPid; self.installedBinary = installedBinary
        self.binaryExecutable = binaryExecutable; self.configDir = configDir; self.dirMode = dirMode
        self.keyFile = keyFile; self.keyFileExists = keyFileExists; self.keyFileMode = keyFileMode
        self.keyFormatValid = keyFormatValid
    }
}

public func hostChecks(_ f: HostFacts, daemonExecutable: String?) -> [HealthCheck] {
    var out: [HealthCheck] = []
    out.append(f.tailnetIPv4 != nil
        ? HealthCheck("tailnet", "Tailnet address present", .pass, detail: f.tailnetIPv4!)
        : HealthCheck("tailnet", "Tailnet address present", .fail, detail: "no 100.64.0.0/10 address on any interface",
            why: "The phone and other Macs reach this Mac only through its tailnet address.",
            fix: "Open Tailscale and connect, or run `tailscale up`; check with `tailscale status`."))

    out.append(f.binaryExecutable
        ? HealthCheck("binary", "Binary installed", .pass, detail: f.installedBinary)
        : HealthCheck("binary", "Binary installed", .fail, detail: "\(f.installedBinary) is missing or not executable",
            why: "launchd starts the daemon from this exact path, and the Accessibility approval is tied to it.",
            fix: "`make -C mac install` from the repo (copy the mac/ folder to this Mac first if needed)."))

    out.append(f.plistText != nil
        ? HealthCheck("plist", "launchd agent file present", .pass, detail: f.plistPath)
        : HealthCheck("plist", "launchd agent file present", .fail, detail: "\(f.plistPath) not found",
            why: "Without it the daemon does not start at login or restart after a crash.",
            fix: "`make -C mac install`."))

    if f.launchdLoaded, f.launchdPid != nil {
        out.append(HealthCheck("launchd", "launchd agent loaded and running", .pass, detail: "pid \(f.launchdPid!)"))
    } else if f.launchdLoaded {
        out.append(HealthCheck("launchd", "launchd agent loaded and running", .fail, detail: "loaded but not running",
            why: "launchd has the agent but no process; it may be crash-looping or waiting out its 5 second throttle.",
            fix: "`tail ~/.config/greenfield-inserter/inserter.log ~/.config/greenfield-inserter/launchd-stderr.log`, then `launchctl kickstart -k gui/$(id -u)/\(InserterDefaults.launchdLabel)`."))
    } else {
        out.append(HealthCheck("launchd", "launchd agent loaded and running", .fail, detail: "not loaded in gui/$(id -u)",
            why: "The daemon will not run until the agent is loaded (it loads at login, but only for a logged-in graphical session).",
            fix: "`launchctl bootstrap gui/$(id -u) \(f.plistPath)` or `make -C mac install`. If this is an ssh session, check that someone is logged in at the Mac."))
    }

    // key file
    if !f.keyFileExists {
        out.append(HealthCheck("keyfile", "Key file present and private", .fail, detail: "\(f.keyFile) not found",
            why: "No key means every request is refused.",
            fix: "`\(f.installedBinary) key create` (shows the key once)."))
    } else if !f.keyFormatValid {
        out.append(HealthCheck("keyfile", "Key file present and private", .fail, detail: "\(f.keyFile) is not a valid key file",
            why: "The daemon treats a corrupt key file as no key.",
            fix: "`\(f.installedBinary) key create --force` and re-enter the new key in the phone."))
    } else if let mode = f.keyFileMode, mode & 0o077 != 0 {
        out.append(HealthCheck("keyfile", "Key file present and private", .fail, detail: "mode is \(String(mode, radix: 8)), should be 600",
            why: "Other users on this Mac could read it (it holds only a hash, but it should stay private).",
            fix: "`chmod 600 \(f.keyFile)`."))
    } else if let mode = f.dirMode, mode & 0o077 != 0 {
        out.append(HealthCheck("keyfile", "Key file present and private", .fail, detail: "\(f.configDir) mode is \(String(mode, radix: 8)), should be 700",
            why: "Other users on this Mac could list or replace files there.",
            fix: "`chmod 700 \(f.configDir)`."))
    } else {
        out.append(HealthCheck("keyfile", "Key file present and private", .pass, detail: "mode 600 in a 700 directory (holds a hash, not the key)"))
    }

    if let exe = daemonExecutable, !exe.isEmpty, f.binaryExecutable, exe != f.installedBinary {
        out.append(HealthCheck("path", "Daemon runs the installed binary", .fail, detail: "running \(exe)",
            why: "The Accessibility approval belongs to the installed binary's path; a daemon started from elsewhere will not have it.",
            fix: "Stop the stray copy and use launchd: `launchctl kickstart -k gui/$(id -u)/\(InserterDefaults.launchdLabel)`."))
    }

    return out
}

public func peerChecks(_ reports: [MacReport], localVersion: String) -> [HealthCheck] {
    reports.map { r in
        let id = "peer-\(r.mac.alias)"
        let title = "\(r.mac.alias) reachable from here"
        if r.state.needsAttention || !r.exposed.isEmpty {
            return HealthCheck(id, title, .fail, detail: r.state.label + (r.exposed.isEmpty ? "" : "; listening outside the tailnet"),
                why: "The phone, or this Mac, could not use \(r.mac.alias) as an input target right now." + (r.state == .unauthorized ? " " + keyFileNote : ""),
                fix: "`greenfield-inserter macs doctor` shows what to fix on \(r.mac.alias); `tailscale ping \(r.mac.host)` tests the network path.")
        }
        return HealthCheck(id, title, .pass, detail: "\(r.mac.host):\(r.mac.port) \(r.state.label)")
    }
}

// MARK: - formatting

public func isHealthy(_ checks: [HealthCheck]) -> Bool { checks.allSatisfy { $0.status == .pass } }

private func mark(_ s: HealthCheck.Status) -> String {
    switch s { case .pass: return "ok  "; case .fail: return "FAIL"; case .warn: return "warn"; case .skip: return "skip" }
}

public func formatHealth(label: String, checks: [HealthCheck]) -> String {
    var lines = ["\(label): " + (isHealthy(checks) ? "HEALTHY" : "NOT HEALTHY")]
    for c in checks {
        lines.append("  \(mark(c.status))  \(c.title)" + (c.detail.isEmpty ? "" : " - \(c.detail)"))
    }
    if checks.contains(where: { $0.id == "key" || $0.id == "keyfile" }) { lines.append("  note: " + keyFileNote) }
    return lines.joined(separator: "\n")
}

public func formatDoctor(label: String, checks: [HealthCheck]) -> String {
    let problems = checks.filter { $0.status == .fail || $0.status == .warn }
    var lines = ["\(label): " + (problems.isEmpty ? "all \(checks.count) checks passed" : "\(problems.count) problem\(problems.count == 1 ? "" : "s") found")]
    for c in checks where c.status == .pass { lines.append("  ok    \(c.title) - \(c.detail)") }
    for c in checks where c.status == .skip { lines.append("  skip  \(c.title) - \(c.detail)") }
    for c in problems {
        lines.append("")
        lines.append("  \(mark(c.status))  \(c.title)")
        lines.append("        wrong: \(c.detail)")
        lines.append("        why:   \(c.why)")
        lines.append("        fix:   \(c.fix)")
    }
    if checks.contains(where: { $0.id == "key" || $0.id == "keyfile" }) { lines += ["", "  note: " + keyFileNote] }
    return lines.joined(separator: "\n")
}
