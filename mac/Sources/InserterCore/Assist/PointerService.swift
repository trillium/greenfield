import Foundation
import KitAssist

/// What a phone gets back when it opens a pointer session over the authenticated HTTP route.
public struct PointerSessionOffer: Equatable {
    public var session: UInt32
    /// 32 random bytes, shown once, never logged, never stored on disk. Every datagram of the session carries a tag made with it.
    public var key: Data
    public var idleTimeout: TimeInterval
    public var maxLifetime: TimeInterval
    public var capabilities: AssistCapabilities
}

public enum PointerOpenError: Error, Equatable {
    case disabled
    case locked
    case rateLimited(retryAfter: Int)
    case tooManySessions
    /// The datagram socket could not be opened (no tailnet address).
    case noListener
}

/// The datagram socket, opened only while at least one session exists and closed when the last one ends. The pointer service asks for
/// it; the transport never opens anything by itself.
public protocol PointerListener: AnyObject {
    /// Opens the socket on the tailnet address. False when it cannot.
    func start() -> Bool
    func stop()
    /// "address:port" the phone should send to; nil while closed.
    var endpoint: (address: String, port: UInt16)? { get }
}

public struct PointerLimits: Equatable {
    /// No valid datagram for this long ends the session.
    public var idleTimeout: TimeInterval = 30
    /// A session ends this long after it was opened, however busy it is; the phone opens a new one.
    public var maxLifetime: TimeInterval = 3600
    public var maxSessions = 4
    /// Datagrams per second per session, and the burst: 240 frames a second is four times a phone's touch rate.
    public var datagramsPerSecond = 240.0
    public var datagramBurst = 480.0
    /// Sessions opened per second overall, and the burst.
    public var opensPerSecond = 0.2
    public var openBurst = 3.0
    public var maxDatagramBytes = 512
    /// How often the lock screen and the settings are looked at when datagrams are flowing.
    public var checkInterval: TimeInterval = 0.25
    public init() {}
}

/// The pointer receiver. Everything a datagram has to pass before it can move the cursor:
///
/// 1. a session opened over the authenticated HTTP route (tailnet identity; a caller who only has the optional key is refused there);
/// 2. the sender's address is the one that opened it;
/// 3. the tag under that session's own random key, checked before anything else is parsed;
/// 4. the kit's strict codec, then its sequence rules (replays and late datagrams are dropped);
/// 5. a rate limit; and the kill switch, the locked screen and 30 seconds of silence end the session at once.
///
/// Nothing is ever answered to a datagram that fails 1 to 3. The sink only sees what survived.
public final class PointerService {
    private final class Session {
        let id: UInt32
        let caller: String
        let authenticator: PointerAuthenticator
        var receiver: TPT1Receiver
        let opened: TimeInterval
        var lastHeard: TimeInterval
        let bucket: RateLimit
        init(id: UInt32, caller: String, key: Data, receiver: TPT1Receiver, now: TimeInterval, bucket: RateLimit) {
            self.id = id
            self.caller = caller
            authenticator = PointerAuthenticator(key: key)
            self.receiver = receiver
            opened = now
            lastHeard = now
            self.bucket = bucket
        }
    }

    /// Why a datagram was dropped, for the counters (the log shows counts only).
    public enum Drop: String, CaseIterable {
        case malformed, unknownSession, wrongSource, authentication, rateLimited, rejected
    }

    private let settings: AssistSettingsSource
    private let probe: SystemProbe
    private let sink: PointerSink
    private let listener: PointerListener
    private let limits: PointerLimits
    private let logger: RequestLogger?
    private let random: (Int) -> Data
    private let opens: RateLimit

    private let lock = NSLock()
    private var sessions: [UInt32: Session] = [:]
    private var drops: [Drop: Int] = [:]
    private var dropsLogged: TimeInterval = 0
    private var dropsLoggedTotal = 0
    private var checked: TimeInterval = -.infinity
    private var allowed = false
    private var locked = false

    public init(settings: AssistSettingsSource, probe: SystemProbe, sink: PointerSink, listener: PointerListener, limits: PointerLimits = PointerLimits(),
                logger: RequestLogger? = nil, random: @escaping (Int) -> Data = PointerService.secureRandom) {
        self.settings = settings
        self.probe = probe
        self.sink = sink
        self.listener = listener
        self.limits = limits
        self.logger = logger
        self.random = random
        opens = RateLimit(perSecond: limits.opensPerSecond, burst: limits.openBurst)
    }

    public static func secureRandom(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            // No randomness means no key: stop rather than hand out something guessable.
            fatalError("could not read secure random bytes")
        }
        return Data(bytes)
    }

    public var activeSessions: Int {
        lock.lock(); defer { lock.unlock() }
        return sessions.count
    }

    public var capabilities: AssistCapabilities { sink.capabilities }

    public func dropCount(_ reason: Drop) -> Int {
        lock.lock(); defer { lock.unlock() }
        return drops[reason, default: 0]
    }

    // MARK: Opening

    /// `caller` is who the authenticated HTTP route saw: the tailnet address, or "loopback". A new session for the same caller replaces
    /// the old one.
    public func open(caller: String, now: TimeInterval) -> Result<PointerSessionOffer, PointerOpenError> {
        lock.lock(); defer { lock.unlock() }
        let current = settings.current()
        guard current.pointerAvailable else { return .failure(.disabled) }
        if probe.screenLocked { return .failure(.locked) }
        guard opens.allow(at: now) else { return .failure(.rateLimited(retryAfter: opens.retryAfter)) }
        let replaced = sessions.values.filter { $0.caller == caller }
        if sessions.count - replaced.count >= limits.maxSessions { return .failure(.tooManySessions) }
        for old in replaced { end(old, reason: "replaced") }

        if sessions.isEmpty, !listener.start() { return .failure(.noListener) }
        var id: UInt32
        repeat {
            id = random(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        } while id == 0 || sessions[id] != nil
        let key = random(PointerAuthenticator.keyBytes)
        let receiver = TPT1Receiver(session: id, capabilities: sink.capabilities)
        sessions[id] = Session(id: id, caller: caller, key: key, receiver: receiver, now: now,
                               bucket: RateLimit(perSecond: limits.datagramsPerSecond, burst: limits.datagramBurst))
        checked = -.infinity
        logger?.log("assist pointer session opened active=\(sessions.count)")
        return .success(PointerSessionOffer(session: id, key: key, idleTimeout: limits.idleTimeout, maxLifetime: limits.maxLifetime,
                                            capabilities: sink.capabilities))
    }

    // MARK: Datagrams

    /// One datagram from `source` (an IPv4 address). Returns the datagram to send back, if any. Never throws and never answers anything
    /// that did not authenticate.
    public func receive(_ datagram: Data, from source: String, now: TimeInterval) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard datagram.count >= TPT1.headerLength + PointerAuthenticator.tagBytes, datagram.count <= limits.maxDatagramBytes,
              datagram.prefix(4).elementsEqual(TPT1.magic) else { return drop(.malformed) }
        let base = datagram.startIndex
        let id = (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(datagram[base + 6 + $1]) }
        guard let session = sessions[id] else { return drop(.unknownSession) }
        guard source == session.caller || (session.caller == "loopback" && source.hasPrefix("127.")) else { return drop(.wrongSource) }
        let packet: TPT1.Packet
        do {
            packet = try TPT1.decode(datagram, authenticator: session.authenticator)
        } catch TPT1.DecodeError.authenticationFailed {
            return drop(.authentication)
        } catch {
            return drop(.malformed)
        }
        guard session.bucket.allow(at: now) else { return drop(.rateLimited) }
        if refreshAndEndIfNeeded(now: now) { return nil }

        let outcome = session.receiver.receive(packet, now: now)
        if outcome.rejection != nil { return drop(.rejected) }
        session.lastHeard = now
        if !outcome.events.isEmpty { sink.apply(outcome.events) }
        if session.receiver.isClosed { end(session, reason: "goodbye", release: false) }
        return outcome.reply.map { TPT1.encode($0, authenticator: session.authenticator) }
    }

    private func drop(_ reason: Drop) -> Data? {
        drops[reason, default: 0] += 1
        return nil
    }

    // MARK: Time

    /// Call often (every 50 ms or so, whether or not datagrams are coming). Ends sessions that went quiet, ran out of lifetime, or lost
    /// their permission; releases buttons of a phone that vanished.
    public func tick(now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _ = refreshAndEndIfNeeded(now: now)
        for session in sessions.values {
            let events = session.receiver.expire(now: now)
            if !events.isEmpty { sink.apply(events) }
            if now - session.lastHeard >= limits.idleTimeout { end(session, reason: "idle") }
            else if now - session.opened >= limits.maxLifetime { end(session, reason: "lifetime") }
        }
        if !sessions.isEmpty, now - dropsLogged >= 10 { logDrops(now: now) }
    }

    /// Looks at the kill switch and the lock screen (at most `checkInterval` apart) and ends every session when either says stop.
    @discardableResult
    private func refreshAndEndIfNeeded(now: TimeInterval) -> Bool {
        if now - checked >= limits.checkInterval || now < checked {
            checked = now
            allowed = settings.current().pointerAvailable
            locked = probe.screenLocked
        }
        guard !sessions.isEmpty, !allowed || locked else { return false }
        endAllSessions(reason: locked ? "screen locked" : "assist off")
        return true
    }

    public func endAll(reason: String) {
        lock.lock(); defer { lock.unlock() }
        endAllSessions(reason: reason)
    }

    private func endAllSessions(reason: String) {
        for session in Array(sessions.values) { end(session, reason: reason) }
    }

    private func end(_ session: Session, reason: String, release: Bool = true) {
        guard sessions.removeValue(forKey: session.id) != nil else { return }
        // Whatever the phone held when it went away is let go.
        if release { sink.apply([.releaseAll]) }
        logger?.log("assist pointer session closed reason=\(reason) active=\(sessions.count)")
        if sessions.isEmpty { listener.stop() }
    }

    private func logDrops(now: TimeInterval) {
        dropsLogged = now
        let total = drops.values.reduce(0, +)
        guard total != dropsLoggedTotal else { return }
        dropsLoggedTotal = total
        let parts = Drop.allCases.compactMap { reason in drops[reason].map { $0 > 0 ? "\(reason.rawValue)=\($0)" : nil } ?? nil }
        if !parts.isEmpty { logger?.log("assist pointer datagrams dropped so far: " + parts.joined(separator: " ")) }
    }
}
