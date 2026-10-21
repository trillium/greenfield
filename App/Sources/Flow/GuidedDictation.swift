import Foundation
import Observation

/// The first dictation, guided: "say hello, then say send it". It uses the real pipeline (microphone, Parakeet, the line-ender, delivery)
/// and ends in a plain pass or fail that says what was heard and, on a fail, what to do.
@MainActor
@Observable
final class GuidedDictation {
    enum Phase: Equatable {
        case idle
        case listening
        case checking
        case passed(String)
        case failed(String)
    }

    /// What the run needs from the app, so it can be tested without a microphone.
    struct Timing {
        var hearTimeout = 40.0
        var deliveryTimeout = 15.0
        var poll = 0.1
    }

    private(set) var phase: Phase = .idle
    private(set) var heard: String?
    private let flow: FlowController
    private let delivery: DeliveryService
    private let timing: Timing
    private var task: Task<Void, Never>?

    init(flow: FlowController, delivery: DeliveryService, timing: Timing = Timing()) {
        self.flow = flow
        self.delivery = delivery
        self.timing = timing
    }

    var computerName: String { delivery.targets.selected?.name ?? "the computer" }

    /// Starts recording and waits for the result. The phrase "send it" ends the recording by itself; Stop ends it by hand.
    func start() {
        task?.cancel()
        heard = nil
        guard flow.session.canHold else {
            phase = .failed("Not ready to listen yet: the microphone or the speech model is still starting. Wait a moment and try again.")
            return
        }
        let before = flow.lastHeard
        phase = .listening
        flow.toggleDictation()
        task = Task { [weak self] in await self?.watch(after: before) }
    }

    func stopByHand() {
        if flow.session.isHolding { flow.toggleDictation() }
    }

    func cancel() {
        task?.cancel()
        if flow.session.isHolding { flow.toggleDictation() }
        phase = .idle
    }

    private func watch(after before: FlowController.Heard?) async {
        let deadline = Date().addingTimeInterval(timing.hearTimeout)
        while flow.lastHeard == before, Date() < deadline, !Task.isCancelled { try? await Task.sleep(for: .seconds(timing.poll)) }
        guard !Task.isCancelled else { return }
        if flow.session.isHolding { flow.toggleDictation() }
        guard let result = flow.lastHeard, result != before else {
            phase = .failed("Nothing was heard. Check that the microphone is allowed, speak closer to the phone, and try again.")
            return
        }
        phase = .checking
        heard = result.raw
        let words = result.raw.lowercased()
        guard words.contains("hello") else {
            phase = .failed("I heard \"\(result.raw)\". Say hello first, then send it.")
            return
        }
        guard result.lineEnder != nil else {
            phase = .failed("I heard \"\(result.raw)\", but it did not end with \"send it\". Say send it as the last words.")
            return
        }
        await finish()
    }

    /// The phrase worked and the text was submitted: did the computer take it?
    private func finish() async {
        let deadline = Date().addingTimeInterval(timing.deliveryTimeout)
        while Date() < deadline, !Task.isCancelled {
            if let id = flow.lastSubmittedID, let item = delivery.outbox.item(id) {
                if item.status == .sent {
                    phase = .passed("Heard hello and send it, and \(computerName) received the text.")
                    return
                }
                if let reason = item.lastError, !delivery.inFlight.contains(id) {
                    phase = .failed("Heard hello and send it, but \(computerName) did not take the text: \(reason)")
                    return
                }
            }
            try? await Task.sleep(for: .seconds(timing.poll))
        }
        phase = .failed("Heard hello and send it, but \(computerName) did not answer in time. Check the computer in Help > Health.")
    }
}
