import Foundation
import CryptoKit
import Security

public enum KeyCheck: Equatable {
    case ok
    case mismatch
    case notConfigured
}

public protocol KeyVerifier {
    func verify(_ presented: String?) -> KeyCheck
}

/// Per-Mac configuration directory. Holds the key hash (never the key itself) and the display name.
public struct InserterPaths {
    public var directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> InserterPaths {
        if let override = environment["GREENFIELD_INSERTER_HOME"], !override.isEmpty {
            return InserterPaths(directory: URL(fileURLWithPath: override, isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return InserterPaths(directory: home.appendingPathComponent(".config/greenfield-inserter", isDirectory: true))
    }

    public var keyFile: URL { directory.appendingPathComponent("key") }
    public var nameFile: URL { directory.appendingPathComponent("name") }
    public var logFile: URL { directory.appendingPathComponent("inserter.log") }
    public var localTokenFile: URL { directory.appendingPathComponent("local-token") }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}

public enum KeyStoreError: Error, CustomStringConvertible {
    case alreadyExists
    case randomFailed
    case io(String)

    public var description: String {
        switch self {
        case .alreadyExists: return "a key already exists (use --force to replace it; the old key stops working)"
        case .randomFailed: return "could not read secure random bytes"
        case .io(let m): return m
        }
    }
}

/// Stores only a SHA-256 of the key in a 0600 file, so the key can be shown once at creation
/// and can never be read back off disk. The file is re-read when it changes, so rotating the
/// key needs no daemon restart.
public final class FileKeyStore: KeyVerifier {
    public let paths: InserterPaths
    private let lock = NSLock()
    private var cached: (mtime: Date, hash: Data)?

    public init(paths: InserterPaths) { self.paths = paths }

    public var isConfigured: Bool { loadHash() != nil }

    /// Normalizes what a human might paste: surrounding whitespace and dashes/spaces in groups.
    static func normalize(_ key: String) -> String {
        key.filter { !$0.isWhitespace && $0 != "-" }.lowercased()
    }

    static func digest(_ key: String) -> Data {
        Data(SHA256.hash(data: Data(normalize(key).utf8)))
    }

    /// Generates a new key, writes its hash, and returns the key for one-time display.
    public func create(force: Bool) throws -> String {
        try paths.ensureDirectory()
        var bytes = [UInt8](repeating: 0, count: 20)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KeyStoreError.randomFailed
        }
        let key = Base32.encode(bytes)
        let line = "sha256:" + FileKeyStore.digest(key).map { String(format: "%02x", $0) }.joined() + "\n"
        let path = paths.keyFile.path
        if force {
            let tmp = path + ".tmp"
            unlink(tmp)
            try write(line, to: tmp, excl: true)
            guard rename(tmp, path) == 0 else { throw KeyStoreError.io("rename failed: errno \(errno)") }
        } else {
            try write(line, to: path, excl: true)
        }
        return key
    }

    private func write(_ text: String, to path: String, excl: Bool) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            if errno == EEXIST { throw KeyStoreError.alreadyExists }
            throw KeyStoreError.io("cannot write \(path): errno \(errno)")
        }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        guard Darwin.write(fd, bytes, bytes.count) == bytes.count else { throw KeyStoreError.io("short write") }
    }

    private func loadHash() -> Data? {
        let url = paths.keyFile
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let c = cached, c.mtime == mtime { return c.hash }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sha256:"), let hash = Data(hex: String(trimmed.dropFirst(7))), hash.count == 32 else {
            return nil
        }
        cached = (mtime, hash)
        return hash
    }

    public func verify(_ presented: String?) -> KeyCheck {
        guard let stored = loadHash() else { return .notConfigured }
        guard let presented = presented, !presented.isEmpty, presented.count <= 256 else { return .mismatch }
        return constantTimeEqual(Array(FileKeyStore.digest(presented)), Array(stored)) ? .ok : .mismatch
    }
}

func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[i] ^ b[i] }
    return diff == 0
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        self = out
    }
}

enum Base32 {
    static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    static func encode(_ bytes: [UInt8]) -> String {
        var out = ""
        var buffer = 0, bits = 0
        for b in bytes {
            buffer = (buffer << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }
}

/// The friendly name the phone shows for this Mac: a saved name, else the hostname.
public struct MacName {
    public let paths: InserterPaths
    public init(paths: InserterPaths) { self.paths = paths }

    public func current() -> String {
        if let saved = try? String(contentsOf: paths.nameFile, encoding: .utf8) {
            let t = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return MacName.hostname()
    }

    public func set(_ name: String) throws {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 64 else { throw KeyStoreError.io("name must be 1-64 characters") }
        try paths.ensureDirectory()
        try t.write(to: paths.nameFile, atomically: true, encoding: .utf8)
    }

    public func clear() { try? FileManager.default.removeItem(at: paths.nameFile) }

    public static func hostname() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return "mac" }
        let full = String(cString: buf)
        return full.split(separator: ".").first.map(String.init) ?? full
    }
}

/// A throwaway credential the daemon makes for itself each time it starts and writes to a 0600 file.
/// It is accepted only from requests that arrive over loopback, so tools on this Mac that can read
/// the file (the same user) can talk to the daemon without ever seeing the real key.
public enum LocalToken {
    public static func create(paths: InserterPaths) throws -> String {
        try paths.ensureDirectory()
        var bytes = [UInt8](repeating: 0, count: 20)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw KeyStoreError.randomFailed }
        let token = Base32.encode(bytes)
        let tmp = paths.localTokenFile.path + ".tmp"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw KeyStoreError.io("cannot write \(tmp): errno \(errno)") }
        let line = Array((token + "\n").utf8)
        let ok = Darwin.write(fd, line, line.count) == line.count
        close(fd)
        guard ok, rename(tmp, paths.localTokenFile.path) == 0 else { throw KeyStoreError.io("could not save the local token") }
        return token
    }

    public static func read(paths: InserterPaths) -> String? {
        guard let t = try? String(contentsOf: paths.localTokenFile, encoding: .utf8) else { return nil }
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
