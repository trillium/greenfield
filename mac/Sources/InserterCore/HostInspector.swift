import Foundation

/// Reads the facts `doctor` needs from the Mac it runs on. Kept apart from the judging code in
/// Health.swift so that code can be tested with made-up facts.
public enum HostInspector {
    public static func gather(paths: InserterPaths, label: String = InserterDefaults.launchdLabel,
                              binary: String = InserterDefaults.installedBinary) -> HostFacts {
        let fm = FileManager.default
        let home = InserterDefaults.home.path
        let plist = "\(home)/Library/LaunchAgents/\(label).plist"
        let launchd = run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])
        var pid: Int?
        var state: String?, runs: Int?
        if launchd.status == 0 {
            for raw in launchd.output.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if state == nil, line.hasPrefix("state = ") { state = String(line.dropFirst(8)) }
                if runs == nil, line.hasPrefix("runs = ") { runs = Int(line.dropFirst(7)) }
            }
        }
        if launchd.status == 0, let line = launchd.output.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") }) {
            pid = Int(line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "")
        }
        func mode(_ path: String) -> Int? {
            ((try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue
        }
        let keyText = try? String(contentsOf: paths.keyFile, encoding: .utf8)
        let keyValid: Bool = {
            guard let t = keyText?.trimmingCharacters(in: .whitespacesAndNewlines), t.hasPrefix("sha256:") else { return false }
            let hex = t.dropFirst(7)
            return hex.count == 64 && hex.allSatisfy { $0.isHexDigit }
        }()
        return HostFacts(
            tailnetIPv4: Tailnet.ipv4(), plistPath: plist, plistText: try? String(contentsOfFile: plist, encoding: .utf8),
            launchdLoaded: launchd.status == 0, launchdPid: pid, installedBinary: binary,
            binaryExecutable: fm.isExecutableFile(atPath: binary), configDir: paths.directory.path,
            dirMode: mode(paths.directory.path), keyFile: paths.keyFile.path, keyFileExists: keyText != nil,
            keyFileMode: mode(paths.keyFile.path), keyFormatValid: keyValid,
            launchdState: state, launchdRuns: runs, installedSha: RunningBuild.sha256Prefix(ofFile: binary))
    }

    public static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

/// Everything a local "am I ready?" or "setup" view needs, gathered the same way `doctor` does but without
/// opening any window or asking other Macs.
public func gatherLocalChecks(paths: InserterPaths, port: Int, label: String = InserterDefaults.launchdLabel,
                              binary: String = InserterDefaults.installedBinary) -> [HealthCheck] {
    let outcome = InserterClient.snapshot(host: "127.0.0.1", port: port, key: nil, path: "/health", timeout: 2)
    var exe: String?, running: BuildIdentity?, uptime: Int?
    if case .ok(let s) = outcome { exe = s.executable; running = s.build; uptime = s.uptime }
    let host = hostChecks(HostInspector.gather(paths: paths, label: label, binary: binary), daemonExecutable: exe, running: running, uptime: uptime)
    return host + snapshotChecks(outcome, subject: .local(port: port), localVersion: BuildInfo.version)
}
