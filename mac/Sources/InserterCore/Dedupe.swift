import Foundation

/// Remembers the result of recently completed requests by id so a retried POST is answered
/// from memory instead of inserting the text twice. Only successes are remembered, so a
/// request that failed (locked screen, secure input) can be retried with the same id.
public final class DedupeCache {
    private struct Entry { var response: HTTPResponse; var at: Date }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let lock = NSLock()
    private let ttl: TimeInterval
    private let capacity: Int
    private let now: () -> Date

    public init(ttl: TimeInterval = 15 * 60, capacity: Int = 1024, now: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.capacity = capacity
        self.now = now
    }

    public func lookup(_ id: String) -> HTTPResponse? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[id] else { return nil }
        if now().timeIntervalSince(e.at) > ttl {
            entries[id] = nil
            order.removeAll { $0 == id }
            return nil
        }
        return e.response
    }

    public func remember(_ id: String, _ response: HTTPResponse) {
        lock.lock(); defer { lock.unlock() }
        if entries[id] == nil { order.append(id) }
        entries[id] = Entry(response: response, at: now())
        while order.count > capacity {
            entries[order.removeFirst()] = nil
        }
    }
}
