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

    /// Asks macOS to show its Accessibility prompt for this binary (no-op once granted).
    public static func requestAccessibilityPrompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
