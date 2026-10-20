import Foundation
import AppKit
import ApplicationServices

/// Inserts by putting the text on the pasteboard and sending Cmd+V, then restoring whatever
/// was on the pasteboard before. If the paste cannot be set up it types the text as key events.
public final class MacInserter: TextInserter {
    private let restoreDelay: TimeInterval

    public init(restoreDelay: TimeInterval = 0.35) { self.restoreDelay = restoreDelay }

    public func insert(_ text: String, method: InsertMethod?) throws -> InsertMethod {
        guard AXIsProcessTrusted() else { throw InsertError.accessibilityNotGranted }
        switch method {
        case .type:
            try typeText(text)
            return .type
        case .paste:
            try paste(text)
            return .paste
        case nil:
            do {
                try paste(text)
                return .paste
            } catch InsertError.accessibilityNotGranted {
                throw InsertError.accessibilityNotGranted
            } catch {
                try typeText(text)
                return .type
            }
        }
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
        let source = CGEventSource(stateID: .combinedSessionState)
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if i > 0 {
                guard postKey(virtualKey: 36) else { throw InsertError.failed("could not post Return") }   // 36 = Return
            }
            let units = Array(line.utf16)
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
}

private extension UTF16 {
    static func isLeadSurrogate(_ u: UInt16) -> Bool { (0xD800...0xDBFF).contains(u) }
}
