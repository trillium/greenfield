import Foundation

/// One transcript and what became of it. The `id` is generated when the words are transcribed and reused on every resend, so a Mac
/// that already inserted it can say so instead of typing it twice.
struct OutboxItem: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        /// Not delivered yet: waiting for a Mac to be chosen, being sent, or failed and waiting for a resend.
        case pending
        case sent
    }

    var id: UUID
    var text: String
    var createdAt: Date
    var status: Status = .pending
    var targetName: String?
    var attempts = 0
    /// Why the last attempt failed; nil while untried or after success.
    var lastError: String?
    var sentAt: Date?
    var asrMs: Int?
    var networkMs: Int?
    var macMs: Int?
    /// The agent's evidence that the text reached the focused field: "confirmed", "unconfirmed", or nil (older agent).
    var delivery: String?

    init(id: UUID = UUID(), text: String, createdAt: Date = Date(), asrMs: Int? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.asrMs = asrMs
    }
}

/// The transcripts, newest first, saved to disk so nothing is lost when the app quits or the network drops.
/// Sent items beyond the newest `keepSent` are dropped; an item that has not been delivered is never dropped automatically.
@MainActor
@Observable
final class Outbox {
    static let keepSent = 20

    private(set) var items: [OutboxItem] = []
    /// Called after every save, so the support log file can follow. It reads metadata only.
    var onChange: (() -> Void)?
    private let url: URL?

    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([OutboxItem].self, from: data) {
            items = saved
        }
    }

    static var standardURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("outbox.json")
    }

    var pending: [OutboxItem] { items.filter { $0.status == .pending } }

    func item(_ id: UUID) -> OutboxItem? { items.first { $0.id == id } }

    @discardableResult
    func add(text: String, asrMs: Int? = nil) -> OutboxItem {
        let item = OutboxItem(text: text, asrMs: asrMs)
        items.insert(item, at: 0)
        save()
        return item
    }

    func update(_ id: UUID, _ change: (inout OutboxItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        prune()
        save()
    }

    func markAttempt(_ id: UUID, targetName: String) {
        update(id) {
            $0.attempts += 1
            $0.targetName = targetName
        }
    }

    func markSent(_ id: UUID, networkMs: Int, macMs: Int?, delivery: String? = nil, now: Date = Date()) {
        update(id) {
            $0.delivery = delivery
            $0.status = .sent
            $0.lastError = nil
            $0.sentAt = now
            $0.networkMs = networkMs
            $0.macMs = macMs
        }
    }

    func markFailed(_ id: UUID, reason: String) {
        update(id) {
            $0.status = .pending
            $0.lastError = reason
        }
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    /// Clears what was delivered. Undelivered transcripts stay: they are the user's words.
    func clearSent() {
        items.removeAll { $0.status == .sent }
        save()
    }

    private func prune() {
        var keptSent = 0
        items = items.filter { item in
            guard item.status == .sent else { return true }
            keptSent += 1
            return keptSent <= Self.keepSent
        }
    }

    private func save() {
        onChange?()
        guard let url, let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
