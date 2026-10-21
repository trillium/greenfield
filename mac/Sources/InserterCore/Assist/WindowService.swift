import Foundation
import CryptoKit
import KitAssist

/// What the operating system says right now, in no particular order. The real one is `MacWindowProvider`; tests use a fake.
public struct WindowListing: Equatable {
    public var apps: [AppInfo]
    public var frontmost: WindowRef?
    public init(apps: [AppInfo], frontmost: WindowRef? = nil) {
        self.apps = apps
        self.frontmost = frontmost
    }
}

/// How the system took a request to bring something forward. It does not say whether the thing is in front: the service checks that.
public enum Activation: Equatable {
    case asked
    /// The system or the provider refused outright; `reason` is a short sentence.
    case refused(String)
    /// This Mac cannot do it (a window on another desktop).
    case unsupported(String)
}

public protocol WindowProvider {
    /// The apps and windows now. Must be safe to call from any thread.
    func listing() -> WindowListing
    /// Asks the system to bring the app or window forward. Does not wait.
    func bringForward(_ target: WindowRef) -> Activation
}

/// The bounds that keep an answer small however many windows a Mac has or however long a title is.
public struct WindowLimits: Equatable {
    public var maxApps = 200
    public var maxWindowsPerApp = 64
    public var maxWindows = 600
    public var maxNameCharacters = 120
    public var maxTitleCharacters = 240
    /// All titles together; once spent, later windows are listed without a title.
    public var maxTitleCharactersTotal = 40_000
    public var maxIdCharacters = 256
    /// Reading the list again within this long returns the last reading (polling phones cost the Mac one read).
    public var cacheSeconds = 0.25
    /// How long a focus request waits for the system to put the thing in front.
    public var settleSeconds = 0.8
    public var settleStepSeconds = 0.05
    public init() {}
}

public enum WindowListOutcome: Equatable {
    case snapshot(WindowsSnapshot)
    case unchanged(epoch: String, rev: Int)
    /// A password field is in use (secure input): nothing is listed.
    case secureInput
}

public enum WindowFocusOutcome: Equatable {
    case answer(FocusResponse)
    /// Too many requests, or one activation is already in flight.
    case tooMany(retryAfter: Int)
}

/// The window switcher's brain, free of the operating system: it owns the order (most recently used first), the revision counter, the
/// bounds and the rules about when to refuse, and it only ever answers with what is true after looking again.
public final class WindowService {
    public let epoch: String
    private let provider: WindowProvider
    private let probe: SystemProbe
    private let settings: AssistSettingsSource
    private let computerName: () -> String
    private let limits: WindowLimits
    private let clock: () -> TimeInterval
    private let sleeper: (TimeInterval) -> Void
    private let actions: RateLimit

    private let lock = NSLock()
    private var order: [String] = []
    private var history: [WindowRef] = []
    private var rev = 0
    private var fingerprint: String?
    private var cached: (at: TimeInterval, snapshot: WindowsSnapshot)?
    private let activation = NSLock()

    public init(provider: WindowProvider, probe: SystemProbe, settings: AssistSettingsSource, computerName: @escaping () -> String,
                limits: WindowLimits = WindowLimits(), epoch: String = WindowService.newEpoch(),
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                actionsPerSecond: Double = 10, actionBurst: Double = 20) {
        self.provider = provider
        self.probe = probe
        self.settings = settings
        self.computerName = computerName
        self.limits = limits
        self.epoch = epoch
        self.clock = clock
        self.sleeper = sleeper
        actions = RateLimit(perSecond: actionsPerSecond, burst: actionBurst)
    }

    public static func newEpoch() -> String {
        var bytes = [UInt8](repeating: 0, count: 3)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "e-" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: List

    public func list(since: (epoch: String, rev: Int)?) -> WindowListOutcome {
        let locked = probe.screenLocked
        if !locked, probe.secureInputEnabled { return .secureInput }
        let snapshot = current(locked: locked, fresh: false)
        if let since = since, since.epoch == snapshot.epoch, since.rev == snapshot.rev { return .unchanged(epoch: snapshot.epoch, rev: snapshot.rev) }
        return .snapshot(snapshot)
    }

    /// What the log may say about a list answer: counts only.
    public static func counts(_ snapshot: WindowsSnapshot) -> (apps: Int, windows: Int) {
        (snapshot.apps.count, snapshot.apps.reduce(0) { $0 + $1.windows.count })
    }

    private func current(locked: Bool, fresh: Bool) -> WindowsSnapshot {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        if !fresh, let cached = cached, now - cached.at < limits.cacheSeconds, cached.snapshot.locked == locked { return cached.snapshot }
        let snapshot = build(provider.listing(), locked: locked)
        cached = (now, snapshot)
        return snapshot
    }

    /// Orders by recent use, bounds sizes, drops titles when they may not leave, and counts a revision when anything visible changed.
    private func build(_ listing: WindowListing, locked: Bool) -> WindowsSnapshot {
        observe(listing)
        let allowTitles = settings.current().titles && !locked
        var windowsLeft = limits.maxWindows, titleBudget = limits.maxTitleCharactersTotal
        let byId = Dictionary(listing.apps.map { ($0.appId, $0) }, uniquingKeysWith: { first, _ in first })
        var apps: [AppInfo] = []
        for appId in order.prefix(limits.maxApps) {
            guard var app = byId[appId] else { continue }
            app.name = clip(app.name, limits.maxNameCharacters)
            if locked {
                app.windows = []
                app.otherSpaceWindows = nil
            } else {
                app.windows = app.windows.prefix(min(limits.maxWindowsPerApp, windowsLeft)).filter { $0.windowId.count <= limits.maxIdCharacters }.map { window in
                    var window = window
                    if allowTitles, titleBudget > 0 {
                        window.title = clip(window.title, min(limits.maxTitleCharacters, titleBudget))
                        titleBudget -= window.title.count
                    } else {
                        window.title = ""
                    }
                    return window
                }
                windowsLeft -= app.windows.count
            }
            apps.append(app)
        }
        var snapshot = WindowsSnapshot(epoch: epoch, rev: 0, locked: locked, computer: clip(computerName(), limits.maxNameCharacters),
                                       frontmost: locked ? nil : listing.frontmost, apps: apps)
        let print = Self.fingerprint(of: snapshot)
        if print != fingerprint {
            fingerprint = print
            rev += 1
        }
        snapshot.rev = rev
        return snapshot
    }

    private static func fingerprint(of snapshot: WindowsSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(snapshot)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Keeps the most-recently-used order: the front app moves to the head, apps that quit leave, apps not seen before join at the end in
    /// the order the system gave them. `history` remembers what was in front before, for "previous".
    private func observe(_ listing: WindowListing) {
        let present = Set(listing.apps.map(\.appId))
        order.removeAll { !present.contains($0) }
        for app in listing.apps where !order.contains(app.appId) { order.append(app.appId) }
        if let front = listing.frontmost, present.contains(front.appId) {
            order.removeAll { $0 == front.appId }
            order.insert(front.appId, at: 0)
            if history.first != front {
                history.removeAll { $0 == front }
                history.insert(front, at: 0)
                if history.count > 16 { history.removeLast() }
            }
        }
    }

    private func clip(_ text: String, _ count: Int) -> String {
        text.count <= count ? text : String(text.prefix(max(0, count - 1))) + "…"
    }

    // MARK: Focus

    public func focus(_ request: FocusRequest) -> WindowFocusOutcome {
        let locked = probe.screenLocked
        if locked { return .answer(reply(.locked, "The Mac is locked.")) }
        if probe.secureInputEnabled {
            return .answer(reply(.denied, "A password field is in use on the Mac (secure input is on), so switching is paused."))
        }
        guard settings.current().focus else { return .answer(reply(.denied, "Switching windows is turned off on this Mac.")) }
        guard actions.allow(at: clock()) else { return .tooMany(retryAfter: actions.retryAfter) }
        // One activation at a time: a second request while one is settling is told to wait, never queued behind it.
        guard activation.try() else { return .tooMany(retryAfter: 1) }
        defer { activation.unlock() }

        let before = current(locked: false, fresh: true)
        guard let target = resolve(request.target, in: before) else {
            let reason: String
            switch request.target {
            case .previous: reason = "There is nothing to go back to."
            case .app: reason = "That app is no longer open."
            case .window: reason = "That window is gone."
            }
            return .answer(reply(.notFound, reason, snapshot: before))
        }
        switch provider.bringForward(target) {
        case let .refused(reason): return .answer(reply(.declined, reason, snapshot: before))
        case let .unsupported(reason): return .answer(reply(.unsupported, reason, snapshot: before))
        case .asked: break
        }

        // Never answer ok because the request arrived: look until the front is what was asked for, for a short bounded time.
        var waited = 0.0, after = before
        while true {
            after = current(locked: probe.screenLocked, fresh: true)
            if isFront(target, in: after) { return .answer(reply(.ok, nil, snapshot: after)) }
            if waited >= limits.settleSeconds { break }
            sleeper(limits.settleStepSeconds)
            waited += limits.settleStepSeconds
        }
        let name = byAppName(target.appId, in: after)
        if after.frontmost == before.frontmost {
            return .answer(reply(.declined, "The system did not bring \(name) forward.", snapshot: after))
        }
        return .answer(reply(.pending, nil, snapshot: after))
    }

    private func reply(_ result: FocusResult, _ reason: String?, snapshot: WindowsSnapshot? = nil) -> FocusResponse {
        let snapshot = snapshot ?? current(locked: probe.screenLocked, fresh: false)
        return FocusResponse(result: result, reason: reason, rev: snapshot.rev, frontmost: snapshot.frontmost)
    }

    private func byAppName(_ appId: String, in snapshot: WindowsSnapshot) -> String {
        let name = snapshot.apps.first { $0.appId == appId }?.name ?? ""
        return name.isEmpty ? "that app" : name
    }

    /// Looks the target up in what is true now. Never a similar thing: an id that is gone is gone.
    private func resolve(_ target: FocusTarget, in snapshot: WindowsSnapshot) -> WindowRef? {
        switch target {
        case let .app(appId):
            return snapshot.apps.contains { $0.appId == appId } ? WindowRef(appId: appId) : nil
        case let .window(appId, windowId):
            guard let app = snapshot.apps.first(where: { $0.appId == appId }), app.windows.contains(where: { $0.windowId == windowId }) else { return nil }
            return WindowRef(appId: appId, windowId: windowId)
        case .previous:
            lock.lock(); defer { lock.unlock() }
            for ref in history where ref != snapshot.frontmost {
                guard let app = snapshot.apps.first(where: { $0.appId == ref.appId }) else { continue }
                if let windowId = ref.windowId {
                    if app.windows.contains(where: { $0.windowId == windowId }) { return ref }
                } else {
                    return ref
                }
            }
            return nil
        }
    }

    private func isFront(_ target: WindowRef, in snapshot: WindowsSnapshot) -> Bool {
        guard let front = snapshot.frontmost, front.appId == target.appId else { return false }
        guard let windowId = target.windowId else { return true }
        return front.windowId == windowId
    }
}
