import Foundation
import Observation

/// Sends queued texts by itself. While anything is waiting it asks the active computer for its status, and as soon as that says it can
/// actually insert text it retries everything queued (oldest first). While it cannot, it checks again after a growing pause
/// (5 s, 10 s, 20 s ... at most 2 minutes), so a computer that comes back is found without anyone tapping Retry and a dead one is not
/// hammered.
@MainActor
@Observable
final class AutoRetry {
    struct Timing: Equatable {
        var first = 5.0
        var factor = 2.0
        var maximum = 120.0
        /// How often to look at an empty outbox.
        var idlePoll = 5.0
    }

    typealias Pause = @Sendable (Double) async -> Void

    private(set) var interval: Double
    /// When the next check will happen while something is queued (for the screen).
    private(set) var nextCheck: Date?
    private(set) var lastReason: String?

    private let service: DeliveryService
    private let log: EventLog?
    private let timing: Timing
    private let pause: Pause
    private let app: Semver?
    private let minimumAgent: Semver?
    private var task: Task<Void, Never>?

    init(service: DeliveryService, log: EventLog?, timing: Timing = Timing(), app: Semver? = Compatibility.appVersion,
         minimumAgent: Semver? = Compatibility.minimumAgent,
         pause: @escaping Pause = { try? await Task.sleep(for: .seconds($0)) }) {
        self.service = service
        self.log = log
        self.timing = timing
        self.app = app
        self.minimumAgent = minimumAgent
        self.pause = pause
        interval = timing.first
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let waiting = await self.runOnce()
                let wait = waiting ? self.interval : self.timing.idlePoll
                self.nextCheck = waiting ? Date().addingTimeInterval(wait) : nil
                await self.pause(wait)
                await Task.yield()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        nextCheck = nil
    }

    /// One look. Returns true while something is still queued afterwards (so the caller should wait `interval` before the next look).
    @discardableResult
    func runOnce() async -> Bool {
        let queued = service.outbox.pending
        guard !queued.isEmpty else {
            interval = timing.first
            lastReason = nil
            return false
        }
        guard let target = service.targets.selected else {
            note("no computer is chosen")
            return grow()
        }
        let answer = await service.health(of: target)
        guard let blocker = blocker(in: answer) else {
            log?.add(.send, "auto-retry: \(target.name) can insert text, retrying \(queued.count) queued")
            lastReason = nil
            await service.resendAll()
            if service.outbox.pending.isEmpty {
                interval = timing.first
                return false
            }
            return grow()
        }
        note("\(target.name): \(blocker)")
        return grow()
    }

    private func grow() -> Bool {
        interval = min(interval * timing.factor, timing.maximum)
        return true
    }

    /// Logs a reason once, not on every look.
    private func note(_ reason: String) {
        guard reason != lastReason else { return }
        lastReason = reason
        log?.add(.send, "auto-retry waiting: \(reason)")
    }

    /// Why the computer cannot take text right now, or nil when it can.
    func blocker(in health: ReceiverClient.Health) -> String? {
        switch health {
        case .unreachable(let reason): return "not reachable (\(reason))"
        case .wrongKey: return "it will not take text from this phone"
        case .keyNotSetOnMac: return "its input agent is not set up yet"
        case .incompatible(let message): return message
        case .ready(let status):
            let verdict = Compatibility.judge(app: app, agent: status.version, minClient: status.minClientVersion,
                                              minimumAgent: minimumAgent)
            if verdict != .compatible { return "app and agent versions do not match" }
            if !status.accessibility { return "needs Accessibility approval" }
            if status.locked { return "its screen is locked" }
            if status.secureInput { return "a password field is focused" }
            if let line = status.delivery, !line.works { return "cannot insert text (\(line.message))" }
            return nil
        }
    }
}
