import Foundation
import Observation

/// What happened, in order, readable in the app (Diagnostics) without a cable: sounds heard, rules fired, dictation, sends, microphone.
/// Newest first, capped, and saved so it survives a restart. Never records dictated text or keys.
@MainActor
@Observable
final class EventLog {
    enum Category: String, Codable, CaseIterable, Identifiable {
        case app, sound, rule, dictation, send, mic, model
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        let date: Date
        let category: Category
        let text: String
    }

    static let capacity = 500

    private(set) var entries: [Entry] = []
    /// Called after every change, so the support log file can follow.
    var onChange: (() -> Void)?
    private let url: URL?
    private var saver: Task<Void, Never>?

    init(url: URL?) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let url, let data = try? Data(contentsOf: url), let saved = try? decoder.decode([Entry].self, from: data) { entries = saved }
    }

    static var standardURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("events.json")
    }

    func add(_ category: Category, _ text: String, date: Date = Date()) {
        entries.insert(Entry(date: date, category: category, text: text), at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        scheduleSave()
    }

    func clear() {
        entries = []
        scheduleSave()
    }

    /// The whole log as plain text, oldest first, for Copy and Share.
    func export() -> String {
        let stamp = Date.FormatStyle(date: .omitted, time: .complete)
        return entries.reversed().map { "\($0.date.formatted(stamp)) [\($0.category.rawValue)] \($0.text)" }.joined(separator: "\n")
    }

    /// Writes soon, not on every entry: sounds can arrive many times a second.
    private func scheduleSave() {
        onChange?()
        guard url != nil, saver == nil else { return }
        saver = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.saveNow()
        }
    }

    func saveNow() {
        saver = nil
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
