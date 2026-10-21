import AVFoundation
import Foundation
import KitHealth
import Observation
import ParrotKit

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
    let peers: PeerDirectory
    let retry: AutoRetry
    let trainers: TrainerDirectory
    let teach: TeachModel
    let support: SupportLog
    let trainerConfiguration: TrainerConfiguration

    init(session: DictationSession, outbox: Outbox, targets: TargetStore, client: ReceiverClient = ReceiverClient(),
         models: ParrotModelStore = .app(), ruleStore: RuleStore = RuleStore(defaults: .standard),
         log: EventLog = EventLog(url: nil), phraseStore: PhraseStore = PhraseStore(defaults: .standard),
         presetTrainers: String? = nil, trainerConfiguration: TrainerConfiguration = AppTeach.configuration(),
         teachLibrary: TeachLibrary = TeachLibrary(directory: AppModel.teachDirectory), teachDefaults: UserDefaults = .standard,
         supportLogURL: URL? = nil, levelsStore: NoiseLevelsStoring = InMemoryNoiseLevelsStore()) {
        self.log = log
        support = SupportLog(log: log, outbox: outbox, url: supportLogURL)
        self.session = session
        self.outbox = outbox
        self.targets = targets
        delivery = DeliveryService(outbox: outbox, targets: targets, client: client)
        health = TargetHealth(service: delivery)
        delivery.log = log
        let peerDirectory = PeerDirectory(service: delivery)
        peers = peerDirectory
        retry = AutoRetry(service: delivery, log: log)
        let flowController = FlowController(session: session, delivery: delivery, models: models, ruleStore: ruleStore, log: log,
                                            phraseStore: phraseStore, levelsStore: levelsStore)
        flow = flowController
        self.trainerConfiguration = trainerConfiguration
        let port = trainerConfiguration.port
        trainers = TrainerDirectory(
            configuration: trainerConfiguration,
            providers: [
                ClosureTrainerCandidates { TrainerEndpoint.parsePresets(presetTrainers, port: port) },
                ClosureTrainerCandidates {
                    targets.targets.compactMap {
                        TrainerEndpoint.onTrainerPort(name: $0.name, address: $0.address, source: .computer, port: port)
                    }
                },
                ClosureTrainerCandidates {
                    peerDirectory.discovered.compactMap {
                        TrainerEndpoint.onTrainerPort(name: $0.name, address: $0.address, source: .peer, port: port)
                    }
                }
            ],
            defaults: teachDefaults, makeClient: AppTeach.makeClient)
        let bus = session.capture.bus
        teach = TeachModel(library: teachLibrary, store: models,
                           microphone: SessionMicrophone(bus: bus, makeReady: { [weak session] in await Self.prepareMicrophone(session) }),
                           addressProvider: trainers, configuration: trainerConfiguration, policy: .activateKeepingPrevious,
                           defaults: teachDefaults, makeClient: AppTeach.makeClient)
        teach.onRecordingChanged = { [flowController] recording in flowController.setRulesPaused(recording) }
        log.add(.app, "app started, \(BuildInfo().display)")
        support.health = { [weak self] in self?.healthReport() ?? HealthReport(items: []) }
        support.writeNow()
    }

    /// `Application Support/Sounds/Teach`: the user's recordings, in the app's sandbox.
    static var teachDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Sounds/Teach", isDirectory: true)
    }

    /// Makes sure the one microphone tap is running for a take; returns a sentence when it cannot be.
    private static func prepareMicrophone(_ session: DictationSession?) async -> String? {
        guard let session else { return "The app is closing." }
        if session.isHolding { return "Finish dictating first, then record." }
        await session.startListening()
        if session.micDenied { return "Microphone access is off. Turn it on in iPhone Settings > Greenfield." }
        return session.capture.isRunning ? nil : "The microphone is not available right now. Try again in a moment."
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
                        log: EventLog(url: EventLog.standardURL),
                        presetTrainers: Bundle.main.object(forInfoDictionaryKey: "GreenfieldPresetTrainers") as? String,
                        supportLogURL: SupportLog.standardURL, levelsStore: AppLevels.standardStore())
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
        input.trainerItems = TrainerHealthReport
            .lines(for: trainers, tailnet: InterfaceTailnetStatus(), configuration: trainerConfiguration).map(\.healthItem)
        input.queued = outbox.pending.count
        input.logsAvailable = support.isAvailable || support.url == nil
        input.loggedEvents = log.entries.count
        input.appVersion = AppVersion.current
        input.minimumAgent = AppVersion.minimumAgent
        return input
    }

    func healthReport() -> HealthReport { AppHealth.report(healthInputs()) }

    func resend(_ id: UUID) {
        Task { await delivery.deliver(id) }
    }
}
