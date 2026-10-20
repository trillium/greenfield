import Foundation

/// Sends outbox items to the selected Mac, one Mac per transcript, never to another one when it fails.
@MainActor
@Observable
final class DeliveryService {
    let outbox: Outbox
    let targets: TargetStore
    private let client: ReceiverClient
    /// Ids being sent right now, so a double tap on Resend cannot send twice at once.
    private(set) var inFlight: Set<UUID> = []

    init(outbox: Outbox, targets: TargetStore, client: ReceiverClient = ReceiverClient()) {
        self.outbox = outbox
        self.targets = targets
        self.client = client
    }

    /// Delivers the item to the selected Mac. Updates the outbox with the result and returns it.
    @discardableResult
    func deliver(_ id: UUID) async -> ReceiverClient.SendOutcome? {
        guard let item = outbox.item(id), item.status == .pending, !inFlight.contains(id) else { return nil }
        guard let target = targets.selected, let base = target.baseURL else {
            outbox.markFailed(id, reason: "No Mac is selected. Choose one in the Macs tab, then resend.")
            return nil
        }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        outbox.markAttempt(id, targetName: target.name)
        let (outcome, networkMs) = await client.send(id: id, text: item.text, to: base, key: targets.key(for: target))
        switch outcome {
        case .delivered(_, let macMs): outbox.markSent(id, networkMs: networkMs, macMs: macMs)
        case .refused(let refusal): outbox.markFailed(id, reason: refusal.message)
        case .unreachable(let reason): outbox.markFailed(id, reason: reason)
        }
        return outcome
    }

    /// Sends every undelivered item, oldest first, to the selected Mac. Stops at the first failure so order is kept.
    func resendAll() async {
        for item in outbox.pending.reversed() {
            guard let outcome = await deliver(item.id), case .delivered = outcome else { return }
        }
    }

    /// `GET /status` for the Mac, with its saved key unless `key` is given (testing an edit before it is saved).
    func health(of target: MacTarget, key: String? = nil) async -> ReceiverClient.Health {
        guard let base = target.baseURL else { return .unreachable("The address is not valid.") }
        return await client.health(of: base, key: key ?? targets.key(for: target))
    }
}
