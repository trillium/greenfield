import Foundation

/// What the Mac's owner allows the assist tools (window switcher, trackpad) to do. Everything is off until it is turned on here, on this Mac:
/// a phone cannot widen it. The file is read again whenever it changes, so `greenfield-inserter assist off` takes effect at once, with no
/// restart. A missing, unreadable or malformed file means "off".
public struct AssistSettings: Equatable {
    /// The master switch (the kill switch). Default OFF.
    public var enabled = false
    /// Action class: list the apps and windows.
    public var windows = true
    /// Action class: bring an app or window to the front. Off leaves the list read-only.
    public var focus = true
    /// Action class: pointer sessions. Off by default even when assist is on, so turning the window switcher on never opens a pointer path.
    public var pointer = false
    /// Whether window titles leave this Mac. Off lists applications and windows without their titles.
    public var titles = true

    public init(enabled: Bool = false, windows: Bool = true, focus: Bool = true, pointer: Bool = false, titles: Bool = true) {
        self.enabled = enabled
        self.windows = windows
        self.focus = focus
        self.pointer = pointer
        self.titles = titles
    }

    public static let off = AssistSettings()

    /// The window routes answer (otherwise 404, and the phone hides the tool).
    public var windowsAvailable: Bool { enabled && windows }
    /// The pointer session route answers.
    public var pointerAvailable: Bool { enabled && pointer }

    var json: [String: Any] { ["enabled": enabled, "windows": windows, "focus": focus, "pointer": pointer, "titles": titles] }

    /// Unknown keys are ignored; a wrong type for a known key makes the whole file "off" rather than guessing.
    public static func parse(_ data: Data) -> AssistSettings {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .off }
        var settings = AssistSettings.off
        for (key, keyPath) in [("enabled", \AssistSettings.enabled), ("windows", \.windows), ("focus", \.focus),
                               ("pointer", \.pointer), ("titles", \.titles)] as [(String, WritableKeyPath<AssistSettings, Bool>)] {
            guard let raw = object[key] else { continue }
            // A number is not a switch: only a JSON true or false counts (NSNumber bridges 1 and 0 to Bool, so look at the type).
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return .off }
            settings[keyPath: keyPath] = number.boolValue
        }
        return settings
    }
}

public protocol AssistSettingsSource {
    func current() -> AssistSettings
}

/// Fixed settings, for tests and for a daemon started without a configuration directory.
public struct StaticAssistSettings: AssistSettingsSource {
    public var settings: AssistSettings
    public init(_ settings: AssistSettings = .off) { self.settings = settings }
    public func current() -> AssistSettings { settings }
}

public extension InserterPaths {
    var assistFile: URL { directory.appendingPathComponent("assist.json") }
}

/// `assist.json` in the configuration directory (mode 0600). Read afresh on every call, never cached: it is a few bytes, and a kill switch
/// must not be able to read stale.
public final class FileAssistSettings: AssistSettingsSource {
    public let paths: InserterPaths

    public init(paths: InserterPaths) { self.paths = paths }

    public func current() -> AssistSettings {
        (try? Data(contentsOf: paths.assistFile)).map(AssistSettings.parse) ?? .off
    }

    public func save(_ settings: AssistSettings) throws {
        try paths.ensureDirectory()
        let data = try JSONSerialization.data(withJSONObject: settings.json, options: [.prettyPrinted, .sortedKeys])
        let tmp = paths.assistFile.path + ".tmp"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw KeyStoreError.io("cannot write \(tmp): errno \(errno)") }
        defer { close(fd) }
        let bytes = [UInt8](data + Data("\n".utf8))
        guard Darwin.write(fd, bytes, bytes.count) == bytes.count else { throw KeyStoreError.io("short write to \(tmp)") }
        guard rename(tmp, paths.assistFile.path) == 0 else { throw KeyStoreError.io("could not replace \(paths.assistFile.path): errno \(errno)") }
    }

    /// Changes some switches and keeps the rest.
    @discardableResult
    public func update(_ change: (inout AssistSettings) -> Void) throws -> AssistSettings {
        var settings = current()
        change(&settings)
        try save(settings)
        return settings
    }
}

/// A token bucket: `burst` at once, refilled at `rate` per second. Safe to share between threads.
public final class RateLimit {
    private let rate: Double
    private let burst: Double
    private var tokens: Double
    private var last: TimeInterval?
    private let lock = NSLock()

    public init(perSecond: Double, burst: Double) {
        rate = perSecond
        self.burst = burst
        tokens = burst
    }

    /// True when one more is allowed at `now` (seconds on any steady clock).
    public func allow(at now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let last = last { tokens = min(burst, tokens + max(0, now - last) * rate) }
        last = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    /// Whole seconds until one more is allowed, at least 1.
    public var retryAfter: Int { max(1, Int((1 / max(rate, 0.001)).rounded(.up))) }
}
