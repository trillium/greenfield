import AppKit
import InserterCore
import KitAssist

/// `greenfield-inserter assist check-windows`: the one live check of the window switcher. It opens TWO throwaway windows of its own with
/// random titles, lists with the real provider, asks the service to bring the first one forward, checks with Accessibility that it is,
/// goes `previous`, and closes both. Focus only ever moves between those two windows (the helper itself comes to the front for a moment).
/// It never posts a pointer event, never touches another app's window, and prints counts and its own titles only.
final class LiveWindowCheck: NSObject {
    private let app = NSApplication.shared
    private let tag = String(UUID().uuidString.prefix(8)).lowercased()
    private lazy var titles = ("greenfield-livecheck-\(tag)-A", "greenfield-livecheck-\(tag)-B")
    private var windows: [NSWindow] = []

    private func makeWindow(_ title: String, x: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: x, y: 400, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = title
        window.contentView?.addSubview(NSTextField(labelWithString: "Assist live check: closes by itself."))
        return window
    }

    private func pump(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done() {
            if let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true) { app.sendEvent(event) }
            app.updateWindows()
        }
    }

    /// Runs `body` off the main thread (Accessibility calls into this very process need its main thread free) while events keep flowing.
    private func offMain<T>(_ body: @escaping () -> T) -> T {
        var result: T?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { result = body(); done.signal() }
        pump(20) { done.wait(timeout: .now()) == .success }
        return result!
    }

    func run() -> Int32 {
        let probe = MacSystemProbe()
        guard probe.accessibilityTrusted else {
            print("SKIPPED: Accessibility is not granted to this program (or the terminal running it), so windows cannot be listed.")
            return 3
        }
        guard !probe.screenLocked else { print("SKIPPED: the screen is locked."); return 3 }
        // A shell that is not in the console login session (ssh, a detached terminal multiplexer) cannot show windows or read them back
        // with Accessibility; a LaunchAgent and Terminal.app on the Mac itself are in that session.
        guard CGSessionCopyCurrentDictionary() != nil else {
            print("SKIPPED: this shell is not in the Mac's console login session, so windows cannot be created or read here. Run it from Terminal.app on the Mac.")
            return 3
        }
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        windows = [makeWindow(titles.0, x: 240), makeWindow(titles.1, x: 560)]
        defer { windows.forEach { $0.orderOut(nil); $0.close() }; pump(0.2) }
        windows[0].makeKeyAndOrderFront(nil)
        windows[1].makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        pump(1.0)

        let provider = MacWindowProvider(includeOwnApp: true)
        let service = WindowService(provider: provider, probe: probe, settings: StaticAssistSettings(AssistSettings(enabled: true)),
                                    computerName: { "livecheck" })
        let ownPid = Int(getpid())
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { print((ok ? "  ok   " : "  FAIL ") + what); if !ok { failures.append(what) } }

        guard case let .snapshot(snapshot) = offMain({ service.list(since: nil) }) else { print("FAIL: the list was refused"); return 1 }
        let counts = WindowService.counts(snapshot)
        print("listed \(counts.apps) apps and \(counts.windows) windows (titles are not shown here)")
        let mine = snapshot.apps.first { $0.pid == ownPid }
        let a = mine?.windows.first { $0.title == titles.0 }, b = mine?.windows.first { $0.title == titles.1 }
        check(mine != nil, "this helper's own app is in the list")
        check(a != nil && b != nil, "both throwaway windows are listed with their titles")
        guard let appId = mine?.appId, let first = a, let second = b else { return 1 }
        check(snapshot.frontmost == KitAssist.WindowRef(appId: appId, windowId: second.windowId) || snapshot.frontmost?.appId == appId,
              "the helper is in front before the test (the second window)")

        let wantFirst = FocusRequest(target: .window(appId: appId, windowId: first.windowId), rev: snapshot.rev)
        let focused = offMain { service.focus(wantFirst) }
        if case let .answer(answer) = focused {
            check(answer.result == .ok, "focusing the first window answers ok (got \(AssistEndpoints.resultName(answer.result)))")
            check(answer.frontmost?.windowId == first.windowId, "and the first window is the one in front")
        } else { check(false, "focus was not rate limited") }

        let back = offMain { service.focus(FocusRequest(target: .previous, rev: snapshot.rev)) }
        if case let .answer(answer) = back {
            check(answer.result == .ok && answer.frontmost?.windowId == second.windowId, "previous goes back to the second window (got \(AssistEndpoints.resultName(answer.result)))")
        } else { check(false, "previous was not rate limited") }

        let gone = offMain { service.focus(FocusRequest(target: .window(appId: appId, windowId: "w-does-not-exist"), rev: snapshot.rev)) }
        if case let .answer(answer) = gone { check(answer.result == .notFound, "a window id that does not exist answers notFound") }

        print(failures.isEmpty ? "PASS: window list and focus work on this Mac" : "FAIL: \(failures.count) check(s) failed")
        return failures.isEmpty ? 0 : 1
    }
}
