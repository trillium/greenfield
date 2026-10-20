import Foundation
import ApplicationServices
import Carbon.HIToolbox

public struct MacSystemProbe: SystemProbe {
    public init() {}

    public var secureInputEnabled: Bool { IsSecureEventInputEnabled() }

    public var screenLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Bool, locked { return true }
        // Another user's session in front (fast user switching) behaves like a locked screen.
        if let onConsole = dict["kCGSSessionOnConsoleKey"] as? Bool, !onConsole { return true }
        return false
    }

    public var accessibilityTrusted: Bool { AXIsProcessTrusted() }
    public var accessibilityAtStart: Bool { MacSystemProbe.trustedAtStart }

    /// Whether this process was already trusted when it started. macOS only lets a process use a grant it received
    /// after it started once it is relaunched, so "trusted now, not then" means a restart is needed.
    public static let trustedAtStart: Bool = AXIsProcessTrusted()

    /// Under launchd: when Accessibility is granted while the daemon is running, exit so KeepAlive starts a fresh
    /// process that can use the grant. Does nothing in a foreground run (nothing would restart it).
    public static func restartWhenAccessibilityIsGranted(log: @escaping (String) -> Void) {
        _ = trustedAtStart
        guard !trustedAtStart, let service = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"], service != "0", !service.isEmpty else { return }
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 2)
                if AXIsProcessTrusted() {
                    log("Accessibility was granted; restarting so the new process can use it")
                    Thread.sleep(forTimeInterval: 0.3)
                    exit(0)
                }
            }
        }
    }

    /// Asks macOS to show its Accessibility prompt for this binary (no-op once granted).
    public static func requestAccessibilityPrompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
