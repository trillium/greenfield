import Foundation
import Observation

/// Wires the pieces together: the dictation session turns speech into text, the outbox keeps it, delivery sends it to the Mac.
@MainActor
@Observable
final class AppModel {
    let session: DictationSession
    let outbox: Outbox
    let targets: TargetStore
    let delivery: DeliveryService
    let health: TargetHealth

    init(session: DictationSession, outbox: Outbox, targets: TargetStore, client: ReceiverClient = ReceiverClient()) {
        self.session = session
        self.outbox = outbox
        self.targets = targets
        delivery = DeliveryService(outbox: outbox, targets: targets, client: client)
        health = TargetHealth(service: delivery)
        session.onTranscript = { [weak self] text, asrMs in self?.received(text, asrMs: asrMs) }
    }

    static func live() -> AppModel {
        AppModel(session: DictationSession(transcriber: ParakeetTranscriber()), outbox: Outbox(url: Outbox.standardURL),
                 targets: TargetStore(keys: KeychainKeyStore()))
    }

    /// A new transcript goes into the outbox first, then to the selected Mac. If the send fails the text stays there.
    func received(_ text: String, asrMs: Int) {
        let item = outbox.add(text: text, asrMs: asrMs)
        Task { await delivery.deliver(item.id) }
    }

    func resend(_ id: UUID) {
        Task { await delivery.deliver(id) }
    }
}
