import Foundation

/// A MAJOR.MINOR.PATCH version. Build metadata (`+3.gabc`) and a leading `v` are ignored; anything else that is not three numbers is nil.
struct Semver: Comparable, Equatable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ text: String?) {
        guard var text = text?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasPrefix("v") { text.removeFirst() }
        let core = text.split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, let major = parts[0], let minor = parts[1], let patch = parts[2],
              parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        self.init(major, minor, patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: Semver, rhs: Semver) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// The compatibility rule (docs/mac-contract.md): while MAJOR is 0 the MINOR must match; from 1.0.0 the MAJOR must match.
    func isCompatible(with other: Semver) -> Bool {
        guard major == other.major else { return false }
        return major != 0 || minor == other.minor
    }
}

/// The phone's side of the compatibility contract. The app sends its own version in `X-Greenfield-App` on every request and declares
/// the oldest agent version it works with (`GreenfieldMinPeerVersion`, set in Config/Base.xcconfig); the agent reports its `version`
/// and `min_client_version` in `GET /status`. Both sides apply the same rule.
enum Compatibility {
    static let appHeader = "X-Greenfield-App"

    enum Verdict: Equatable, Sendable {
        case compatible
        case updateAgent
        case updateApp
    }

    /// The app's own version, from the git tag (`MARKETING_VERSION`), never typed in.
    static var appVersion: Semver? { Semver(BuildInfo().version) }

    /// The oldest agent version this app works with.
    static var minimumAgent: Semver? { Semver(Bundle.main.object(forInfoDictionaryKey: "GreenfieldMinPeerVersion") as? String) }

    /// Who has to update. An agent that states no version predates this contract. A newer-than-us agent that the rule rejects means the
    /// app is behind; an older one that the rule rejects means the agent is.
    static func judge(app: Semver?, agent: String?, minClient: String?, minimumAgent: Semver?) -> Verdict {
        guard let app else { return .compatible }
        if let minClient = Semver(minClient), app < minClient { return .updateApp }
        guard let agent = Semver(agent) else { return .updateAgent }
        // The floor describes the line this app was cut from, so it only speaks for a build at or above it. A working build from an
        // untagged checkout stamps itself 0.0.1, and telling such a build to update every Mac it meets is a false red state.
        if let minimumAgent, minimumAgent <= app, agent < minimumAgent { return .updateAgent }
        if app.isCompatible(with: agent) { return .compatible }
        return agent > app ? .updateApp : .updateAgent
    }
}
