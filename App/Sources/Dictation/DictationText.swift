import Foundation

/// How the text box is read, joined and sent. Line breaks are part of the text: they go to the Mac as line feeds, with empty lines and a
/// trailing newline kept. Only spaces and tabs at the two ends are dropped.
enum DictationText {
    /// Drawn by the text box at each line break so it can be seen. Display only: it is never a character of the text and never sent.
    static let marker = "\u{21B5}"

    /// CRLF, a lone CR and the Unicode line and paragraph separators as one line feed.
    static func normalizingNewlines(_ text: String) -> String {
        guard text.contains(where: \.isNewline) else { return text }
        // "\r\n" is one Character in Swift, so one pass sees it once.
        return String(text.map { $0.isNewline ? "\n" : $0 })
    }

    /// Spaces and tabs off both ends; line breaks stay.
    static func trimmingEdges(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces) }

    /// What a submit sends.
    static func forSending(_ text: String) -> String { trimmingEdges(normalizingNewlines(text)) }

    /// Something to send: at least one visible character. A box of only spaces and line breaks sends nothing.
    static func isSendable(_ text: String) -> Bool { text.contains { !$0.isWhitespace } }

    /// More dictated words on the end of the box: a space between, none after a line break or a space.
    static func joining(_ existing: String, _ addition: String) -> String {
        guard let last = existing.last else { return addition }
        return last.isWhitespace || last.isNewline ? existing + addition : existing + " " + addition
    }

    /// For labels that show text that was already sent: the marker in front of each line break. The text itself is untouched.
    static func displayed(_ text: String) -> String {
        normalizingNewlines(text).replacingOccurrences(of: "\n", with: marker + "\n")
    }

    /// UTF-16 offsets (as NSString counts) of the line breaks, where the text box draws the marker.
    static func lineBreakOffsets(in text: String) -> [Int] {
        var offsets: [Int] = []
        var index = 0
        for unit in text.utf16 {
            if unit == 0x0A { offsets.append(index) }
            index += 1
        }
        return offsets
    }

    /// What VoiceOver reads: each line break as "new line".
    static func spoken(_ text: String) -> String {
        var parts: [String] = []
        for (index, line) in normalizingNewlines(text).components(separatedBy: "\n").enumerated() {
            if index > 0 { parts.append("new line") }
            if !line.isEmpty { parts.append(line) }
        }
        return parts.joined(separator: ", ")
    }
}
