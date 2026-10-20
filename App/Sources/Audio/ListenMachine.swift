import Foundation

/// Decides what the microphone should be doing, from events, with no AVFoundation or UIKit in it so every path is unit-tested.
/// The audio owner feeds it the user's taps, scene changes and the audio session's notifications, then carries out the actions.
/// Every transition returns the Log lines to write (`state:` prefix), so the file on the phone is a record of this machine.
struct ListenMachine: Equatable, Sendable {
    enum Scene: String, Equatable, Sendable {
        case foreground, background
    }

    /// What the user asked for and whether the mic is delivering it.
    enum Mode: Equatable, Sendable {
        case off
        case listening
        /// Wanted, but the mic is gone (call, Siri, another app, route or format change). A resume is scheduled, or the system says when.
        case interrupted(String)
        /// Wanted, and every resume attempt failed. Retried when the app is opened, the interruption ends, or the user taps.
        case gaveUp(String)
    }

    /// What the screen shows.
    enum Status: Equatable, Sendable {
        case off, listening, backgrounded
        case interrupted(String)
        case gaveUp(String)
    }

    enum Event: Equatable, Sendable {
        /// The microphone is running because the user asked for it.
        case started
        case stopped
        case scene(Scene)
        case interruptionBegan(reason: String)
        case interruptionEnded(shouldResume: Bool)
        /// The engine stopped by itself (route or format change, media services reset) without an interruption.
        case captureLost(reason: String)
        case routeChanged(reason: String)
        /// The user tapped while interrupted or after giving up.
        case retryRequested
        case resumeSucceeded
        case resumeFailed(String)
    }

    enum Action: Equatable, Sendable {
        /// Try to bring the mic back after the delay; replaces any attempt already waiting.
        case resume(after: TimeInterval)
        case cancelResume
        /// Flush the endpointer so a half-spoken utterance is cut at the loss, not spliced onto what comes after.
        case flushUtterance
    }

    struct Outcome: Equatable, Sendable {
        var actions: [Action] = []
        var log: [String] = []
    }

    /// Wait before resume attempt 1, 2, 3...; after the last one the machine gives up until something changes.
    static let backoff: [TimeInterval] = [0.5, 1, 2, 4, 8, 15, 30]

    private(set) var mode: Mode = .off
    private(set) var scene: Scene = .foreground
    /// Failed resume attempts in a row.
    private(set) var failedAttempts = 0

    var status: Status {
        switch mode {
        case .off: return .off
        case .listening: return scene == .background ? .backgrounded : .listening
        case .interrupted(let reason): return .interrupted(reason)
        case .gaveUp(let reason): return .gaveUp(reason)
        }
    }

    /// The mic is delivering audio now.
    var isCapturing: Bool { mode == .listening }
    /// The user has asked to listen and has not stopped: a tap should stop it. False after giving up, where a tap tries again.
    var isWanted: Bool {
        switch mode {
        case .listening, .interrupted: return true
        case .off, .gaveUp: return false
        }
    }

    mutating func handle(_ event: Event) -> Outcome {
        switch event {
        case .started: return start()
        case .stopped: return stop()
        case .scene(let next): return changeScene(to: next)
        case .interruptionBegan(let reason): return interruptionBegan(reason)
        case .interruptionEnded(let shouldResume): return interruptionEnded(shouldResume: shouldResume)
        case .captureLost(let reason): return captureLost(reason)
        case .routeChanged(let reason): return routeChanged(reason)
        case .retryRequested: return requestRetry()
        case .resumeSucceeded: return resumeSucceeded()
        case .resumeFailed(let message): return resumeFailed(message)
        }
    }

    private mutating func start() -> Outcome {
        guard mode != .listening else { return Outcome() }
        mode = .listening
        failedAttempts = 0
        return Outcome(actions: [.cancelResume], log: ["microphone started (\(scene.rawValue))"])
    }

    private mutating func stop() -> Outcome {
        guard mode != .off else { return Outcome() }
        mode = .off
        failedAttempts = 0
        return Outcome(actions: [.cancelResume], log: ["microphone stopped"])
    }

    private mutating func changeScene(to next: Scene) -> Outcome {
        guard next != scene else { return Outcome() }
        scene = next
        let out = Outcome(log: ["app \(next == .background ? "backgrounded" : "foregrounded"), \(describe(mode))"])
        guard next == .foreground else { return out }
        // Opening the app is the best moment to ask for the mic back: the system allows it and a person is looking.
        switch mode {
        case .interrupted: return retry(out, why: "app opened")
        case .gaveUp(let reason):
            mode = .interrupted(reason)
            return retry(out, why: "app opened")
        case .off, .listening: return out
        }
    }

    private mutating func interruptionBegan(_ reason: String) -> Outcome {
        guard mode != .off else { return Outcome() }
        var out = Outcome()
        if mode == .listening { out.actions.append(.flushUtterance) }
        mode = .interrupted(reason)
        failedAttempts = 0
        out.actions.append(.cancelResume)
        out.log.append("interrupted: \(reason) (\(scene.rawValue))")
        return out
    }

    /// Resumes whether or not the system says to: the user asked for a mic that stays on, and the system refuses the activation if
    /// someone else still holds the mic, which the retries then ride out.
    private mutating func interruptionEnded(shouldResume: Bool) -> Outcome {
        switch mode {
        case .off, .listening: return Outcome()
        case .interrupted(let reason), .gaveUp(let reason):
            mode = .interrupted(reason)
            failedAttempts = 0
            return Outcome(actions: [.resume(after: Self.backoff[0])],
                           log: ["interruption ended, system says \(shouldResume ? "resume" : "do not resume (trying anyway)")"])
        }
    }

    private mutating func captureLost(_ reason: String) -> Outcome {
        guard mode == .listening else { return Outcome() }
        mode = .interrupted(reason)
        failedAttempts = 0
        return Outcome(actions: [.flushUtterance, .resume(after: 0)], log: ["microphone lost: \(reason) (\(scene.rawValue))"])
    }

    private mutating func routeChanged(_ reason: String) -> Outcome {
        let out = Outcome(log: ["route changed: \(reason)"])
        guard case .gaveUp(let last) = mode else { return out }
        mode = .interrupted(last)
        return retry(out, why: "route changed")
    }

    private mutating func requestRetry() -> Outcome {
        switch mode {
        case .off, .listening: return Outcome()
        case .interrupted(let reason), .gaveUp(let reason):
            mode = .interrupted(reason)
            return retry(Outcome(), why: "requested")
        }
    }

    private mutating func resumeSucceeded() -> Outcome {
        guard case .interrupted = mode else { return Outcome() }
        mode = .listening
        let tries = failedAttempts > 0 ? " after \(failedAttempts) failed \(failedAttempts == 1 ? "try" : "tries")" : ""
        failedAttempts = 0
        return Outcome(log: ["microphone resumed\(tries) (\(scene.rawValue))"])
    }

    private mutating func resumeFailed(_ message: String) -> Outcome {
        guard case .interrupted(let reason) = mode else { return Outcome() }
        failedAttempts += 1
        guard failedAttempts < Self.backoff.count else {
            mode = .gaveUp(reason)
            return Outcome(log: ["gave up resuming after \(failedAttempts) tries (\(message)); "
                                 + "retries when the app is opened or the interruption ends"])
        }
        let wait = Self.backoff[failedAttempts]
        let log = "resume attempt \(failedAttempts) failed (\(message)), next in \(Self.seconds(wait)) s"
        return Outcome(actions: [.resume(after: wait)], log: [log])
    }

    private mutating func retry(_ out: Outcome, why: String) -> Outcome {
        var out = out
        failedAttempts = 0
        out.log.append("resuming microphone (\(why))")
        out.actions.append(.resume(after: 0))
        return out
    }

    private func describe(_ mode: Mode) -> String {
        switch mode {
        case .off: return "microphone off"
        case .listening: return "microphone still running"
        case .interrupted(let reason): return "microphone interrupted (\(reason))"
        case .gaveUp(let reason): return "microphone lost (\(reason))"
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
