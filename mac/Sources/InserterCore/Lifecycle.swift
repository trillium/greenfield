import Foundation

public enum RunningVsInstalled: Equatable {
    case match
    /// A daemon is running but it is not the file on disk (updated, never restarted; or started from elsewhere).
    case restartNeeded(runningSha: String, installedSha: String)
    case notRunning
    case unknown(String)
}

public func judgeRunning(running: BuildIdentity?, installedSha: String?) -> RunningVsInstalled {
    guard let installedSha = installedSha else { return .unknown("the installed file cannot be read") }
    guard let running = running else { return .notRunning }
    if running.binarySha == "unknown" { return .unknown("the running daemon did not report its binary") }
    return running.binarySha == installedSha ? .match : .restartNeeded(runningSha: running.binarySha, installedSha: installedSha)
}

public enum UpdateResult: Equatable {
    case updated(version: String)
    /// The new build did not come up as itself; the previous binary was put back and is running again.
    case rolledBack(reason: String)
    /// The new build did not come up and there was nothing (or nothing working) to go back to.
    case failed(reason: String)
}

/// Install a new binary, restart the agent, wait until the running build IS the new file, and put the
/// previous binary back if it does not. The OS pieces are injected so the decisions can be tested.
public struct UpdateFlow {
    public var installNew: () throws -> Void
    public var restorePrevious: () throws -> Bool          // false when there is no previous binary
    public var restart: () throws -> Void
    /// Waits for the daemon to answer and returns what it says it is running (nil if it never answered).
    public var waitForRunning: () -> BuildIdentity?
    public var newSha: String
    public var previousSha: String?

    public init(installNew: @escaping () throws -> Void, restorePrevious: @escaping () throws -> Bool,
                restart: @escaping () throws -> Void, waitForRunning: @escaping () -> BuildIdentity?,
                newSha: String, previousSha: String?) {
        self.installNew = installNew; self.restorePrevious = restorePrevious; self.restart = restart
        self.waitForRunning = waitForRunning; self.newSha = newSha; self.previousSha = previousSha
    }

    public func run() -> UpdateResult {
        var reason = ""
        do {
            try installNew()
            try restart()
            let running = waitForRunning()
            if let r = running, r.binarySha == newSha { return .updated(version: r.version) }
            reason = running == nil ? "the new build did not answer after the restart"
                                    : "after the restart the daemon is still running a different build (\(running!.binarySha), expected \(newSha))"
        } catch {
            reason = "\(error)"
        }
        // Roll back.
        do {
            guard try restorePrevious() else { return .failed(reason: reason + "; there is no previous binary to go back to") }
            try restart()
            let running = waitForRunning()
            if let r = running, let p = previousSha, r.binarySha == p { return .rolledBack(reason: reason) }
            return .failed(reason: reason + "; the previous binary was put back but the daemon did not come up as it")
        } catch {
            return .failed(reason: reason + "; rolling back failed: \(error)")
        }
    }
}

/// The OS side of install, restart and wait. Not unit tested; exercised by `update`, `restart`, `make install`.
public enum LaunchAgent {
    public static func plistPath(label: String) -> String {
        InserterDefaults.home.path + "/Library/LaunchAgents/\(label).plist"
    }

    /// launchctl bootout then bootstrap, so a changed plist or binary is picked up and nothing stale keeps running.
    public static func restart(label: String) throws {
        let uid = getuid()
        _ = HostInspector.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])     // fine if it was not loaded
        // bootout is asynchronous: give the old process a moment to leave before loading again.
        for _ in 0..<20 where HostInspector.run("/bin/launchctl", ["print", "gui/\(uid)/\(label)"]).status == 0 {
            Thread.sleep(forTimeInterval: 0.25)
        }
        let r = HostInspector.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistPath(label: label)])
        guard r.status == 0 else { throw KeyStoreError.io("launchctl bootstrap failed (\(r.status)): \(r.output.prefix(200))") }
    }

    /// Polls the daemon's /health until it answers (and, if given, reports `expectedSha`), up to `timeout`.
    public static func waitForRunning(port: Int, expectedSha: String?, timeout: TimeInterval = 20) -> BuildIdentity? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: BuildIdentity?
        while Date() < deadline {
            if case .ok(let s) = InserterClient.snapshot(host: "127.0.0.1", port: port, key: nil, path: "/health", timeout: 2), let b = s.build {
                last = b
                if expectedSha == nil || b.binarySha == expectedSha { return b }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return last
    }

    /// Hash prefix of a file, the same way the daemon hashes itself.
    public static func sha(of path: String) -> String? { RunningBuild.sha256Prefix(ofFile: path) }
}
