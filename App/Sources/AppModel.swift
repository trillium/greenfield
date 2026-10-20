import Foundation
import Observation

/// Wires the pieces together: the dictation session turns speech into text, the flow controller applies the sound rules and fills
/// the text box, delivery sends submitted text to the active Mac through the outbox.
@MainActor
@Observable
final class AppModel {
    let session: DictationSession
    let outbox: Outbox
    let targets: TargetStore
    let delivery: DeliveryService
    let health: TargetHealth
    let flow: FlowController

    init(session: DictationSession, outbox: Outbox, targets: TargetStore, client: ReceiverClient = ReceiverClient(),
         models: ParrotModelStore = ParrotModelStore(), ruleStore: RuleStore = RuleStore(defaults: .standard)) {
        self.session = session
        self.outbox = outbox
        self.targets = targets
        delivery = DeliveryService(outbox: outbox, targets: targets, client: client)
        health = TargetHealth(service: delivery)
        flow = FlowController(session: session, delivery: delivery, models: models, ruleStore: ruleStore)
    }

    static func live() -> AppModel {
        let targets = TargetStore(keys: KeychainKeyStore())
        targets.seedPresets(Bundle.main.object(forInfoDictionaryKey: "GreenfieldPresetComputers") as? String)
        return AppModel(session: DictationSession(transcriber: ParakeetTranscriber()), outbox: Outbox(url: Outbox.standardURL),
                        targets: targets)
    }

    func resend(_ id: UUID) {
        Task { await delivery.deliver(id) }
    }
}
