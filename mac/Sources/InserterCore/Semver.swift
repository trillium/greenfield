import Foundation

/// A MAJOR.MINOR.PATCH version. The daemon's own comes from the git tags (GeneratedVersion.swift).
public struct Semver: Equatable, Comparable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) { self.major = major; self.minor = minor; self.patch = patch }

    /// Accepts "1.2.3", "v1.2.3" and "1.2.3+4.gabc" (build metadata is ignored); anything else is nil.
    public init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") { t.removeFirst() }
        if let plus = t.firstIndex(of: "+") { t = String(t[..<plus]) }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]), a >= 0, b >= 0, c >= 0,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        self.init(a, b, c)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (l: Semver, r: Semver) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }
}

public enum BuildInfo {
    public static var version: String { StampedBuild.version }
    public static var fullVersion: String { StampedBuild.fullVersion }
    public static var build: String { StampedBuild.build }
    public static var commit: String { StampedBuild.commit }
    /// The oldest app this daemon accepts (declared in mac/min-client-version).
    public static var minClientVersion: String { StampedBuild.minClientVersion }
}

/// The compatibility rule (docs/mac-contract.md): while MAJOR is 0 the MINOR must match; from 1.0.0 the MAJOR
/// must match; each side also names the oldest peer it works with.
public enum Compat {
    public enum Verdict: Equatable {
        case compatible
        /// The peer is older than our minimum, or on an older line than us.
        case peerTooOld
        /// The peer is on a newer line than us.
        case peerTooNew
        case peerUnreadable
    }

    public static func sameLine(_ a: Semver, _ b: Semver) -> Bool {
        if a.major != b.major { return false }
        return a.major == 0 ? a.minor == b.minor : true
    }

    public static func judge(peer: String, me: String, minPeer: String) -> Verdict {
        guard let p = Semver(peer), let m = Semver(me), let floor = Semver(minPeer) else { return .peerUnreadable }
        if p < floor { return .peerTooOld }
        if sameLine(p, m) { return .compatible }
        return p < m ? .peerTooOld : .peerTooNew
    }
}
