import Foundation

/// What the daemon can say about whether text really arrives, from evidence only: a delivery the
/// daemon confirmed by reading the focused field back, or a selftest that read its own window.
public struct CanInsert: Equatable {
    public enum State: String { case ok, failed, unknown }
    public var state: State
    public var at: Date?
    public var source: String?      // "delivery" or "selftest"
    public var detail: String

    public var json: [String: Any] {
        var o: [String: Any] = ["state": state.rawValue, "detail": detail]
        if let at = at { o["at"] = ISO8601DateFormatter().string(from: at) }
        if let source = source { o["source"] = source }
        return o
    }

    public static func parse(_ any: Any?) -> CanInsert? {
        guard let o = any as? [String: Any], let s = (o["state"] as? String).flatMap(State.init(rawValue:)) else { return nil }
        return CanInsert(state: s, at: (o["at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
                         source: o["source"] as? String, detail: o["detail"] as? String ?? "")
    }
}

public protocol DeliveryRecord {
    func recordSuccess(source: String)
    func recordFailure(source: String, detail: String)
    func canInsert() -> CanInsert
}

/// Remembers the latest success and failure in a small 0600 file shared by the daemon and the
/// selftest. Evidence older than the daemon's start does not count (a reinstall may have lost the
/// Accessibility approval), nor does evidence older than a week.
public final class DeliveryLedger: DeliveryRecord {
    private let url: URL
    private let daemonStart: Date
    private let now: () -> Date
    private let lock = NSLock()
    public static let maxAge: TimeInterval = 7 * 24 * 3600

    public init(paths: InserterPaths, daemonStart: Date = Date(), now: @escaping () -> Date = Date.init) {
        self.url = paths.directory.appendingPathComponent("delivery.json")
        self.daemonStart = daemonStart
        self.now = now
    }

    private struct Entry: Codable { var at: Date; var source: String; var detail: String }
    private struct File: Codable { var success: Entry?; var failure: Entry? }

    private func load() -> File {
        guard let data = try? Data(contentsOf: url) else { return File() }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (try? d.decode(File.self, from: data)) ?? File()
    }

    private func save(_ f: File) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(f) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let tmp = url.appendingPathExtension("tmp")
        unlink(tmp.path)
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return }
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        close(fd)
        rename(tmp.path, url.path)
    }

    public func recordSuccess(source: String) {
        lock.lock(); defer { lock.unlock() }
        var f = load(); f.success = Entry(at: now(), source: source, detail: "text was read back from the focused field"); save(f)
    }

    public func recordFailure(source: String, detail: String) {
        lock.lock(); defer { lock.unlock() }
        var f = load(); f.failure = Entry(at: now(), source: source, detail: detail); save(f)
    }

    public func canInsert() -> CanInsert {
        lock.lock(); defer { lock.unlock() }
        let f = load()
        func valid(_ e: Entry?) -> Entry? {
            guard let e = e, e.at >= daemonStart, now().timeIntervalSince(e.at) <= DeliveryLedger.maxAge else { return nil }
            return e
        }
        let ok = valid(f.success), bad = valid(f.failure)
        if let b = bad, ok == nil || b.at > ok!.at {
            return CanInsert(state: .failed, at: b.at, source: b.source, detail: b.detail)
        }
        if let g = ok { return CanInsert(state: .ok, at: g.at, source: g.source, detail: g.detail) }
        return CanInsert(state: .unknown, at: nil, source: nil,
                         detail: "no delivery has been confirmed since this daemon started")
    }
}
