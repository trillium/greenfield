import Foundation

/// The phone's support log: the Diagnostics event log, the outbox's metadata and the Health summary, redacted, in one file that
/// `scripts/pull-logs.sh` copies off the phone (no cable needed) and the Share logs button hands to the share sheet.
/// The outbox itself (`outbox.json`) holds the dictated text and is never read by anything that leaves the phone; this file has
/// only the length of each text.
@MainActor
final class SupportLog {
    /// Where the file lives, relative to the app container, for `devicectl device copy from`.
    static let containerPath = "Library/Application Support/support-log.txt"

    let url: URL?
    private let log: EventLog
    private let outbox: Outbox
    private var info: [String: Any]
    private var saver: Task<Void, Never>?
    /// The Health report, for the last section; set by the app model.
    var health: (() -> [HealthItem])?
    private(set) var lastWriteFailed = false

    init(log: EventLog, outbox: Outbox, url: URL?, info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        self.log = log
        self.outbox = outbox
        self.url = url
        self.info = info
        log.onChange = { [weak self] in self?.schedule() }
        outbox.onChange = { [weak self] in self?.schedule() }
    }

    static var standardURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("support-log.txt")
    }

    /// Events available to share: what Health reports as "Logs available".
    var isAvailable: Bool { url != nil && !lastWriteFailed }

    func render(now: Date = Date()) -> String {
        let build = BuildInfo(info: info)
        let header = ["support log, format 1", "app: \(build.display)", "generated: \(LogBundle.stamp(now))",
                      "contents: events, outbox metadata and the Health summary; no dictated text, no keys, no audio"]
        var sections = [LogBundle.Section(title: "events", lines: log.entries.reversed().map {
            "\(LogBundle.stamp($0.date)) [\($0.category.rawValue)] \($0.text)"
        })]
        sections.append(LogBundle.Section(title: "outbox (text is never included, only its length)",
                                          lines: outbox.items.sorted { $0.createdAt < $1.createdAt }.map(Self.line)))
        if let health {
            sections.append(LogBundle.Section(title: "health", lines: health().map {
                "\(LogBundle.stamp(now)) health \($0.id) \(Self.level($0.level)) \($0.detail)"
            }))
        }
        return LogBundle(header: header, sections: sections).render()
    }

    /// One outbox item as a log line: ids, states, counts and timings. `text` is not read except for its length.
    static func line(_ item: OutboxItem) -> String {
        var parts = ["outbox", "id=\(item.id.uuidString)", "status=\(item.status.rawValue)", "chars=\(item.text.count)",
                     "attempts=\(item.attempts)"]
        if let target = item.targetName { parts.append("target=\(target)") }
        if let ms = item.asrMs { parts.append("asr_ms=\(ms)") }
        if let ms = item.networkMs { parts.append("network_ms=\(ms)") }
        if let ms = item.macMs { parts.append("mac_ms=\(ms)") }
        if let delivery = item.delivery { parts.append("delivery=\(delivery)") }
        if let sent = item.sentAt { parts.append("sent=\(LogBundle.stamp(sent))") }
        if let error = item.lastError { parts.append("error=\(error)") }
        return "\(LogBundle.stamp(item.createdAt)) " + parts.joined(separator: " ")
    }

    private static func level(_ level: HealthItem.Level) -> String {
        switch level {
        case .ok: return "ok"
        case .warning: return "warning"
        case .problem: return "problem"
        }
    }

    /// Writes the file now (opening Diagnostics, tapping Share logs, launch).
    @discardableResult
    func writeNow() -> URL? {
        saver?.cancel()
        saver = nil
        guard let url else { return nil }
        do {
            try LogBundle.write(render(), to: url)
            lastWriteFailed = false
            return url
        } catch {
            lastWriteFailed = true
            return nil
        }
    }

    /// Soon, not on every entry: sounds can arrive many times a second.
    private func schedule() {
        guard url != nil, saver == nil else { return }
        saver = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.writeNow()
        }
    }
}
