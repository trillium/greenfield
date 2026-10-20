import Foundation

/// Reads the facts `doctor` needs from the Mac it runs on. Kept apart from the judging code in
/// Health.swift so that code can be tested with made-up facts.
public enum HostInspector {
    public static func gather(paths: InserterPaths) -> HostFacts {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let plist = "\(home)/Library/LaunchAgents/\(InserterDefaults.launchdLabel).plist"
        let binary = InserterDefaults.installedBinary
        let launchd = run("/bin/launchctl", ["print", "gui/\(getuid())/\(InserterDefaults.launchdLabel)"])
        var pid: Int?
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
            keyFileMode: mode(paths.keyFile.path), keyFormatValid: keyValid)
    }

    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
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
