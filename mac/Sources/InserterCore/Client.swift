import Foundation

/// A Mac running greenfield-inserter that this machine can talk to. The key is kept in a 0600
/// file on the machine that talks to it (a phone-side secret, so it is stored in the clear).
public struct KnownMac: Codable, Equatable {
    public var alias: String
    public var host: String
    public var port: Int
    public var key: String
    /// Optional `user@host` for running commands on that Mac over ssh (used by `macs selftest`).
    public var ssh: String?

    /// `key` is empty when none was saved: the daemon authorizes by tailnet identity and the key is optional.
    public init(alias: String, host: String, port: Int = 47821, key: String = "", ssh: String? = nil) {
        self.alias = alias; self.host = host; self.port = port; self.key = key; self.ssh = ssh
    }

    enum CodingKeys: String, CodingKey { case alias, host, port, key, ssh }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = try c.decode(String.self, forKey: .alias)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 47821
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        ssh = try c.decodeIfPresent(String.self, forKey: .ssh)
    }
}

public final class MacRegistry {
    public let paths: InserterPaths
    public init(paths: InserterPaths) { self.paths = paths }

    var file: URL { paths.directory.appendingPathComponent("macs.json") }

    public func load() -> [KnownMac] {
        guard let data = try? Data(contentsOf: file),
              let macs = try? JSONDecoder().decode([KnownMac].self, from: data) else { return [] }
        return macs
    }

    public func upsert(_ mac: KnownMac) throws {
        guard mac.alias.range(of: "^[A-Za-z0-9._-]{1,32}$", options: .regularExpression) != nil else {
            throw KeyStoreError.io("alias must be 1-32 letters, digits, '.', '_' or '-'")
        }
        var all = load().filter { $0.alias != mac.alias }
        all.append(mac)
        try save(all)
    }

    public func remove(_ alias: String) throws {
        try save(load().filter { $0.alias != alias })
    }

    private func save(_ macs: [KnownMac]) throws {
        try paths.ensureDirectory()
        let data = try JSONEncoder().encode(macs.sorted { $0.alias < $1.alias })
        let tmp = file.appendingPathExtension("tmp")
        unlink(tmp.path)
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw KeyStoreError.io("cannot write \(tmp.path): errno \(errno)") }
        defer { close(fd) }
        let ok = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) == data.count }
        guard ok, rename(tmp.path, file.path) == 0 else { throw KeyStoreError.io("could not save \(file.path)") }
    }
}

public enum MacState: Equatable {
    case ready
    case locked
    case secureInput
    case noAccessibility
    case unauthorized
    case identityUnavailable
    case keyNotSet
    case unreachable(String)
    case unexpected(Int)

    public var label: String {
        switch self {
        case .ready: return "ready"
        case .locked: return "locked (screen is locked)"
        case .secureInput: return "secure-input (password field focused)"
        case .noAccessibility: return "needs Accessibility approval"
        case .unauthorized: return "refused (a different tailnet user than that Mac, or a wrong key)"
        case .identityUnavailable: return "that Mac cannot verify who is calling (its Tailscale is not answering)"
        case .keyNotSet: return "older daemon: it still needs a key"
        case .unreachable(let why): return "unreachable (\(why))"
        case .unexpected(let code): return "unexpected HTTP \(code)"
        }
    }

    /// Locked and secure-input are passing conditions of a healthy daemon; the rest need action.
    public var needsAttention: Bool {
        switch self {
        case .ready, .locked, .secureInput: return false
        default: return true
        }
    }
}

public struct MacReport: Equatable {
    public var mac: KnownMac
    public var state: MacState
    public var name: String?
    public var version: String?
    /// Addresses the daemon says it is serving on; empty if it did not say.
    public var listen: [String] = []

    /// Listeners outside the policy (tailnet 100.64.0.0/10 and loopback only).
    public var exposed: [String] { listen.filter { !isTailnetOrLoopback($0) } }
    public var needsAttention: Bool { state.needsAttention || !exposed.isEmpty }
}

/// Policy: plain HTTP is fine because the trust boundary is tailnet membership, so the daemon may
/// listen on the tailnet address and loopback and on nothing else ("ip:port" form).
public func isTailnetOrLoopback(_ hostPort: String) -> Bool {
    let host = hostPort.split(separator: ":").first.map(String.init) ?? hostPort
    let octets = host.split(separator: ".").compactMap { Int($0) }
    guard octets.count == 4 else { return false }
    if octets[0] == 127 { return true }
    return octets[0] == 100 && (64...127).contains(octets[1])
}

public enum InserterClient {
    /// Classifies a /status HTTP exchange. Pure so it can be tested without a network.
    public static func classify(httpStatus: Int, body: Data) -> (MacState, name: String?, version: String?, listen: [String]) {
        let object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        switch httpStatus {
        case 200:
            let name = object["name"] as? String
            let version = object["version"] as? String
            let listen = object["listen"] as? [String] ?? []
            if object["accessibility"] as? Bool == false { return (.noAccessibility, name, version, listen) }
            if object["identity_ok"] as? Bool == false { return (.identityUnavailable, name, version, listen) }
            if object["screen_locked"] as? Bool == true { return (.locked, name, version, listen) }
            if object["secure_input"] as? Bool == true { return (.secureInput, name, version, listen) }
            return (.ready, name, version, listen)
        case 401: return (.unauthorized, nil, nil, [])
        case 503 where object["error"] as? String == "identity_unavailable": return (.identityUnavailable, nil, nil, [])
        case 503 where object["error"] as? String == "key_not_configured": return (.keyNotSet, nil, nil, [])
        default: return (.unexpected(httpStatus), nil, nil, [])
        }
    }

    public static func check(_ mac: KnownMac, timeout: TimeInterval = 5) -> MacReport {
        switch request(mac, method: "GET", path: "/status", body: nil, timeout: timeout) {
        case .failure(let e): return MacReport(mac: mac, state: .unreachable(e.message), name: nil, version: nil)
        case .success(let (code, body)):
            let (state, name, version, listen) = classify(httpStatus: code, body: body)
            return MacReport(mac: mac, state: state, name: name, version: version, listen: listen)
        }
    }

    public struct SendResult: Equatable {
        public var httpStatus: Int?
        public var summary: String
        public var inserted: Bool
        /// "confirmed" or "unconfirmed" when the daemon said which.
        public var delivery: String?

        public init(httpStatus: Int?, summary: String, inserted: Bool, delivery: String? = nil) {
            self.httpStatus = httpStatus; self.summary = summary; self.inserted = inserted; self.delivery = delivery
        }
    }

    public static func sendText(_ text: String, to mac: KnownMac, id: String = UUID().uuidString,
                                source: String = "cli", method: String? = nil, timeout: TimeInterval = 10) -> SendResult {
        var object: [String: Any] = ["id": id, "text": text, "source": source]
        if let method = method { object["method"] = method }
        let payload = try? JSONSerialization.data(withJSONObject: object)
        switch request(mac, method: "POST", path: "/text", body: payload, timeout: timeout) {
        case .failure(let e): return SendResult(httpStatus: nil, summary: "unreachable (\(e.message))", inserted: false)
        case .success(let (code, body)): return interpretSend(httpStatus: code, body: body)
        }
    }

    public static func interpretSend(httpStatus: Int, body: Data) -> SendResult {
        let object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        switch httpStatus {
        case 200:
            let method = object["method"] as? String ?? "?"
            let delivery = object["delivery"] as? String
            let summary = delivery == "unconfirmed"
                ? "sent via \(method), arrival unconfirmed (that app does not expose its text)"
                : "inserted (\(method)\(delivery == "confirmed" ? ", confirmed" : ""))"
            return SendResult(httpStatus: 200, summary: summary, inserted: true, delivery: delivery)
        case 502: return SendResult(httpStatus: 502, summary: "not delivered: the focused field did not change", inserted: false)
        case 401: return SendResult(httpStatus: 401, summary: "refused: this device is not the same tailnet user as that Mac, and no valid key was given (if you use a key it is the real key, not the key file's contents: `macs show-key ALIAS` on the Mac that ran `macs add`)", inserted: false)
        case 409: return SendResult(httpStatus: 409, summary: "secure input is on - nothing inserted", inserted: false)
        case 423: return SendResult(httpStatus: 423, summary: "screen is locked - nothing inserted", inserted: false)
        case 503:
            let error = object["error"] as? String
            let why = error == "accessibility_not_granted" ? "Accessibility is not approved on that Mac"
                : error == "identity_unavailable" ? "that Mac cannot verify who is calling (its Tailscale is not answering)"
                : "that Mac has no key set (older daemon)"
            return SendResult(httpStatus: 503, summary: why, inserted: false)
        default: return SendResult(httpStatus: httpStatus, summary: "HTTP \(httpStatus): \(object["message"] as? String ?? "failed")", inserted: false)
        }
    }

    struct NetworkError: Error { var message: String }

    fileprivate static func request(_ mac: KnownMac, method: String, path: String, body: Data?,
                                    timeout: TimeInterval, sendKey: Bool = true) -> Result<(Int, Data), NetworkError> {
        guard let url = URL(string: "http://\(mac.host):\(mac.port)\(path)") else {
            return .failure(NetworkError(message: "bad host"))
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        if sendKey, !mac.key.isEmpty { req.setValue(mac.key, forHTTPHeaderField: "X-Dictation-Key") }
        if let body = body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let sem = DispatchSemaphore(value: 0)
        var result: Result<(Int, Data), NetworkError> = .failure(NetworkError(message: "no response"))
        URLSession(configuration: .ephemeral).dataTask(with: req) { data, response, error in
            if let http = response as? HTTPURLResponse { result = .success((http.statusCode, data ?? Data())) }
            else if let error = error { result = .failure(NetworkError(message: (error as NSError).localizedDescription)) }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }
}

/// Fixed-width table of check results, one row per Mac, then the network-exposure policy verdict.
public func formatReports(_ reports: [MacReport]) -> String {
    formatTable(reports) + "\n\n" + formatExposure(reports)
}

public func formatExposure(_ reports: [MacReport]) -> String {
    "Network policy: plain HTTP on tailnet addresses and loopback only; any tailnet name (short, full ts.net, 100.x) works; key required.\n"
        + reports.map { r -> String in
            if r.listen.isEmpty { return "  \(r.mac.alias): listening addresses not reported" }
            let verdict = r.exposed.isEmpty ? "ok" : "WARNING - also listening outside the tailnet: " + r.exposed.joined(separator: ", ")
            return "  \(r.mac.alias): \(r.listen.joined(separator: ", ")) - \(verdict)"
        }.joined(separator: "\n")
}

func formatTable(_ reports: [MacReport]) -> String {
    let rows = [["ALIAS", "NAME", "VERSION", "ADDRESS", "STATE"]] + reports.map {
        [$0.mac.alias, $0.name ?? "-", $0.version ?? "-", "\($0.mac.host):\($0.mac.port)", $0.state.label]
    }
    let widths = (0..<5).map { c in rows.map { $0[c].count }.max() ?? 0 }
    return rows.map { row in
        row.enumerated().map { i, cell in i == 4 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) }.joined(separator: "  ")
    }.joined(separator: "\n")
}

extension InserterClient {
    /// Fetches what a daemon says about itself: /status with the key from elsewhere, or /health
    /// (no key) on this Mac's loopback.
    public static func snapshot(host: String, port: Int, key: String?, path: String, timeout: TimeInterval = 4) -> SnapshotOutcome {
        let probe = KnownMac(alias: "-", host: host, port: port, key: key ?? "")
        switch request(probe, method: "GET", path: path, body: nil, timeout: timeout, sendKey: key != nil) {
        case .failure(let e): return .unreachable(e.message)
        case .success(let (code, body)):
            switch code {
            case 200: return DaemonSnapshot.parse(body).map { .ok($0) } ?? .unexpected(200)
            case 401: return .unauthorized
            case 403: return .forbidden
            case 503 where (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String == "identity_unavailable":
                return .identityUnavailable
            case 503 where (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String == "key_not_configured":
                return .keyNotSet
            default: return .unexpected(code)
            }
        }
    }
}
