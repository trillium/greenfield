import Foundation

/// Who a tailnet address belongs to, relative to this Mac's own node.
public enum PeerIdentity: Equatable {
    /// Same tailnet user as this Mac's own node.
    case sameUser(login: String)
    /// A device of someone else, or a tagged (non-user) device.
    case otherUser(login: String)
    /// Tailscale could not say. Callers must treat this as "deny".
    case unknown(String)
}

public protocol TailnetIdentity {
    /// Asks the local Tailscale who owns `address` and compares with this Mac's own user.
    func identify(_ address: String) -> PeerIdentity
    /// Login name of this Mac's own tailnet user, nil if Tailscale cannot say.
    func selfLogin() -> String?
}

/// Pure parsing of `tailscale whois --json` output, kept apart so it can be tested with canned output.
public struct WhoisRecord: Equatable {
    public var userID: Int64
    public var login: String
    public var tagged: Bool

    public static func parse(_ data: Data) -> WhoisRecord? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let node = o["Node"] as? [String: Any],
              let user = (node["User"] as? NSNumber)?.int64Value else { return nil }
        let login = ((o["UserProfile"] as? [String: Any])?["LoginName"] as? String) ?? "user \(user)"
        let tags = node["Tags"] as? [Any] ?? []
        return WhoisRecord(userID: user, login: login, tagged: !tags.isEmpty)
    }
}

public func comparePeer(_ peer: WhoisRecord, to me: WhoisRecord) -> PeerIdentity {
    // A tagged device is owned by the tailnet, not by a person, so it never counts as "the same user".
    if peer.tagged || me.tagged { return .otherUser(login: peer.tagged ? "a tagged device" : peer.login) }
    return peer.userID == me.userID ? .sameUser(login: peer.login) : .otherUser(login: peer.login)
}

/// Talks to the local Tailscale through its command-line tool, which knows how to reach the local
/// API however Tailscale was installed. Results are cached briefly; failures are cached even more
/// briefly so a restarting Tailscale recovers quickly but a burst of requests does not spawn a storm.
public final class TailscaleIdentity: TailnetIdentity {
    private let lock = NSLock()
    private var cache: [String: (until: Date, record: WhoisRecord?, reason: String)] = [:]
    private let runner: (_ arguments: [String]) -> (status: Int32, output: Data)?
    private let ownAddress: () -> String?
    private let now: () -> Date

    public init(runner: ((_ arguments: [String]) -> (status: Int32, output: Data)?)? = nil,
                ownAddress: @escaping () -> String? = { Tailnet.ipv4() }, now: @escaping () -> Date = Date.init) {
        self.runner = runner ?? TailscaleIdentity.runCLI
        self.ownAddress = ownAddress
        self.now = now
    }

    public static let cliCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale", "/usr/bin/tailscale",
    ]

    static func runCLI(_ arguments: [String]) -> (status: Int32, output: Data)? {
        guard let path = cliCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
        if done.wait(timeout: .now() + 4) == .timedOut { p.terminate(); return nil }
        return (p.terminationStatus, out.fileHandleForReading.readDataToEndOfFile())
    }

    private func whois(_ address: String) -> (WhoisRecord?, String) {
        lock.lock()
        if let hit = cache[address], hit.until > now() { lock.unlock(); return (hit.record, hit.reason) }
        lock.unlock()
        var record: WhoisRecord?
        var reason = ""
        if let r = runner(["whois", "--json", address]) {
            if r.status == 0, let parsed = WhoisRecord.parse(r.output) { record = parsed }
            else { reason = "tailscale could not identify \(address)" }
        } else {
            reason = "the tailscale command-line tool is missing or did not answer"
        }
        lock.lock()
        cache[address] = (now().addingTimeInterval(record != nil ? 60 : 3), record, reason)
        lock.unlock()
        return (record, reason)
    }

    public func selfLogin() -> String? {
        guard let own = ownAddress() else { return nil }
        return whois(own).0?.login
    }

    public func identify(_ address: String) -> PeerIdentity {
        guard let own = ownAddress() else { return .unknown("this Mac has no tailnet address") }
        let (me, myReason) = whois(own)
        guard let mine = me else { return .unknown(myReason) }
        let (peer, reason) = whois(address)
        guard let theirs = peer else { return .unknown(reason) }
        return comparePeer(theirs, to: mine)
    }
}
