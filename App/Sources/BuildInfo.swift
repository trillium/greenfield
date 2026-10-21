import Foundation

/// Version and build number as shown on screen, so a tester can say exactly which TestFlight build they have.
struct BuildInfo: Equatable {
    let version: String
    let build: String

    init(info: [String: Any]) {
        version = info["CFBundleShortVersionString"] as? String ?? "?"
        build = info["CFBundleVersion"] as? String ?? "?"
    }

    init(bundle: Bundle = .main) {
        self.init(info: bundle.infoDictionary ?? [:])
    }

    var display: String { "v\(version) (\(build))" }
}
