import Foundation
import CryptoKit
import Security

/// A browser (the PWA) that has paired with this Mac. The token itself is never kept: only its SHA-256.
public struct PairedDevice: Equatable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var expiresAt: Date
    public var lastSeen: Date?

    public var json: [String: Any] {
        let f = ISO8601DateFormatter()
        var o: [String: Any] = ["id": id, "name": name, "created_at": f.string(from: createdAt), "expires_at": f.string(from: expiresAt)]
        o["last_seen"] = lastSeen.map { f.string(from: $0) } ?? NSNull()
        return o
    }
}

public struct PairingCode: Equatable {
    /// Shown as `ABCD-EFGH`; compared without the dash and in upper case.
    public var code: String
    public var expiresIn: Int
}

public enum PairOutcome: Equatable {
    case paired(token: String, device: PairedDevice)
    /// The code is wrong, used, expired, or burned by too many wrong guesses. One answer for all of them: a guesser learns nothing.
    case refused
    /// Too many attempts in a short time; the seconds to wait.
    case slowDown(Int)
}

/// One-time pairing of a device that is not on the tailnet: the person at this Mac asks for a short code, the device exchanges it
/// for a scoped token. The token is short-lived, belongs to one device and can be revoked. It reaches `/status` and `/text` only;
/// never the computer list, the logs or the assist tools (the same limits as the optional key).
public protocol DevicePairing: AnyObject {
    func issueCode() -> PairingCode
    func redeem(code: String, device: String) -> PairOutcome
    /// The device that holds `token`, if it is valid now; remembers that it was seen.
    func verify(token: String) -> PairedDevice?
    func devices() -> [PairedDevice]
    @discardableResult func revoke(id: String) -> Bool
    @discardableResult func revokeAll() -> Int
}

/// The in-memory book. A restart of the daemon forgets every code and every token: pairing again is the safe default, and nothing
/// secret ever reaches a disk.
public final class PairingBook: DevicePairing {
    public static let codeTTL: TimeInterval = 5 * 60
    public static let tokenTTL: TimeInterval = 24 * 60 * 60
    public static let maxWrongGuesses = 5
    public static let maxDevices = 16
    /// No 0/O/1/I/L: a code read aloud or from a screen cannot be mistyped into another valid one.
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    private struct Live {
        var code: String
        var expires: Date
        var wrong: Int
    }

    private struct Entry {
        var device: PairedDevice
        var hash: [UInt8]
    }

    private let lock = NSLock()
    private let now: () -> Date
    private let random: (Int) -> [UInt8]
    private let limiter: LogRateLimiter
    private var live: Live?
    private var entries: [Entry] = []

    public init(now: @escaping () -> Date = Date.init, random: @escaping (Int) -> [UInt8] = PairingBook.secureRandom,
                limiter: LogRateLimiter = LogRateLimiter(limit: 10, window: 60)) {
        self.now = now
        self.random = random
        self.limiter = limiter
    }

    public static func secureRandom(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        // A failure to get secure random bytes must never fall back to something guessable.
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { fatalError("no secure random bytes") }
        return bytes
    }

    /// Upper case, without spaces and dashes.
    static func normalize(_ code: String) -> String {
        String(code.uppercased().filter { $0.isLetter || $0.isNumber })
    }

    public func issueCode() -> PairingCode {
        lock.lock(); defer { lock.unlock() }
        // Rejection sampling: 248 is the largest multiple of the alphabet size below 256, so every symbol is equally likely.
        var chars: [Character] = []
        let limit = 256 - (256 % PairingBook.alphabet.count)
        while chars.count < 8 {
            for b in random(16) where Int(b) < limit && chars.count < 8 { chars.append(PairingBook.alphabet[Int(b) % PairingBook.alphabet.count]) }
        }
        let raw = String(chars)
        // A new code replaces the old one: at most one is live.
        live = Live(code: raw, expires: now().addingTimeInterval(PairingBook.codeTTL), wrong: 0)
        return PairingCode(code: String(raw.prefix(4)) + "-" + String(raw.suffix(4)), expiresIn: Int(PairingBook.codeTTL))
    }

    public func redeem(code: String, device: String) -> PairOutcome {
        if let wait = limiter.admit(now: now()) { return .slowDown(wait) }
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        guard var current = live, current.expires > now() else { live = nil; return .refused }
        guard constantTimeEqual(Array(PairingBook.normalize(code).utf8), Array(current.code.utf8)) else {
            current.wrong += 1
            // Enough wrong guesses burn the code: it has to be asked for again at this Mac.
            live = current.wrong >= PairingBook.maxWrongGuesses ? nil : current
            return .refused
        }
        // One use only.
        live = nil
        if entries.count >= PairingBook.maxDevices { entries.removeFirst(entries.count - PairingBook.maxDevices + 1) }
        let token = Data(random(32)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let id = Data(random(6)).map { String(format: "%02x", $0) }.joined()
        let created = now()
        let record = PairedDevice(id: id, name: PairingBook.cleanName(device), createdAt: created,
                                  expiresAt: created.addingTimeInterval(PairingBook.tokenTTL), lastSeen: nil)
        entries.append(Entry(device: record, hash: PairingBook.digest(token)))
        return .paired(token: token, device: record)
    }

    public func verify(token: String) -> PairedDevice? {
        let presented = PairingBook.digest(token)
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        // Compare against every entry (there are few) so the time does not say which one matched.
        var found: Int?
        for (i, e) in entries.enumerated() where constantTimeEqual(presented, e.hash) { found = i }
        guard let i = found else { return nil }
        entries[i].device.lastSeen = now()
        return entries[i].device
    }

    public func devices() -> [PairedDevice] {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        return entries.map(\.device)
    }

    @discardableResult
    public func revoke(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let before = entries.count
        entries.removeAll { $0.device.id == id }
        return entries.count < before
    }

    @discardableResult
    public func revokeAll() -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = entries.count
        entries = []
        live = nil
        return n
    }

    private func pruneLocked() {
        let t = now()
        entries.removeAll { $0.device.expiresAt <= t }
        if let l = live, l.expires <= t { live = nil }
    }

    static func digest(_ token: String) -> [UInt8] { Array(SHA256.hash(data: Data(token.utf8))) }

    /// A device name for a list: printable, one line, at most 40 characters; "browser" when nothing usable is left.
    static func cleanName(_ raw: String) -> String {
        let one = String(raw.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7f ? " " : Character($0) })
            .trimmingCharacters(in: .whitespaces)
        return one.isEmpty ? "browser" : String(one.prefix(40))
    }
}

/// Headers a reverse proxy adds. A request that carries one did not come from the person at this Mac even when its TCP peer is
/// loopback (`tailscale serve`, the PWA's own server): it is never treated as local, and only a paired device's token lets it in.
public enum ProxiedRequest {
    static let headers = ["x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "x-real-ip", "forwarded",
                          "tailscale-user-login", "tailscale-user-name", "tailscale-funnel-request"]

    public static func isProxied(_ request: HTTPRequest) -> Bool { headers.contains { request.headers[$0] != nil } }
}
