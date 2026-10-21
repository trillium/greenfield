import XCTest
import KitAssist
@testable import InserterCore

/// The kit's recorded assist fixtures (the phone's tests read the same files). The kit is found the same way Package.swift finds it.
enum KitFixtures {
    static let directory: URL = {
        let mac = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["PARROT_KIT_DIR"], !env.isEmpty { candidates.append(env) }
        candidates.append(mac.appendingPathComponent("../../parrot-kit").standardized.path)
        candidates.append(NSHomeDirectory() + "/code/parrot-kit")
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate + "/Tests/Fixtures/assist") {
            return URL(fileURLWithPath: candidate).appendingPathComponent("Tests/Fixtures/assist")
        }
        fatalError("the kit's Tests/Fixtures/assist is not found; set PARROT_KIT_DIR")
    }()

    static func data(_ path: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(path)) }

    static func object(_ path: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data(path)) as? [String: Any])
    }

    static func names(in folder: String, prefix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(folder).path)
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }.sorted()
    }
}

final class FakeWindowProvider: WindowProvider {
    var value: WindowListing
    var activation: Activation = .asked
    /// When true a successful request moves the front to the target, like a system that obeys.
    var obeys = true
    var requested: [KitAssist.WindowRef] = []
    var reads = 0
    var onRead: (() -> Void)?

    init(_ value: WindowListing = WindowListing(apps: [])) { self.value = value }

    func listing() -> WindowListing {
        reads += 1
        onRead?()
        return value
    }

    func bringForward(_ target: KitAssist.WindowRef) -> Activation {
        requested.append(target)
        if case .asked = activation, obeys {
            var ref = target
            if ref.windowId == nil { ref.windowId = value.apps.first { $0.appId == target.appId }?.windows.first?.windowId }
            value.frontmost = ref
        }
        return activation
    }
}

/// The tailnet addresses the tests use: 100.64.0.20 is a device of this Mac's own user, .99 belongs to someone else, anything else is unknown.
final class FakeIdentity: TailnetIdentity {
    func identify(_ address: String) -> PeerIdentity {
        switch address {
        case "100.64.0.20": return .sameUser(login: "me@example")
        case "100.64.0.99": return .otherUser(login: "them@example")
        default: return .unknown("no such node")
        }
    }
    func selfLogin() -> String? { "me@example" }
}

final class MutableSettings: AssistSettingsSource {
    var settings: AssistSettings
    init(_ settings: AssistSettings = .off) { self.settings = settings }
    func current() -> AssistSettings { settings }
}

final class ManualClock {
    var now: TimeInterval = 1000
    func advance(_ seconds: TimeInterval) { now += seconds }
}

func listing(_ apps: [AppInfo], front: KitAssist.WindowRef? = nil) -> WindowListing { WindowListing(apps: apps, frontmost: front) }

func app(_ id: String, _ name: String, windows: [WindowInfo] = [], pid: Int? = nil) -> AppInfo {
    AppInfo(appId: id, name: name, pid: pid ?? abs(id.hashValue % 9000) + 100, windows: windows)
}

func window(_ id: String, _ title: String = "", main: Bool = false) -> WindowInfo { WindowInfo(windowId: id, title: title, main: main) }

func decode<T: Decodable>(_ type: T.Type, _ response: HTTPResponse) throws -> T {
    try JSONDecoder().decode(type, from: response.body)
}

func jsonObject(_ response: HTTPResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:]
}
