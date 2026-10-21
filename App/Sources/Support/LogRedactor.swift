import Foundation

/// The last gate before a log line leaves a device (the Mac's `GET /logs`, the phone's exported file, the pull script).
/// Loggers already write only ids, counts, lengths, timings, states and error text; this also masks anything that looks like a
/// credential, so a mistake in a log call cannot leak one, and keeps every line short and on one line.
/// Dictated text has no pattern to match, so it is kept out by construction: nothing hands it to a logger.
public struct LogRedactor {
    public static let maxLineLength = 400
    public static let mask = "<redacted>"

    private let rules: [(NSRegularExpression, String)]
    private let opaque: NSRegularExpression
    private let uuid: NSRegularExpression

    public init() {
        func rx(_ pattern: String) -> NSRegularExpression {
            // The patterns are literals in this file; a typo is a programming error caught by the first test run.
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
        let name = "(?:x-[a-z-]*key|authorization|proxy-authorization|cookie|set-cookie|api[_-]?key|access[_-]?token|"
            + "auth[_-]?token|token|secret|password|passwd|passphrase|bearer|key)"
        rules = [
            // a query string or fragment of a URL can carry a token; the host and path are enough to debug
            (rx("([a-z][a-z0-9+.-]*://[^\\s?#\"']*)[?#][^\\s\"']*"), "$1"),
            // credentials in a URL: scheme://user:pass@host
            (rx("(://)[^/\\s@\"']+@"), "$1" + Self.mask + "@"),
            // a launch argument that carries a secret: `-some-key VALUE`
            (rx("(^|\\s)(--?[a-z][a-z-]*(?:key|token|secret|password))(\\s+)\\S+"), "$1$2$3" + Self.mask),
            // header or field with a value: `X-Example-Key: abc`, `key=abc`, `"token":"abc"`
            (rx("\\b(\(name))([\"']?\\s*[:=]\\s*[\"']?)(?:(?:bearer|basic)\\s+)?[^\\s,;\"'}&]+"), "$1$2" + Self.mask),
            (rx("\\bbearer\\s+[^\\s,;\"']+"), "Bearer " + Self.mask),
            (rx("\\btskey-[a-z0-9-]+"), Self.mask),
            (rx("\\bsk-[a-z0-9_-]{16,}"), Self.mask),
            (rx("\\bgh[pousr]_[a-z0-9]{20,}"), Self.mask),
            (rx("\\bxox[abprs]-[a-z0-9-]{10,}"), Self.mask),
            (rx("\\bAKIA[0-9A-Z]{16}\\b"), Self.mask),
            (rx("\\beyJ[a-z0-9_-]{8,}\\.[a-z0-9_-]+\\.[a-z0-9_-]*"), Self.mask),
        ]
        opaque = rx("[a-z0-9+/_-]{32,}")
        uuid = rx("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
    }

    /// One line, made safe: values in `secrets` are masked wherever they appear, line breaks become " / " (one entry per line, so
    /// `tail` means something), other control characters become spaces, credentials are masked, long opaque strings (hashes, keys)
    /// are masked, and the result is cut to `maxLineLength` characters.
    public func redact(_ line: String, secrets: [String] = []) -> String {
        var text = line
        for secret in secrets where !secret.isEmpty { text = text.replacingOccurrences(of: secret, with: Self.mask) }
        text = text.replacingOccurrences(of: "\r\n", with: " / ").replacingOccurrences(of: "\n", with: " / ")
            .replacingOccurrences(of: "\r", with: " / ")
        text = String(text.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7f ? " " : Character($0) })
        for (regex, template) in rules {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        text = replaceOpaque(text)
        if text.count > Self.maxLineLength { text = String(text.prefix(Self.maxLineLength - 1)) + "…" }
        return text
    }

    public func redact(lines: [String]) -> [String] { lines.map { redact($0) } }

    /// The same as `LogRedactor().redact(text, secrets:)`, for a caller that scrubs one entry at a time.
    public static func clean(_ text: String, secrets: [String] = []) -> String { LogRedactor().redact(text, secrets: secrets) }

    /// A 36-character id with dashes is an id, not a secret; anything else that long and unbroken is masked.
    private func replaceOpaque(_ text: String) -> String {
        let matches = opaque.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var out = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let token = String(out[range])
            let isID = uuid.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil
            if !isID { out.replaceSubrange(range, with: Self.mask) }
        }
        return out
    }
}
