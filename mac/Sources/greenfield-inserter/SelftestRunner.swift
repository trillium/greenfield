import AppKit
import InserterCore

/// A small window with one focused text field. Return presses in it are counted through the
/// field's delegate, so the selftest can tell a real Return key event from a pasted newline.
final class SelftestWindow: NSObject, NSTextFieldDelegate {
    let app = NSApplication.shared
    let window: NSWindow
    let field = NSTextField(frame: NSRect(x: 20, y: 40, width: 440, height: 24))
    private(set) var returnCount = 0

    override init() {
        window = NSWindow(contentRect: NSRect(x: 240, y: 360, width: 480, height: 110),
                          styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.title = "greenfield-inserter selftest"
        let label = NSTextField(labelWithString: "Self-test in progress - please do not type.")
        label.frame = NSRect(x: 20, y: 76, width: 440, height: 20)
        window.contentView?.addSubview(label)
        field.delegate = self
        window.contentView?.addSubview(field)
        app.setActivationPolicy(.regular)
        app.finishLaunching()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { returnCount += 1; return true }
        return false
    }

    var contents: String { field.currentEditor()?.string ?? field.stringValue }

    var hasFocus: Bool { app.isActive && window.isKeyWindow && field.currentEditor() != nil }

    /// Processes UI events (so key events from the daemon are handled) until `done` or the timeout.
    @discardableResult
    func pump(timeout: TimeInterval, until done: () -> Bool = { false }) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if done() { return true }
            if let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
            app.updateWindows()
        }
        return done()
    }

    func open() -> Bool {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        app.activate(ignoringOtherApps: true)
        return pump(timeout: 4) { self.hasFocus }
    }

    func close() { window.orderOut(nil); window.close(); pump(timeout: 0.2) }
}

/// Runs the real delivery path against the local daemon and reports what the window saw.
func runSelftest(port: Int, keyFromStdin: String?, simulate: Bool, paths: InserterPaths) -> SelftestObservations {
    var o = SelftestObservations()
    o.simulated = simulate

    var credential: String?
    if !simulate {
        let health = InserterClient.snapshot(host: "127.0.0.1", port: port, key: nil, path: "/health")
        o.preflight = snapshotChecks(health, subject: .local(port: port), localVersion: RequestHandler.version)
        if o.preflight.contains(where: { $0.status == .fail }) { return o }
        credential = keyFromStdin ?? LocalToken.read(paths: paths)
        if credential == nil { o.credentialProblem = "this Mac's daemon has not written a local token (it is an older version)"; return o }
    }

    let ui = SelftestWindow()
    defer { ui.close() }
    let focused = ui.open()
    o.windowFocused = focused
    guard focused else { return o }

    let mac = KnownMac(alias: "local", host: "127.0.0.1", port: port, key: credential ?? "")
    let marker = "greenfield-selftest-" + String(UUID().uuidString.prefix(8)).lowercased()

    func deliver(_ text: String, method: String?) -> InserterClient.SendResult? {
        if simulate {
            if method == "type" && text == "\n" { ui.field.currentEditor()?.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
            else { ui.field.currentEditor()?.insertText(text) }
            return nil
        }
        // The HTTP call runs off the main thread so this one keeps handling the key events it triggers.
        var result: InserterClient.SendResult?
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            result = InserterClient.sendText(text, to: mac, source: "selftest", method: method)
            group.leave()
        }
        ui.pump(timeout: 12) { group.wait(timeout: .now()) == .success }
        return result
    }

    o.textSend = deliver(marker, method: nil)
    if !simulate, o.textSend?.inserted != true { return o }
    o.textArrived = ui.pump(timeout: 3) { ui.contents.contains(marker) }
    guard o.textArrived == true else { return o }

    o.returnSend = deliver("\n", method: "type")
    if !simulate, o.returnSend?.inserted != true { return o }
    o.returnSeen = ui.pump(timeout: 3) { ui.returnCount >= 1 }
    return o
}
