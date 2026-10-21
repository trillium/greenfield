import Foundation
import KitOnboarding

/// The first dictation, guided: "say hello, then say send it". The run itself (the state machine and its pass or fail) is the shared
/// `GuidedRun` (KitOnboarding); this is the app's real pipeline behind it (microphone, speech model, the spoken line-ender, delivery), so
/// the run proves the whole path.
@MainActor
final class GuidedDictationSteps: GuidedRunSteps {
    private let flow: FlowController
    private let service: DeliveryService

    init(flow: FlowController, delivery: DeliveryService) {
        self.flow = flow
        service = delivery
    }

    var destinationName: String { service.targets.selected?.name ?? "the computer" }
    var canStart: Bool { flow.session.canHold }
    var isCapturing: Bool { flow.session.isHolding }

    var latestHeard: GuidedHeard? {
        flow.lastHeard.map { GuidedHeard(id: "\($0.time.timeIntervalSince1970)", raw: $0.raw, endedWithFinishPhrase: $0.lineEnder != nil) }
    }

    func startCapture() { flow.toggleDictation() }

    func stopCapture() { if flow.session.isHolding { flow.toggleDictation() } }

    var delivery: GuidedDelivery {
        guard let id = flow.lastSubmittedID, let item = service.outbox.item(id) else { return .waiting }
        if item.status == .sent { return .delivered }
        if let reason = item.lastError, !service.inFlight.contains(id) { return .refused(reason) }
        return .waiting
    }

    /// The words of this app's run.
    static let strings: GuidedRunStrings = {
        var strings = GuidedRunStrings()
        strings.firstWord = "hello"
        strings.nothingHeard = "Nothing was heard. Check that the microphone is allowed, speak closer to the phone, and try again."
        strings.wrongFirstWord = "I heard \"%@\". Say hello first, then send it."
        strings.noFinishPhrase = "I heard \"%@\", but it did not end with \"send it\". Say send it as the last words."
        strings.passed = "Heard hello and send it, and %@ received the text."
        strings.refused = "Heard hello and send it, but %@ did not take the text: %@"
        strings.timedOut = "Heard hello and send it, but %@ did not answer in time. Check the computer in Help > Health."
        return strings
    }()
}
