import Foundation

/// What `GET /logs` and `greenfield-inserter logs` ask for: the newest `tail` lines, no older than `since`.
public struct LogQuery: Equatable {
    public static let defaultTail = 200
    public static let maxTail = 2000
    public static let maxSince: TimeInterval = 7 * 24 * 3600

    public var tail: Int
    public var since: TimeInterval?

    public init(tail: Int = LogQuery.defaultTail, since: TimeInterval? = nil) { self.tail = tail; self.since = since }

    /// `tail=N` (1...2000) and `since=30m` (a number and s, m, h or d; at most 7 days). Anything else is an error in plain words.
    public static func parse(query: String) -> Result<LogQuery, LogQueryError> {
        var result = LogQuery()
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { return .failure(LogQueryError("bad query")) }
            switch kv[0] {
            case "tail":
                guard let n = Int(kv[1]), (1...maxTail).contains(n) else { return .failure(LogQueryError("tail must be 1 to \(maxTail)")) }
                result.tail = n
            case "since":
                guard let seconds = parseDuration(String(kv[1])), seconds <= maxSince else {
                    return .failure(LogQueryError("since must look like 90s, 30m, 2h or 1d, and be at most 7d"))
                }
                result.since = seconds
            default:
                return .failure(LogQueryError("unknown parameter \(LogSafe.token(String(kv[0])))"))
            }
        }
        return .success(result)
    }

    /// "90s", "30m", "2h", "1d" -> seconds; nil for anything else (including zero).
    public static func parseDuration(_ text: String) -> TimeInterval? {
        guard let unit = text.last, let n = Double(text.dropLast()), n > 0 else { return nil }
        switch unit {
        case "s": return n
        case "m": return n * 60
        case "h": return n * 3600
        case "d": return n * 86400
        default: return nil
        }
    }
}

public struct LogQueryError: Error, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// Where the daemon's own log lines come from.
public protocol LogSource {
    /// The newest lines first-to-last (oldest of them first), already limited to `query`. Not redacted.
    func read(_ query: LogQuery, now: Date) -> [String]
    /// Is there a log to serve at all (it exists and can be read)?
    var available: Bool { get }
}

/// Reads the log file `FileLogger` writes, and the one it rotated away, without loading more than `window` bytes of either.
public struct FileLogSource: LogSource {
    public let file: URL
    public var window = 1024 * 1024

    public init(file: URL) { self.file = file }

    public var available: Bool { FileManager.default.isReadableFile(atPath: file.path) }

    public func read(_ query: LogQuery, now: Date) -> [String] {
        var lines = tailLines(of: file)
        if lines.count < query.tail { lines = tailLines(of: file.appendingPathExtension("1")) + lines }
        if let since = query.since {
            let cutoff = now.addingTimeInterval(-since)
            let formatter = ISO8601DateFormatter()
            var keeping = false
            lines = lines.filter { line in
                if let stamp = line.split(separator: " ", maxSplits: 1).first.flatMap({ formatter.date(from: String($0)) }) {
                    keeping = stamp >= cutoff
                }
                return keeping       // a line without a timestamp belongs to the line before it
            }
        }
        return Array(lines.suffix(query.tail))
    }

    private func tailLines(of url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(window) ? size - UInt64(window) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }   // drop the cut-off first line
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

/// At most `limit` successful requests per `window` seconds, over all callers: logs are for a person debugging, not a feed.
public final class LogRateLimiter {
    private let limit: Int
    private let window: TimeInterval
    private var stamps: [Date] = []
    private let lock = NSLock()

    public init(limit: Int = 6, window: TimeInterval = 60) { self.limit = limit; self.window = window }

    /// nil when allowed (and counted); otherwise the seconds to wait.
    public func admit(now: Date) -> Int? {
        lock.lock(); defer { lock.unlock() }
        stamps.removeAll { now.timeIntervalSince($0) >= window }
        if stamps.count >= limit, let oldest = stamps.first { return max(1, Int((window - now.timeIntervalSince(oldest)).rounded(.up))) }
        stamps.append(now)
        return nil
    }
}

/// Builds the `/logs` answer: redacted, at most `maxBytes`, newest lines kept.
public enum LogPage {
    public static let maxBytes = 256 * 1024

    public static func build(lines: [String], query: LogQuery, redactor: LogRedactor = LogRedactor(), maxBytes: Int = LogPage.maxBytes) -> (lines: [String], bytes: Int, truncated: Bool) {
        var safe = redactor.redact(lines: lines)
        var bytes = safe.reduce(0) { $0 + $1.utf8.count + 1 }
        var truncated = lines.count >= query.tail
        while bytes > maxBytes, !safe.isEmpty {
            bytes -= safe.removeFirst().utf8.count + 1
            truncated = true
        }
        return (safe, bytes, truncated)
    }
}

/// Values that come from the caller (an id, a source label, a path, a parameter name) are written to the log only in a shape that cannot
/// carry text: short, from a small alphabet, or replaced by a fixed word.
public enum LogSafe {
    /// An id as a log field: letters, digits, dash and underscore up to 64 characters, else "(invalid)".
    public static func id(_ value: String) -> String { matches(value, "^[A-Za-z0-9_-]{1,64}$") ? value : "(invalid)" }

    /// A source label: lowercase letters, digits, dash and underscore up to 16 characters, else "other".
    public static func source(_ value: String) -> String { matches(value, "^[a-z0-9_-]{1,16}$") ? value : "other" }

    /// A short word from a request (a parameter name): up to 16 letters, digits, dash, underscore; else "?".
    public static func token(_ value: String) -> String { matches(value, "^[A-Za-z0-9_-]{1,16}$") ? value : "?" }

    /// The path of a request as the daemon knows it; any other path is logged as "(unknown)".
    public static func path(_ value: String, known: Set<String>) -> String { known.contains(value) ? value : "(unknown)" }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
