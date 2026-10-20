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
        app.mainMenu = SelftestWindow.makeMainMenu()
        app.finishLaunching()
    }

    /// macOS routes Cmd+V to a text field through the main menu's Paste item, so an app with no
    /// Edit menu ignores the shortcut. Real apps have one; this test window must too.
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return main
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
func runSelftest(port: Int, simulate: Bool) -> SelftestObservations {
    var o = SelftestObservations()
    o.simulated = simulate

    if !simulate {
        let health = InserterClient.snapshot(host: "127.0.0.1", port: port, key: nil, path: "/health")
        // "Can actually insert text" is what this run is about to establish, so it cannot be a precondition.
        o.preflight = snapshotChecks(health, subject: .local(port: port), localVersion: RequestHandler.version)
            .filter { $0.id != "can-insert" }
        if o.preflight.contains(where: { $0.status == .fail }) { return o }
    }

    let ui = SelftestWindow()
    defer { ui.close() }
    let focused = ui.open()
    o.windowFocused = focused
    guard focused else { return o }

    let mac = KnownMac(alias: "local", host: "127.0.0.1", port: port, key: "")
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
    if simulate {
        // Development aid: can the daemon's Accessibility read-back see what is in this field?
        let seen = FocusedField.text()
        FileHandle.standardError.write(Data("simulate: Accessibility read-back of the focused field \(seen == nil ? "UNAVAILABLE" : (seen!.contains(marker) ? "sees the inserted text" : "readable but text missing"))\n".utf8))
    }
    guard o.textArrived == true else { return o }

    o.returnSend = deliver("\n", method: "type")
    if !simulate, o.returnSend?.inserted != true { return o }
    o.returnSeen = ui.pump(timeout: 3) { ui.returnCount >= 1 }
    return o
}
