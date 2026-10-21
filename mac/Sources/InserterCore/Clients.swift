import Foundation

public struct ClientSighting: Equatable {
    public var version: String
    public var at: Date
}

public protocol ClientRecord {
    func saw(version: String)
    /// Newest first.
    func recent() -> [ClientSighting]
}

/// Remembers the last few distinct app versions that talked to the daemon, in a small 0600 file so the
/// memory survives restarts (and `health` run from another process can read it).
public final class ClientLedger: ClientRecord {
    private let url: URL
    private let now: () -> Date
    private let lock = NSLock()
    static let keep = 5

    public init(paths: InserterPaths, now: @escaping () -> Date = Date.init) {
        url = paths.directory.appendingPathComponent("clients.json")
        self.now = now
    }

    private struct Entry: Codable { var version: String; var at: Date }

    private func load() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (try? d.decode([Entry].self, from: data)) ?? []
    }

    public func saw(version: String) {
        lock.lock(); defer { lock.unlock() }
        var all = load().filter { $0.version != version }
        all.insert(Entry(version: String(version.prefix(40)), at: now()), at: 0)
        all = Array(all.prefix(ClientLedger.keep))
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(all) else { return }
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

    public func recent() -> [ClientSighting] {
        lock.lock(); defer { lock.unlock() }
        return load().map { ClientSighting(version: $0.version, at: $0.at) }
    }
}

/// The daemon's own view of the apps it has seen, for `GET /status` (`app_compatible`) and for health/doctor.
public struct AppCompat: Equatable {
    public var ok: Bool
    public var message: String
    public var fix: String

    public var json: [String: Any] { ["ok": ok, "message": message, "fix": fix] }

    public static func parse(_ any: Any?) -> AppCompat? {
        guard let o = any as? [String: Any], let ok = o["ok"] as? Bool else { return nil }
        return AppCompat(ok: ok, message: o["message"] as? String ?? "", fix: o["fix"] as? String ?? "")
    }

    /// Judges the newest app seen. No app yet is a note, never a failure.
    public static func evaluate(_ clients: [ClientSighting], me: String, minClient: String, now: Date = Date()) -> AppCompat {
        guard let newest = clients.max(by: { $0.at < $1.at }) else {
            return AppCompat(ok: true, message: "no app has connected yet", fix: "")
        }
        let age = ageText(from: newest.at, to: now)
        switch Compat.judge(peer: newest.version, me: me, minPeer: minClient) {
        case .compatible:
            return AppCompat(ok: true, message: "the newest app seen (\(newest.version), \(age)) is compatible with daemon \(me)", fix: "")
        case .peerTooOld:
            return AppCompat(ok: false,
                message: "the newest app seen (\(newest.version), \(age)) is older than this daemon works with (daemon \(me), oldest app \(minClient))",
                fix: "Update the app on the phone to a version on the same line as \(me).")
        case .peerTooNew:
            return AppCompat(ok: false,
                message: "the newest app seen (\(newest.version), \(age)) is newer than this daemon (\(me)) supports",
                fix: "Update the Mac daemon: copy the repository's mac/ folder to this Mac and run `make -C mac install`.")
        case .peerUnreadable:
            return AppCompat(ok: false, message: "the newest app seen sent a version this daemon cannot read (\"\(newest.version)\")",
                             fix: "Update the app on the phone.")
        }
    }

    static func ageText(from: Date, to: Date) -> String {
        let s = Int(to.timeIntervalSince(from))
        if s < 90 { return "\(max(s, 0)) seconds ago" }
        if s < 5400 { return "\(s / 60) minutes ago" }
        if s < 172800 { return "\(s / 3600) hours ago" }
        return "\(s / 86400) days ago"
    }
}
