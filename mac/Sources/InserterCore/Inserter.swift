import Foundation
import AppKit
import ApplicationServices

/// Inserts by putting the text on the pasteboard and sending Cmd+V, then restoring whatever
/// was on the pasteboard before. If the paste cannot be set up it types the text as key events.
public final class MacInserter: TextInserter {
    private let restoreDelay: TimeInterval

    public init(restoreDelay: TimeInterval = 0.35) { self.restoreDelay = restoreDelay }

    public func insert(_ text: String, method: InsertMethod?) throws -> InsertOutcome {
        guard AXIsProcessTrusted() else { throw InsertError.accessibilityNotGranted }
        let flow = InsertionFlow(
            readFocusedText: { FocusedField.text() },
            readAfter: { text, before in
                if before == nil { return nil }       // unreadable field: nothing to wait for
                // Give the app up to a second to apply the keys; stop as soon as the text shows up.
                var last = FocusedField.text()
                for _ in 0..<20 {
                    if let l = last, l != before, normalizeNewlines(l).contains(normalizeNewlines(text)) { break }
                    Thread.sleep(forTimeInterval: 0.05)
                    last = FocusedField.text()
                }
                return last
            },
            paste: { try self.paste($0) },
            type: { try self.typeText($0) })
        return try flow.run(text, method: method)
    }

    // MARK: paste

    private struct Snapshot {
        var items: [[(NSPasteboard.PasteboardType, Data)]]
    }

    private func snapshot(_ pb: NSPasteboard) -> Snapshot {
        Snapshot(items: (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        })
    }

    private func restore(_ s: Snapshot, to pb: NSPasteboard) {
        pb.clearContents()
        let items = s.items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, d) in entries { item.setData(d, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    private func paste(_ text: String) throws {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Ask clipboard managers not to record this transient copy.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        guard pb.writeObjects([item]) else {
            restore(saved, to: pb)
            throw InsertError.failed("could not write the pasteboard")
        }
        let ours = pb.changeCount
        guard postKey(virtualKey: 9, flags: .maskCommand) else {   // 9 = V
            restore(saved, to: pb)
            throw InsertError.failed("could not post Cmd+V")
        }
        // The target app reads the pasteboard asynchronously; give it time before restoring,
        // and leave the pasteboard alone if someone else changed it meanwhile.
        Thread.sleep(forTimeInterval: restoreDelay)
        if pb.changeCount == ours { restore(saved, to: pb) }
    }

    private func postKey(virtualKey: CGKeyCode, flags: CGEventFlags = []) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: typed fallback

    private func typeText(_ text: String) throws {
        try typeWithKeys(text, using: CGEventKeySink(postReturn: { self.postKey(virtualKey: 36) }))   // 36 = Return
    }
}

/// Types text as Unicode key events in short chunks. The line breaks were already turned into Return presses by `typeWithKeys`.
private struct CGEventKeySink: TypingKeySink {
    let postReturn: () -> Bool

    func pressReturn() throws {
        guard postReturn() else { throw InsertError.failed("could not post Return") }
    }

    func typeText(_ text: String) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            var end = min(start + 20, units.count)
            // Don't split a surrogate pair across events.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            var chunk = Array(units[start..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw InsertError.failed("could not create key events")
            }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.004)
            start = end
        }
    }
}

private extension UTF16 {
    static func isLeadSurrogate(_ u: UInt16) -> Bool { (0xD800...0xDBFF).contains(u) }
}


/// Reads the text of whatever has keyboard focus through the Accessibility API, when the app exposes it.
public enum FocusedField {
    /// The focused element, asked of the frontmost app directly: that works in more session types than
    /// the system-wide query, which can answer "cannot complete".
    static func focusedElement() -> AXUIElement? {
        if let app = NSWorkspace.shared.frontmostApplication {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appEl, 0.5)
            var focused: CFTypeRef?
            let e = AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focused)
            if e == .success, let f = focused { return (f as! AXUIElement) }
            debug("frontmost app (\(app.localizedName ?? "?")) focused element: AXError \(e.rawValue)")
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var focused: CFTypeRef?
        let e = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        if e == .success, let f = focused { return (f as! AXUIElement) }
        debug("system-wide focused element: AXError \(e.rawValue)")
        return nil
    }

    static func debug(_ message: String) {
        if ProcessInfo.processInfo.environment["GREENFIELD_AX_DEBUG"] != nil {
            FileHandle.standardError.write(Data("ax: \(message)\n".utf8))
        }
    }

    public static func text() -> String? {
        guard let el = focusedElement() else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.5)
        var value: CFTypeRef?
        let e = AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value)
        guard e == .success else { debug("value: AXError \(e.rawValue)"); return nil }
        if !(value is String) { debug("value is not a string") }
        return value as? String
    }
}
