import AVFoundation
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
    let log: EventLog

    init(session: DictationSession, outbox: Outbox, targets: TargetStore, client: ReceiverClient = ReceiverClient(),
         models: ParrotModelStore = ParrotModelStore(), ruleStore: RuleStore = RuleStore(defaults: .standard),
         log: EventLog = EventLog(url: nil)) {
        self.log = log
        self.session = session
        self.outbox = outbox
        self.targets = targets
        delivery = DeliveryService(outbox: outbox, targets: targets, client: client)
        health = TargetHealth(service: delivery)
        delivery.log = log
        flow = FlowController(session: session, delivery: delivery, models: models, ruleStore: ruleStore, log: log)
        log.add(.app, "app started, \(BuildInfo().display)")
    }

    static func live() -> AppModel {
        let targets = TargetStore(keys: KeychainKeyStore())
        targets.seedPresets(Bundle.main.object(forInfoDictionaryKey: "GreenfieldPresetComputers") as? String)
        // `-selftest-fakemic YES`: treat the microphone as running and feed the bus from files (the acceptance scenarios on a phone
        // nobody is speaking to). The detector, rules, buffer, speech model and delivery are all the real ones.
        var machine = ListenMachine()
        let fake = UserDefaults.standard.bool(forKey: "selftest-fakemic")
        if fake { _ = machine.handle(.started) }
        let session = DictationSession(transcriber: ParakeetTranscriber(), listen: machine)
        if fake { session.attach() }
        return AppModel(session: session, outbox: Outbox(url: Outbox.standardURL), targets: targets,
                        log: EventLog(url: EventLog.standardURL))
    }

    /// The facts the Health screen reports on, gathered now.
    func healthInputs() -> HealthInputs {
        var input = HealthInputs()
        input.speechModel = session.model
        input.speechModelOnDisk = session.modelOnDisk
        switch AVAudioApplication.shared.recordPermission {
        case .granted: input.microphonePermission = .granted
        case .denied: input.microphonePermission = .denied
        default: input.microphonePermission = .undetermined
        }
        input.microphoneStatus = session.listen.status
        input.audioFlowing = session.audioFlowing
        input.detectorModel = flow.modelName
        input.detectorProblem = flow.detectorProblem
        input.detectorListening = flow.isListening
        input.tailnetConnected = Tailnet.isConnected()
        input.computers = targets.targets.map { target in
            HealthInputs.Computer(name: target.name, address: target.address, isActive: target.id == targets.selectedID,
                                  hasKey: !(targets.key(for: target) ?? "").isEmpty, answer: health.answers[target.id])
        }
        input.queued = outbox.pending.count
        return input
    }

    func healthReport() -> [HealthItem] { HealthReport.build(healthInputs()) }

    func resend(_ id: UUID) {
        Task { await delivery.deliver(id) }
    }
}
