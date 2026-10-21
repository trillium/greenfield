import Foundation
import CryptoKit

/// Identifies the build that is actually running, so health and doctor can tell it apart from the file
/// on disk: a daemon that was updated on disk but never restarted still reports the old build.
public enum RunningBuild {
    public static let startedAt = Date()

    public static func sha256Prefix(ofFile path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Computed once: the executable cannot change under a running process.
    public static let identity: BuildIdentity = {
        let exe = Bundle.main.executablePath ?? ""
        return BuildIdentity(version: BuildInfo.version, commit: BuildInfo.commit,
                             binarySha: sha256Prefix(ofFile: exe) ?? "unknown",
                             startedAt: ISO8601DateFormatter().string(from: startedAt))
    }()
}
