import Foundation

/// The redacted support file a person can share or a script can pull: a few header lines, then sections of log lines, oldest first.
/// Every line goes through `LogRedactor`; the whole file is capped at `maxBytes`, dropping the oldest lines first.
/// What is in the lines is decided by whoever builds the sections: ids, counts, lengths, timings, states and error text, never the
/// dictated text itself, a key or a recording.
struct LogBundle {
    static let maxBytes = 256 * 1024

    struct Section {
        let title: String
        /// Lines that start with an ISO 8601 time, like the Mac daemon's log, so `--since` works on both.
        let lines: [String]
    }

    /// `"name: value"` pairs shown as `# name: value`.
    let header: [String]
    let sections: [Section]

    func render(redactor: LogRedactor = LogRedactor()) -> String {
        let head = header.map { redactor.redact("# " + $0) }
        let safe = sections.map { Section(title: redactor.redact($0.title), lines: redactor.redact(lines: $0.lines)) }
        var budget = Self.maxBytes - head.reduce(0) { $0 + $1.utf8.count + 1 } - safe.reduce(0) { $0 + $1.title.utf8.count + 3 }
        var kept = safe
        // Walk newest to oldest within each section until the budget is used; the notes below say what was dropped.
        var dropped = 0
        for index in kept.indices {
            var take: [String] = []
            for line in kept[index].lines.reversed() {
                let cost = line.utf8.count + 1
                if budget - cost < 0 { dropped += 1; continue }
                budget -= cost
                take.append(line)
            }
            kept[index] = Section(title: kept[index].title, lines: take.reversed())
        }
        var out = head
        if dropped > 0 { out.append("# \(dropped) older lines left out to keep this file under \(Self.maxBytes / 1024) KiB") }
        for section in kept {
            out.append("# --- \(section.title)")
            out.append(contentsOf: section.lines)
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Writes atomically, readable only after the first unlock.
    static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The time stamp every line starts with.
    static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
