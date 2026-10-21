import Foundation

public enum InsertMethod: String {
    case paste
    case type
}

public enum InsertError: Error, Equatable {
    case accessibilityNotGranted
    case failed(String)
    /// The focused field could be read and the text did not appear in it.
    case notDelivered
}

public protocol TextInserter {
    /// Inserts text at the cursor of the focused app. `method` nil means the default (paste,
    /// falling back to typed key events). The outcome says whether arrival was confirmed.
    func insert(_ text: String, method: InsertMethod?) throws -> InsertOutcome
}

public protocol SystemProbe {
    var secureInputEnabled: Bool { get }
    var screenLocked: Bool { get }
    var accessibilityTrusted: Bool { get }
    /// Was Accessibility already granted when this process started?
    var accessibilityAtStart: Bool { get }
}

public extension SystemProbe {
    var accessibilityAtStart: Bool { accessibilityTrusted }
}

public protocol RequestLogger {
    /// Never receives inserted text; only metadata.
    func log(_ message: String)
}

/// The daemon's whole HTTP surface, free of sockets and OS calls so it can be unit tested.
/// Other input sources use the same two routes: they differ only in the optional `source`.
public final class RequestHandler {
    public static let serviceName = "greenfield-inserter"
    public static var version: String { BuildInfo.version }
    public static let maxTextBytes = 256 * 1024
    /// The paths this daemon answers; anything else is logged as "(unknown)".
    static let routes: Set<String> = Set(["/health", "/status", "/text", "/peers", "/logs"]).union(AssistEndpoints.paths.keys)

    private let keys: KeyVerifier
    private let probe: SystemProbe
    private let inserter: TextInserter
    private let dedupe: DedupeCache
    private let name: () -> String
    private let listening: () -> [String]
    private let identity: TailnetIdentity?
    private let record: DeliveryRecord?
    private let clients: ClientRecord?
    private let discovery: ComputerDiscovery?
    private let assist: AssistEndpoints?
    private let version: String
    private let minClientVersion: String
    private var build: BuildIdentity { RunningBuild.identity }
    private let logger: RequestLogger?
    private let logSource: LogSource?
    private let logLimiter: LogRateLimiter
    private let started: Date
    private let now: () -> Date
    private let insertLock = NSLock()
    private var insertedCount = 0

    public init(keys: KeyVerifier, probe: SystemProbe, inserter: TextInserter, dedupe: DedupeCache = DedupeCache(),
                name: @escaping () -> String, listening: @escaping () -> [String] = { [] },
                identity: TailnetIdentity? = nil, record: DeliveryRecord? = nil, clients: ClientRecord? = nil, discovery: ComputerDiscovery? = nil,
                assist: AssistEndpoints? = nil, version: String = BuildInfo.version, minClientVersion: String = BuildInfo.minClientVersion,
                logger: RequestLogger? = nil, logSource: LogSource? = nil, logLimiter: LogRateLimiter = LogRateLimiter(),
                now: @escaping () -> Date = Date.init) {
        self.keys = keys
        self.probe = probe
        self.inserter = inserter
        self.dedupe = dedupe
        self.name = name
        self.listening = listening
        self.identity = identity
        self.record = record
        self.clients = clients
        self.discovery = discovery
        self.assist = assist
        self.version = version
        self.minClientVersion = minClientVersion
        self.logger = logger
        self.logSource = logSource
        self.logLimiter = logLimiter
        self.now = now
        self.started = now()
    }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        let response = route(request)
        // The path is logged only when it is one of ours: an unknown path is caller-controlled text.
        let path = LogSafe.path(request.path, known: RequestHandler.routes)
        logger?.log("\(LogSafe.token(request.method)) \(path) -> \(response.status)")
        return response
    }

    private func route(_ request: HTTPRequest) -> HTTPResponse {
        if request.path == "/health" { return health(request) }
        let known = ["/status": "GET", "/text": "POST", "/peers": "GET", "/logs": "GET"].merging(AssistEndpoints.paths) { first, _ in first }
        guard let wanted = known[request.path] else {
            return .error(404, "not_found", "unknown path")
        }
        // Authorize before revealing anything else, including whether the method is right.
        let (denied, via) = authorize(request)
        if let denied = denied { return denied }
        // Logs are for a person debugging, so a Mac with a wrong or old app still answers them: no app-version gate here.
        if request.path == "/logs" { return logs(request, via: via) }
        // The assist tools act on this Mac, so they are for this Mac's own tailnet user (or this Mac), never for the optional key.
        if AssistEndpoints.handles(request.path), via == .key {
            return .error(403, "assist_need_same_user", "the assist tools are only for this Mac and devices of its tailnet user")
        }
        if let refused = checkAppVersion(request) { return refused }
        if AssistEndpoints.handles(request.path) { return assist?.handle(request) ?? AssistEndpoints.notBuilt }
        guard request.method == wanted else {
            var r = HTTPResponse.error(405, "method_not_allowed", "use \(wanted)")
            r.headers["Allow"] = wanted
            return r
        }
        switch request.path {
        case "/status": return status()
        case "/peers": return peers(via: via)
        default: return postText(request)
        }
    }

    /// Who may use the daemon: this Mac itself, any device of the same tailnet user as this Mac's own node
    /// (asked of the local Tailscale), or anyone presenting the optional key. If Tailscale cannot say who is
    /// calling and there is no valid key, the request is refused.
    private enum Via { case loopback, sameUser, key }

    private func authorize(_ request: HTTPRequest) -> (HTTPResponse?, Via) {
        if request.fromLoopback { return (nil, .loopback) }
        var refusal: HTTPResponse
        if let peer = request.peerAddress, let identity = identity {
            switch identity.identify(peer) {
            case .sameUser: return (nil, .sameUser)
            case .otherUser(let login):
                refusal = .error(401, "unauthorized", "this device belongs to a different tailnet user (\(login)) than this Mac")
            case .unknown(let why):
                refusal = .error(503, "identity_unavailable", "could not verify who is calling (\(why)); refusing the request")
            }
        } else {
            refusal = .error(503, "identity_unavailable", "could not verify who is calling; refusing the request")
        }
        // The optional key is a second way in, for devices of other users.
        if let presented = request.headers["x-dictation-key"], !presented.isEmpty {
            if keys.verify(presented) == .ok { return (nil, .key) }
            return (.error(401, "unauthorized", "the key was wrong (the key file holds only a hash; use the key shown once by `key create`)"), .key)
        }
        return (refusal, .key)
    }

    /// The other Macs of this tailnet user that run the daemon, so a phone needs only one seed. Listing the tailnet is
    /// for this Mac's own user (or this Mac); a device that got in with the optional key may use /status and /text only.
    private func peers(via: Via) -> HTTPResponse {
        guard via != .key else {
            return .error(403, "peers_need_same_user", "the computer list is only shown to devices of this Mac's tailnet user")
        }
        let list = discovery?.computers() ?? []
        return .json(200, ["ok": true, "peers": list.map { $0.json }])
    }

    /// The app sends its own version in `X-Greenfield-App`. It is remembered (so health can report on the apps
    /// seen) and checked against the compatibility rule; a request without the header (curl, the selftest) is let through.
    private func checkAppVersion(_ request: HTTPRequest) -> HTTPResponse? {
        guard let v = request.headers["x-greenfield-app"], !v.isEmpty else { return nil }
        clients?.saw(version: v)
        let message: String, code: String
        switch Compat.judge(peer: v, me: version, minPeer: minClientVersion) {
        case .compatible: return nil
        case .peerTooOld:
            code = "app_too_old"
            message = "this app (\(v)) is too old for this Mac's daemon (\(version); oldest app it works with: \(minClientVersion)). Update the app."
        case .peerTooNew:
            code = "app_too_new"
            message = "this app (\(v)) is newer than this Mac's daemon (\(version)) supports. Update the Mac daemon."
        case .peerUnreadable:
            code = "app_version_unreadable"
            message = "X-Greenfield-App must be a version like 1.2.3, not \"\(v.prefix(40))\"."
        }
        var r = HTTPResponse.json(426, ["ok": false, "error": code, "message": message,
                                        "version": version, "min_client_version": minClientVersion])
        r.headers["Upgrade"] = "greenfield"
        return r
    }

    /// Same facts as /status plus what only the daemon itself can know, for `health` and `doctor`
    /// run on this Mac. No key needed because it answers loopback peers only and holds nothing secret.
    private func health(_ request: HTTPRequest) -> HTTPResponse {
        guard request.fromLoopback else { return .error(403, "local_only", "/health is only for requests from this Mac") }
        guard request.method == "GET" else { return .error(405, "method_not_allowed", "use GET") }
        var body = statusFields()
        body["pid"] = Int(ProcessInfo.processInfo.processIdentifier)
        body["executable"] = Bundle.main.executablePath ?? ""
        return .json(200, body)
    }

    /// The daemon's own recent log lines, redacted, newest last. Same tailnet-identity authorization as everything else, but not the
    /// optional key (a device of another tailnet user may insert text, not read this Mac's history); a limit on the number of
    /// requests and on the size of the answer. Unknown parameters, a missing log or a refused identity never fall back to "show it".
    private func logs(_ request: HTTPRequest, via: Via) -> HTTPResponse {
        guard request.method == "GET" else {
            var r = HTTPResponse.error(405, "method_not_allowed", "use GET")
            r.headers["Allow"] = "GET"
            return r
        }
        guard via != .key else {
            return .error(403, "logs_need_same_user", "logs are only shown to this Mac and to devices of its tailnet user")
        }
        guard let source = logSource, source.available else {
            return .error(404, "no_log", "this daemon has no log file to show")
        }
        let query: LogQuery
        switch LogQuery.parse(query: request.query) {
        case .success(let q): query = q
        case .failure(let e): return .error(400, "bad_request", e.message)
        }
        if let wait = logLimiter.admit(now: now()) {
            var r = HTTPResponse.error(429, "rate_limited", "too many log requests; try again in \(wait) seconds")
            r.headers["Retry-After"] = String(wait)
            return r
        }
        let page = LogPage.build(lines: source.read(query, now: now()), query: query)
        logger?.log("logs served lines=\(page.lines.count) bytes=\(page.bytes) truncated=\(page.truncated)")
        if query.plainText {
            return HTTPResponse(status: 200, headers: ["Content-Type": "text/plain; charset=utf-8", "X-Logs-Truncated": String(page.truncated),
                                                       "X-Logs-Count": String(page.lines.count)],
                                body: Data((page.lines.map { $0 + "\n" }.joined()).utf8))
        }
        return .json(200, [
            "ok": true, "service": RequestHandler.serviceName, "version": version, "name": name(),
            "generated_at": ISO8601DateFormatter().string(from: now()),
            "tail": query.tail, "since_s": query.since.map { Int($0) } ?? NSNull(),
            "count": page.lines.count, "bytes": page.bytes, "truncated": page.truncated, "lines": page.lines,
        ])
    }

    private func status() -> HTTPResponse { .json(200, statusFields()) }

    /// The delivery line for GET /status, in the shapes the phone reads: flat `can_insert` (bool),
    /// `delivery_message`, `delivery_fix`, and the same inside a `delivery` object. `evidence` is the raw record.
    private func deliveryFields() -> [String: Any] {
        let evidence = record?.canInsert() ?? CanInsert(state: .unknown, at: nil, source: nil, detail: "delivery is not tracked")
        let line = canInsertCheck(evidence, remote: false, onThatMac: "On the computer", bin: InserterDefaults.installedBinary)
        let ok = evidence.state == .ok
        var delivery: [String: Any] = [
            "ok": ok, "can_insert": ok, "state": evidence.state.rawValue,
            "message": line.detail, "text": line.detail, "fix": line.fix,
        ]
        if let at = evidence.at { delivery["at"] = ISO8601DateFormatter().string(from: at) }
        if let source = evidence.source { delivery["source"] = source }
        return ["can_insert": ok, "delivery_message": line.detail, "delivery_fix": line.fix,
                "delivery": delivery, "evidence": evidence.json]
    }

    private func statusFields() -> [String: Any] {
        insertLock.lock()
        let count = insertedCount
        insertLock.unlock()
        return [
            "ok": true,
            "service": RequestHandler.serviceName,
            "version": version,
            "min_client_version": minClientVersion,
            "build": ["version": build.version, "commit": build.commit, "binary_sha": build.binarySha,
                      "started_at": build.startedAt ?? ""],
            "app_compatible": AppCompat.evaluate(clients?.recent() ?? [], me: version, minClient: minClientVersion).json,
            "clients": (clients?.recent() ?? []).map { ["version": $0.version, "at": ISO8601DateFormatter().string(from: $0.at)] },
            "name": name(),
            "uptime_s": Int(now().timeIntervalSince(started)),
            "secure_input": probe.secureInputEnabled,
            "screen_locked": probe.screenLocked,
            "accessibility": probe.accessibilityTrusted,
            "accessibility_at_start": probe.accessibilityAtStart,
            "inserted_count": count,
            "listen": listening(),
            "auth": "tailnet",
            "key_configured": keys.verify(nil) != .notConfigured,
            "tailnet_user": identity?.selfLogin() ?? NSNull(),
            "identity_ok": identity?.selfLogin() != nil,
            "assist": assist?.statusJSON() ?? AssistEndpoints.offStatusJSON,
            "logs_available": logSource?.available ?? false,
            "logs": ["route": "/logs", "max_lines": LogQuery.maxTail, "max_bytes": LogPage.maxBytes],
        ].merging(deliveryFields()) { _, new in new }
    }

    private func postText(_ request: HTTPRequest) -> HTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return .error(400, "bad_request", "body must be a JSON object")
        }
        guard let id = (object["id"] as? String) ?? request.headers["x-request-id"], !id.isEmpty, id.count <= 128 else {
            return .error(400, "bad_request", "id is required (string, up to 128 characters)")
        }
        guard let text = object["text"] as? String, !text.isEmpty else {
            return .error(400, "bad_request", "text is required and must not be empty")
        }
        guard text.utf8.count <= RequestHandler.maxTextBytes else {
            return .error(413, "too_large", "text too large")
        }
        var method: InsertMethod?
        if let raw = object["method"] {
            guard let s = raw as? String, let m = InsertMethod(rawValue: s) else {
                return .error(400, "bad_request", "method must be \"paste\" or \"type\"")
            }
            method = m
        }
        let source = (object["source"] as? String).map { LogSafe.source($0) } ?? "unknown"

        let logID = LogSafe.id(id)

        // One request at a time: a concurrent retry of the same id waits here and then
        // finds the first attempt's result in the cache.
        insertLock.lock()
        defer { insertLock.unlock() }

        if let previous = dedupe.lookup(id) {
            var body = (try? JSONSerialization.jsonObject(with: previous.body) as? [String: Any]) ?? ["ok": true]
            body["duplicate"] = true
            logger?.log("text id=\(logID) source=\(source) duplicate")
            return .json(200, body)
        }
        if probe.screenLocked {
            logger?.log("text id=\(logID) source=\(source) refused: screen locked")
            return .error(423, "screen_locked", "the screen is locked")
        }
        if probe.secureInputEnabled {
            logger?.log("text id=\(logID) source=\(source) refused: secure input")
            return .error(409, "secure_input", "secure input is on (a password field is focused)")
        }
        if !probe.accessibilityTrusted {
            logger?.log("text id=\(logID) source=\(source) refused: no accessibility permission")
            return .error(503, "accessibility_not_granted", "grant Accessibility to greenfield-inserter in System Settings")
        }
        do {
            let used = try inserter.insert(text, method: method)
            insertedCount += 1
            if used.delivery == .confirmed { record?.recordSuccess(source: "delivery") }
            logger?.log("text id=\(logID) source=\(source) sent chars=\(text.count) method=\(used.method.rawValue) delivery=\(used.delivery.rawValue)")
            let response = HTTPResponse.json(200, [
                "ok": true, "id": id, "chars": text.count, "method": used.method.rawValue,
                "delivery": used.delivery.rawValue,
            ])
            dedupe.remember(id, response)
            return response
        } catch InsertError.accessibilityNotGranted {
            return .error(503, "accessibility_not_granted", "grant Accessibility to greenfield-inserter in System Settings")
        } catch InsertError.notDelivered {
            record?.recordFailure(source: "delivery", detail: "the focused field did not change after the keys were sent")
            logger?.log("text id=\(logID) source=\(source) not delivered: the focused field did not change")
            return .error(502, "not_delivered", "the keys were sent but the focused field did not change; nothing was inserted")
        } catch {
            logger?.log("text id=\(logID) source=\(source) failed: \(error)")
            return .error(500, "insert_failed", "could not insert the text")
        }
    }
}
