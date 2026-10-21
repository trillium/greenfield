import Foundation
import AppKit
import ApplicationServices
import KitAssist

/// Lists and raises apps and windows with NSWorkspace and the Accessibility API. It reads only what the window switcher shows (names,
/// titles, flags) and never logs any of it.
///
/// The Accessibility calls are made with a short messaging timeout, so one app that does not answer is listed without windows
/// (`unresponsive`) instead of holding up the list. Without the Accessibility grant, every app is listed with `denied`.
///
/// NSWorkspace keeps its list of running applications up to date from the main thread's run loop: a process that serves requests from other
/// threads must keep the main run loop running (the daemon does).
public final class MacWindowProvider: WindowProvider {
    private struct Known {
        let pid: pid_t
        let element: AXUIElement
        let id: String
    }

    private let lock = NSLock()
    private var known: [Known] = []
    private var counter = 0
    private let ownPid: pid_t
    private let timeout: Float

    /// The daemon does not list itself. The live check, which owns the throwaway windows it lists, asks to be included.
    public init(messagingTimeout: Float = 0.25, includeOwnApp: Bool = false) {
        timeout = messagingTimeout
        ownPid = includeOwnApp ? -1 : ProcessInfo.processInfo.processIdentifier
    }

    // MARK: Listing

    public func listing() -> WindowListing {
        lock.lock(); defer { lock.unlock() }
        let trusted = AXIsProcessTrusted()
        var seen: [Known] = []
        var apps: [AppInfo] = []
        let front = trusted ? frontmostProcess() : nil
        var frontRef: KitAssist.WindowRef?

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated && app.processIdentifier != ownPid {
            let pid = app.processIdentifier
            let appId = app.bundleIdentifier ?? "pid:\(pid)"
            var info = AppInfo(appId: appId, name: app.localizedName ?? appId, pid: Int(pid), hidden: app.isHidden)
            guard trusted else {
                info.access = .denied
                apps.append(info)
                continue
            }
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, timeout)
            var raw: CFTypeRef?
            switch AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &raw) {
            case .success:
                let mainWindow = copyElement(element, kAXMainWindowAttribute)
                let focusedWindow = copyElement(element, kAXFocusedWindowAttribute)
                for window in (raw as? [AXUIElement]) ?? [] {
                    guard isUserWindow(window) else { continue }
                    AXUIElementSetMessagingTimeout(window, timeout)
                    let id = identity(of: window, pid: pid, seen: &seen)
                    info.windows.append(WindowInfo(windowId: id, title: string(window, kAXTitleAttribute),
                                                   minimized: bool(window, kAXMinimizedAttribute), fullscreen: bool(window, "AXFullScreen"),
                                                   main: mainWindow.map { CFEqual($0, window) } ?? false))
                    if pid == front, let focused = focusedWindow ?? mainWindow, CFEqual(focused, window) { frontRef = KitAssist.WindowRef(appId: appId, windowId: id) }
                }
            case .cannotComplete:
                info.access = .unresponsive
            case .apiDisabled, .notImplemented:
                info.access = .denied
            default:
                // A process that exposes no windows (no scripting surface at all) is still an app that can be switched to.
                break
            }
            if pid == front, frontRef == nil { frontRef = KitAssist.WindowRef(appId: appId) }
            apps.append(info)
        }
        known = seen
        return WindowListing(apps: apps, frontmost: frontRef)
    }

    /// The pid of the app that has the keyboard focus, asked of Accessibility (it does not depend on a run loop), else of NSWorkspace.
    private func frontmostProcess() -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        if let app = copyElement(system, kAXFocusedApplicationAttribute) {
            var pid: pid_t = 0
            if AXUIElementGetPid(app, &pid) == .success, pid > 0 { return pid }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private func isUserWindow(_ window: AXUIElement) -> Bool {
        guard string(window, kAXRoleAttribute) == kAXWindowRole as String else { return false }
        let subrole = string(window, kAXSubroleAttribute)
        return subrole.isEmpty || subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String
    }

    /// A window keeps its id as long as the system hands back an equal element for it.
    private func identity(of element: AXUIElement, pid: pid_t, seen: inout [Known]) -> String {
        if let existing = known.first(where: { $0.pid == pid && CFEqual($0.element, element) }) {
            seen.append(existing)
            return existing.id
        }
        counter += 1
        let entry = Known(pid: pid, element: element, id: "w-\(counter)")
        seen.append(entry)
        return entry.id
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let value = raw,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return "" }
        return raw as? String ?? ""
    }

    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return false }
        return (raw as? Bool) ?? false
    }

    // MARK: Bringing forward

    public func bringForward(_ target: KitAssist.WindowRef) -> Activation {
        guard AXIsProcessTrusted() else { return .refused("Accessibility is not granted to the Mac's helper.") }
        lock.lock()
        let window = target.windowId.flatMap { id in known.first { $0.id == id } }
        lock.unlock()
        if target.windowId != nil, window == nil { return .refused("The window is gone.") }
        guard let app = runningApp(target.appId, window: window) else { return .refused("The app is not running.") }
        if app.isHidden { app.unhide() }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, timeout)
        if let window = window {
            if bool(window.element, kAXMinimizedAttribute) {
                AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(element, kAXFocusedWindowAttribute as CFString, window.element)
        } else {
            AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        _ = app.activate(options: [])
        return .asked
    }

    private func runningApp(_ appId: String, window: Known?) -> NSRunningApplication? {
        if let window = window { return NSRunningApplication(processIdentifier: window.pid) }
        if appId.hasPrefix("pid:"), let pid = pid_t(appId.dropFirst(4)) { return NSRunningApplication(processIdentifier: pid) }
        return NSRunningApplication.runningApplications(withBundleIdentifier: appId).first { !$0.isTerminated }
    }
}
