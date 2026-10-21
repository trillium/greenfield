import Foundation
import KitCore

/// This app's side of the compatibility contract (the rule and the verdict are KitCore's: `Semver`, `Compatibility.judge`). The app sends
/// its own version in `X-Greenfield-App` on every request and declares the oldest agent version it works with
/// (`GreenfieldMinPeerVersion`, set in Config/Base.xcconfig); the agent reports its `version` and `min_client_version` in `GET /status`.
enum AppVersion {
    static let header = "X-Greenfield-App"

    /// The app's own version, from the git tag (`MARKETING_VERSION`), never typed in.
    static var current: Semver? { Semver(BuildInfo().version) }

    /// The oldest agent version this app works with.
    static var minimumAgent: Semver? { Semver(Bundle.main.object(forInfoDictionaryKey: "GreenfieldMinPeerVersion") as? String) }

    /// Who has to update, for one agent's `GET /status` answer.
    static func verdict(for status: ReceiverClient.MacStatus, app: Semver? = current,
                        minimumAgent: Semver? = minimumAgent) -> Compatibility.Verdict {
        Compatibility.judge(app: app, peer: status.version, peerMinimumOfApp: status.minClientVersion, minimumPeer: minimumAgent)
    }
}
