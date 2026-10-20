import Foundation

public enum InsertMethod: String {
    case paste
    case type
}

public enum InsertError: Error, Equatable {
    case accessibilityNotGranted
    case failed(String)
}

public protocol TextInserter {
    /// Inserts text at the cursor of the focused app. `method` nil means the default
    /// (paste, falling back to typed key events).
    func insert(_ text: String, method: InsertMethod?) throws -> InsertMethod
}

public protocol SystemProbe {
    var secureInputEnabled: Bool { get }
    var screenLocked: Bool { get }
    var accessibilityTrusted: Bool { get }
}

public protocol RequestLogger {
    /// Never receives inserted text; only metadata.
    func log(_ message: String)
}

/// The daemon's whole HTTP surface, free of sockets and OS calls so it can be unit tested.
/// Other input sources use the same two routes: they differ only in the optional `source`.
public final class RequestHandler {
    public static let serviceName = "greenfield-inserter"
    public static let version = "0.1.0"
    public static let maxTextBytes = 256 * 1024

    private let keys: KeyVerifier
    private let probe: SystemProbe
    private let inserter: TextInserter
    private let dedupe: DedupeCache
    private let name: () -> String
    private let listening: () -> [String]
    private let logger: RequestLogger?
    private let started: Date
    private let now: () -> Date
    private let insertLock = NSLock()
    private var insertedCount = 0

    public init(keys: KeyVerifier, probe: SystemProbe, inserter: TextInserter, dedupe: DedupeCache = DedupeCache(),
                name: @escaping () -> String, listening: @escaping () -> [String] = { [] },
                logger: RequestLogger? = nil, now: @escaping () -> Date = Date.init) {
        self.keys = keys
        self.probe = probe
        self.inserter = inserter
        self.dedupe = dedupe
        self.name = name
        self.listening = listening
        self.logger = logger
        self.now = now
        self.started = now()
    }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        let response = route(request)
        logger?.log("\(request.method) \(request.path) -> \(response.status)")
        return response
    }

    private func route(_ request: HTTPRequest) -> HTTPResponse {
        let known = ["/status": "GET", "/text": "POST"]
        guard let wanted = known[request.path] else {
            return .error(404, "not_found", "unknown path")
        }
        // Authenticate before revealing anything else, including whether the method is right.
        switch keys.verify(request.headers["x-dictation-key"]) {
        case .ok: break
        case .mismatch: return .error(401, "unauthorized", "missing or wrong X-Dictation-Key")
        case .notConfigured:
            return .error(503, "key_not_configured", "no key set on this Mac; run `greenfield-inserter key create`")
        }
        guard request.method == wanted else {
            var r = HTTPResponse.error(405, "method_not_allowed", "use \(wanted)")
            r.headers["Allow"] = wanted
            return r
        }
        return request.path == "/status" ? status() : postText(request)
    }

    private func status() -> HTTPResponse {
        insertLock.lock()
        let count = insertedCount
        insertLock.unlock()
        return .json(200, [
            "ok": true,
            "service": RequestHandler.serviceName,
            "version": RequestHandler.version,
            "name": name(),
            "uptime_s": Int(now().timeIntervalSince(started)),
            "secure_input": probe.secureInputEnabled,
            "screen_locked": probe.screenLocked,
            "accessibility": probe.accessibilityTrusted,
            "inserted_count": count,
            "listen": listening(),
        ])
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
        let source = (object["source"] as? String).map { String($0.prefix(32)) } ?? "unknown"

        // One request at a time: a concurrent retry of the same id waits here and then
        // finds the first attempt's result in the cache.
        insertLock.lock()
        defer { insertLock.unlock() }

        if let previous = dedupe.lookup(id) {
            var body = (try? JSONSerialization.jsonObject(with: previous.body) as? [String: Any]) ?? ["ok": true]
            body["duplicate"] = true
            logger?.log("text id=\(id) source=\(source) duplicate")
            return .json(200, body)
        }
        if probe.screenLocked {
            logger?.log("text id=\(id) source=\(source) refused: screen locked")
            return .error(423, "screen_locked", "the screen is locked")
        }
        if probe.secureInputEnabled {
            logger?.log("text id=\(id) source=\(source) refused: secure input")
            return .error(409, "secure_input", "secure input is on (a password field is focused)")
        }
        if !probe.accessibilityTrusted {
            logger?.log("text id=\(id) source=\(source) refused: no accessibility permission")
            return .error(503, "accessibility_not_granted", "grant Accessibility to greenfield-inserter in System Settings")
        }
        do {
            let used = try inserter.insert(text, method: method)
            insertedCount += 1
            logger?.log("text id=\(id) source=\(source) inserted chars=\(text.count) method=\(used.rawValue)")
            let response = HTTPResponse.json(200, [
                "ok": true, "id": id, "chars": text.count, "method": used.rawValue,
            ])
            dedupe.remember(id, response)
            return response
        } catch InsertError.accessibilityNotGranted {
            return .error(503, "accessibility_not_granted", "grant Accessibility to greenfield-inserter in System Settings")
        } catch {
            logger?.log("text id=\(id) source=\(source) failed: \(error)")
            return .error(500, "insert_failed", "could not insert the text")
        }
    }
}
