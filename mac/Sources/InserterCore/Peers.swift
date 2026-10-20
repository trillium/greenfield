import Foundation

/// One node of the tailnet, from `tailscale status --json`.
public struct TailnetNode: Equatable {
    public var hostName: String
    public var dnsName: String        // full MagicDNS name without the trailing dot
    public var ip: String
    public var os: String
    public var online: Bool
    public var userID: Int64
}

public enum TailnetStatus {
    public static func parse(_ data: Data) -> (me: TailnetNode, peers: [TailnetNode])? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let selfObj = o["Self"] as? [String: Any], let me = node(selfObj) else { return nil }
        let peers = ((o["Peer"] as? [String: Any]) ?? [:]).values.compactMap { ($0 as? [String: Any]).flatMap(node) }
        return (me, peers.sorted { $0.dnsName < $1.dnsName })
    }

    static func node(_ o: [String: Any]) -> TailnetNode? {
        guard let dns = o["DNSName"] as? String, let ips = o["TailscaleIPs"] as? [String],
              let ip = ips.first(where: { !$0.contains(":") }), let user = (o["UserID"] as? NSNumber)?.int64Value else { return nil }
        return TailnetNode(hostName: o["HostName"] as? String ?? "", dnsName: dns.hasSuffix(".") ? String(dns.dropLast()) : dns,
                           ip: ip, os: o["OS"] as? String ?? "", online: o["Online"] as? Bool ?? false, userID: user)
    }
}

/// A computer running greenfield-inserter, as the phone lists it.
public struct DiscoveredComputer: Equatable {
    public var name: String
    public var address: String       // MagicDNS name: stable, and what the phone connects to
    public var version: String
    public var isSelf: Bool

    public var json: [String: Any] { ["name": name, "address": address, "version": version, "self": isSelf] }
}

public protocol ComputerDiscovery {
    func computers() -> [DiscoveredComputer]
}

/// Finds the other Macs of the same tailnet user that run the daemon, by asking each online macOS peer's
/// /status. Only same-user peers are probed, so nothing is sent to other people's devices.
public final class TailnetDiscovery: ComputerDiscovery {
    private let statusJSON: () -> Data?
    private let probe: (TailnetNode) -> DaemonSnapshot?
    private let myName: () -> String
    private let myVersion: String
    private let now: () -> Date
    private let lock = NSLock()
    private var cache: (until: Date, value: [DiscoveredComputer])?

    public init(statusJSON: @escaping () -> Data?, probe: @escaping (TailnetNode) -> DaemonSnapshot?,
                myName: @escaping () -> String, myVersion: String, now: @escaping () -> Date = Date.init) {
        self.statusJSON = statusJSON; self.probe = probe; self.myName = myName; self.myVersion = myVersion; self.now = now
    }

    public func computers() -> [DiscoveredComputer] {
        lock.lock()
        if let c = cache, c.until > now() { lock.unlock(); return c.value }
        lock.unlock()
        guard let data = statusJSON(), let (me, peers) = TailnetStatus.parse(data) else { return [] }
        let candidates = peers.filter { $0.online && $0.userID == me.userID && $0.os == "macOS" }
        var found = [DiscoveredComputer?](repeating: nil, count: candidates.count)
        let resultLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
            let node = candidates[i]
            guard let s = self.probe(node) else { return }
            resultLock.lock(); found[i] = DiscoveredComputer(name: s.name, address: node.dnsName, version: s.version, isSelf: false); resultLock.unlock()
        }
        let all = ([DiscoveredComputer(name: myName(), address: me.dnsName, version: myVersion, isSelf: true)] + found.compactMap { $0 })
        lock.lock(); cache = (now().addingTimeInterval(20), all); lock.unlock()
        return all
    }
}

/// The `greenfield://add` link a phone can scan or tap to add this Mac with no typing.
public enum AddLink {
    public static func make(name: String, address: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        let n = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        let a = address.addingPercentEncoding(withAllowedCharacters: allowed) ?? address
        return "greenfield://add?name=\(n)&address=\(a)"
    }

    public static func parse(_ link: String) -> (name: String, address: String)? {
        guard let c = URLComponents(string: link), c.scheme == "greenfield", c.host == "add",
              let name = c.queryItems?.first(where: { $0.name == "name" })?.value,
              let address = c.queryItems?.first(where: { $0.name == "address" })?.value, !address.isEmpty else { return nil }
        return (name, address)
    }
}
