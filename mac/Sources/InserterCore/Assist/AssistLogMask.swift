import Foundation

/// A window title or an application name is private text (a document name, an address). The assist routes never write one to the log;
/// this is the second gate on the way out: `GET /logs` and `greenfield-inserter logs` mask anything under those field names, to the end of
/// the line, so a mistake in a log call cannot leak one. (The general redactor is shared with the phone and knows nothing of windows.)
public enum AssistLogMask {
    public static let mask = "<redacted>"

    private static let field: NSRegularExpression = {
        // The patterns are literals in this file; a typo is a programming error caught by the first test run.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "\\b(window[_-]?title|window[_-]?name|title|app[_-]?name)([\"']?\\s*[:=]\\s*)[^\\n]*$", options: [.caseInsensitive])
    }()

    public static func mask(_ line: String) -> String {
        field.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "$1$2" + mask)
    }
}
