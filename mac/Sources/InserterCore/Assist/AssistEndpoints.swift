import Foundation
import KitAssist

/// The routes of the assist tools. `RequestHandler` has already decided WHO may call (tailnet identity; a caller that only holds the
/// optional key never gets here) and checked the app's version; this decides what is allowed and answers.
///
/// | Route | |
/// |---|---|
/// | `GET /assist/windows?since=&epoch=` | the apps and windows, or `unchanged` |
/// | `POST /assist/windows/focus` | bring an app or window to the front |
/// | `POST /assist/pointer/session` | open a pointer session: a random session id and the key that tags its datagrams |
///
/// Window titles and names are never logged: the log gets counts and the result.
public final class AssistEndpoints {
    public static let listPath = WindowsContract.listPath
    public static let focusPath = WindowsContract.focusPath
    public static let pointerPath = "/assist/pointer/session"
    public static let paths: [String: String] = [listPath: "GET", focusPath: "POST", pointerPath: "POST"]

    private let settings: AssistSettingsSource
    private let windows: WindowService?
    private let pointer: PointerService?
    private let endpoint: () -> (address: String, port: UInt16)?
    private let logger: RequestLogger?
    private let clock: () -> TimeInterval
    private let listLimit = RateLimit(perSecond: 10, burst: 20)

    public init(settings: AssistSettingsSource, windows: WindowService?, pointer: PointerService?,
                endpoint: @escaping () -> (address: String, port: UInt16)? = { nil }, logger: RequestLogger? = nil,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.settings = settings
        self.windows = windows
        self.pointer = pointer
        self.endpoint = endpoint
        self.logger = logger
        self.clock = clock
    }

    /// The `assist` object of `GET /status`: what the phone may offer right now. `enabled` is the master switch on this Mac; `windows` and
    /// `pointer` say the tool's routes answer (a tool that is off, or that this build cannot do, is false).
    public func statusJSON() -> [String: Any] {
        let current = settings.current()
        var names: [String] = []
        if current.windowsAvailable, windows != nil, current.titles { names.append("windowTitles") }
        if current.pointerAvailable, let pointer = pointer {
            if pointer.capabilities.contains(.zoom) { names.append("zoom") }
            if pointer.capabilities.contains(.swipeShortcuts) { names.append("swipeShortcuts") }
            if pointer.capabilities.contains(.nativeMomentum) { names.append("nativeMomentum") }
        }
        return ["enabled": current.enabled, "windows": current.windowsAvailable && windows != nil,
                "pointer": current.pointerAvailable && pointer != nil, "capabilities": names]
    }

    /// What a daemon built without the assist tools answers on their routes.
    static var notBuilt: HTTPResponse { .error(404, "assist_off", "this daemon has no assist tools") }

    public static var offStatusJSON: [String: Any] { ["enabled": false, "windows": false, "pointer": false, "capabilities": [String]()] }

    /// True when the route is one of ours.
    public static func handles(_ path: String) -> Bool { paths[path] != nil }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        if request.method != Self.paths[request.path] {
            var r = HTTPResponse.error(405, "method_not_allowed", "use \(Self.paths[request.path] ?? "GET")")
            r.headers["Allow"] = Self.paths[request.path]
            return r
        }
        let current = settings.current()
        switch request.path {
        case Self.pointerPath:
            guard current.pointerAvailable, let pointer = pointer else { return unavailable() }
            return openPointer(request, pointer)
        case Self.focusPath:
            guard current.windowsAvailable, let windows = windows else { return unavailable() }
            return focus(request, windows)
        default:
            guard current.windowsAvailable, let windows = windows else { return unavailable() }
            return list(request, windows)
        }
    }

    /// Assist is off, or this Mac has no support for the tool: the phone hides it.
    private func unavailable() -> HTTPResponse {
        .error(404, "assist_off", "this Mac has not turned this assist tool on (greenfield-inserter assist on)")
    }

    private func json<T: Encodable>(_ status: Int, _ value: T) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    // MARK: Windows

    private func list(_ request: HTTPRequest, _ service: WindowService) -> HTTPResponse {
        var since: (epoch: String, rev: Int)?
        let items = URLComponents(string: "?" + request.query)?.queryItems ?? []
        let epoch = items.first { $0.name == "epoch" }?.value, rev = items.first { $0.name == "since" }?.value
        if epoch != nil || rev != nil {
            guard let epoch = epoch, epoch.count <= 64, let rev = rev, let number = Int(rev), number >= 0 else {
                return .error(400, "bad_request", "since must be a number and epoch a short string, and both are needed together")
            }
            since = (epoch, number)
        }
        guard listLimit.allow(at: clock()) else { return tooMany(listLimit.retryAfter) }
        switch service.list(since: since) {
        case .secureInput:
            logger?.log("assist windows list refused: secure input")
            return .error(409, "secure_input", "secure input is on (a password field is in use); the list is paused")
        case let .unchanged(epoch, rev):
            logger?.log("assist windows list unchanged rev=\(rev)")
            return json(200, WindowsResponse.unchanged(epoch: epoch, rev: rev))
        case let .snapshot(snapshot):
            let counts = WindowService.counts(snapshot)
            logger?.log("assist windows list apps=\(counts.apps) windows=\(counts.windows) rev=\(snapshot.rev) locked=\(snapshot.locked)")
            return json(200, WindowsResponse.snapshot(snapshot))
        }
    }

    private func focus(_ request: HTTPRequest, _ service: WindowService) -> HTTPResponse {
        guard request.body.count <= WindowsContract.maxRequestBytes else {
            return .error(413, "too_large", "the body is at most \(WindowsContract.maxRequestBytes) bytes")
        }
        guard let parsed = try? JSONDecoder().decode(FocusRequest.self, from: request.body), Self.idsAreBounded(parsed.target), parsed.rev >= 0 else {
            return .error(400, "bad_request", "the body is not a focus request (format, action, ids and rev)")
        }
        switch service.focus(parsed) {
        case let .tooMany(retryAfter): return tooMany(retryAfter)
        case let .answer(answer):
            logger?.log("assist windows focus action=\(Self.action(parsed.target)) result=\(Self.resultName(answer.result)) rev=\(answer.rev)")
            return json(200, answer)
        }
    }

    private static func idsAreBounded(_ target: FocusTarget) -> Bool {
        switch target {
        case .previous: return true
        case let .app(appId): return appId.count <= 256
        case let .window(appId, windowId): return appId.count <= 256 && windowId.count <= 256
        }
    }

    public static func action(_ target: FocusTarget) -> String {
        switch target {
        case .app: return "app"
        case .window: return "window"
        case .previous: return "previous"
        }
    }

    public static func resultName(_ result: FocusResult) -> String {
        switch result {
        case .ok: return "ok"
        case .declined: return "declined"
        case .notFound: return "notFound"
        case .denied: return "denied"
        case .locked: return "locked"
        case .unsupported: return "unsupported"
        case .pending: return "pending"
        case .unknown: return "unknown"
        }
    }

    private func tooMany(_ retryAfter: Int) -> HTTPResponse {
        var r = HTTPResponse.error(429, "rate_limited", "too many requests; try again in \(retryAfter) seconds")
        r.headers["Retry-After"] = String(retryAfter)
        return r
    }

    // MARK: Pointer

    private func openPointer(_ request: HTTPRequest, _ service: PointerService) -> HTTPResponse {
        guard request.body.count <= WindowsContract.maxRequestBytes else {
            return .error(413, "too_large", "the body is at most \(WindowsContract.maxRequestBytes) bytes")
        }
        // The caller is whoever the authenticated HTTP route saw; datagrams are accepted from that address only.
        let caller = request.fromLoopback ? "loopback" : (request.peerAddress ?? "")
        guard !caller.isEmpty else { return .error(503, "identity_unavailable", "could not tell who is calling") }
        switch service.open(caller: caller, now: clock()) {
        case let .failure(error):
            switch error {
            case .disabled: return unavailable()
            case .locked: return .error(423, "screen_locked", "the screen is locked")
            case let .rateLimited(retryAfter): return tooMany(retryAfter)
            case .tooManySessions: return .error(429, "too_many_sessions", "this Mac already has the most pointer sessions it allows")
            case .noListener: return .error(503, "no_listener", "the Mac could not open its pointer port (is Tailscale running?)")
            }
        case let .success(offer):
            guard let target = endpoint() else { return .error(503, "no_listener", "the Mac could not open its pointer port (is Tailscale running?)") }
            return .json(200, [
                "ok": true, "format": 1, "session": Int(offer.session), "key": offer.key.base64EncodedString(),
                "tag": ["algorithm": "hmac-sha256", "length": PointerAuthenticator.tagBytes],
                "udp": ["address": target.address, "port": Int(target.port)],
                "idle_timeout_s": Int(offer.idleTimeout), "max_lifetime_s": Int(offer.maxLifetime),
                "capabilities": Int(offer.capabilities.rawValue),
            ])
        }
    }
}
