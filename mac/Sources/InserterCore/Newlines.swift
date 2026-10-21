import Foundation

/// Every line ending a client or a field might use (CRLF, a lone CR, NEL, the Unicode line and paragraph separators) as one line feed.
/// Nothing else is changed: empty lines and a trailing newline stay.
public func normalizeNewlines(_ text: String) -> String {
    guard text.contains(where: { $0.isNewline }) else { return text }
    var result = ""
    result.reserveCapacity(text.utf8.count)
    // "\r\n" is a single Character in Swift, so one pass over Characters sees it once.
    for char in text { result.append(char.isNewline ? "\n" : char) }
    return result
}

/// Where typed text goes: text as Unicode key events, and a real Return key press. The recording sink in the tests and the
/// CGEvent sink in the daemon both implement it, so the plan below is tested without posting a key.
public protocol TypingKeySink {
    /// Text with no line break in it.
    func typeText(_ text: String) throws
    func pressReturn() throws
}

/// Types `text` line by line with a Return key press between lines: a line break is never part of a typed string. A trailing
/// newline is a final Return, an empty line is two Returns in a row, and a bare newline is one Return.
public func typeWithKeys(_ text: String, using sink: TypingKeySink) throws {
    let lines = normalizeNewlines(text).components(separatedBy: "\n")
    for (index, line) in lines.enumerated() {
        if index > 0 { try sink.pressReturn() }
        if !line.isEmpty { try sink.typeText(line) }
    }
}
