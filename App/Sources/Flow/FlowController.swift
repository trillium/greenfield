import Foundation
import KitHealth
import Observation
import ParrotKit

/// Runs the dictation flow: sounds go through the rules, the rules start and end dictation and submit the text.
/// The hold button is the fallback and drives the same state.
@MainActor
@Observable
final class FlowController {
    struct HeardSound: Identifiable, Equatable {
        let id = UUID()
        let event: SoundEvent
        let heardAt: Date
        /// The rule this sound fired, if any.
        let firedRule: String?
    }

    static let keepSounds = 100

    private(set) var engine: RuleEngine
    /// The text box on the Dictate screen: dictated text lands here and Submit sends it.
    var text = ""
    private(set) var lastSound: HeardSound?
    private(set) var recentSounds: [HeardSound] = []
    private(set) var modelName = ""
    private(set) var detectorLabels: [String] = []
    private(set) var detectorProblem: String?
    private(set) var submitPending = false
    /// True while the user records their sounds for training: sounds are still heard and listed, but no rule fires, so a click taught as
    /// a sample does not start, end or submit anything.
    private(set) var rulesPaused = false
    /// The last thing Parakeet heard and whether it ended with a line-ender, for the guided first dictation.
    struct Heard: Equatable {
        let raw: String
        let lineEnder: String?
        let time: Date
    }
    private(set) var lastHeard: Heard?
    /// The outbox item the last submit created.
    private(set) var lastSubmittedID: UUID?

    let session: DictationSession
    let delivery: DeliveryService
    let models: ParrotModelStore
    let log: EventLog
    private let ruleStore: RuleStore
    private let phraseStore: PhraseStore
    /// The trigger levels and input gain the detector is built with, and the Levels screen's side of it.
    let levels: AppLevels
    /// The spoken line-enders, editable in Sounds.
    private(set) var phrases: [PhraseStore.Phrase]
    private var listener: SoundListener?
    private var observer: NSObjectProtocol?

    init(session: DictationSession, delivery: DeliveryService, models: ParrotModelStore, ruleStore: RuleStore,
         log: EventLog = EventLog(url: nil), phraseStore: PhraseStore = PhraseStore(defaults: .standard),
         levelsStore: NoiseLevelsStoring = InMemoryNoiseLevelsStore()) {
        self.phraseStore = phraseStore
        levels = AppLevels(models: models, store: levelsStore)
        phrases = phraseStore.load()
        self.log = log
        self.session = session
        self.delivery = delivery
        self.models = models
        self.ruleStore = ruleStore
        engine = RuleEngine(rules: ruleStore.load())
        session.onDictating = { [weak self] on in self?.dictationChanged(on) }
        session.onTranscript = { [weak self] text, asrMs in self?.transcribed(text, asrMs: asrMs) }
        session.onLog = { [weak self] category, line in self?.log.add(category, line) }
        session.lineEnderActive = { [weak self] in !(self?.enabledPhrases.isEmpty ?? true) }
        session.lineEnderProbe = { [weak self] text in
            guard let self else { return false }
            return LineEnder.match(text, phrases: self.enabledPhrases) != nil
        }
        levels.rebuild = { [weak self] in self?.startDetector() }
        levels.listening = { [weak self] in (self?.isListening ?? false) && (self?.session.micReady ?? false) }
        observer = NotificationCenter.default.addObserver(forName: ParrotModelStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startDetector() }
        }
    }

    /// The detector is subscribed to the microphone's tap.
    var isListening: Bool { listener != nil }
    var state: FlowState { engine.state }
    var rules: [SoundRule] { engine.rules }
    var availableSounds: [String] { models.activePatterns() }
    var enabledPhrases: [String] { phrases.filter { $0.enabled && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.map(\.text) }

    func setPhrases(_ updated: [PhraseStore.Phrase]) {
        phrases = updated
        phraseStore.save(updated)
    }

    func resetPhrases() { setPhrases(PhraseStore.defaults) }

    var canSubmit: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// What the next sound will do, for the screen: the first enabled rule that applies in the current state.
    var hint: String {
        let applicable = engine.rules.filter { $0.enabled && $0.from == state }
        guard !applicable.isEmpty else { return "No rule applies in this state." }
        return applicable.map { "\($0.trigger.summary) → \($0.action.title)" }.joined(separator: "; ")
    }

    // MARK: Detector

    /// Builds the detector from the active model and subscribes it to the microphone's one tap. Safe to call again after a model change.
    func startDetector() {
        listener?.cancel()
        listener = nil
        do {
            let source = try models.source()
            let setup = levels.setup(for: source)
            let detector = try SoundDetector(model: source.model, patternsJSON: setup.patternsJSON)
            modelName = source.name
            detectorLabels = detector.labels
            detectorProblem = nil
            log.add(.model, "sound detector listening with \(source.name) (\(detector.labels.count) classes)")
            let levels = levels
            listener = SoundListener(
                detector: detector, bus: session.capture.bus, gain: setup.gain,
                onReading: { reading in MainActor.assumeIsolated { levels.receive(reading) } },
                onEvents: { events in MainActor.assumeIsolated { [weak self] in self?.heard(events) } })
        } catch {
            detectorProblem = String(describing: error)
            log.add(.model, "sound detector could not start: \(error)")
        }
    }

    func setRulesPaused(_ paused: Bool) {
        guard rulesPaused != paused else { return }
        rulesPaused = paused
        log.add(.rule, paused ? "rules paused while sounds are recorded" : "rules active again")
    }

    func heard(_ events: [SoundEvent]) {
        for event in events {
            let before = engine.state
            let fired = rulesPaused ? nil : engine.hear(event.pattern, at: event.time)
            // The model's "not a command" patterns can fire dozens of times a second; they stay out of the log.
            if !event.pattern.hasPrefix("suppress") {
                let percent = Int((event.probability * 100).rounded())
                log.add(.sound, "\(event.pattern) \(percent)% (\(event.topClass), power \(Int(event.power)))")
            }
            if let fired {
                log.add(.rule, "fired \(fired.summary) -> \(fired.action.title) (was \(before.title), now \(engine.state.title))")
            }
            let sound = HeardSound(event: event, heardAt: Date(), firedRule: fired?.summary)
            lastSound = sound
            recentSounds.insert(sound, at: 0)
            if recentSounds.count > Self.keepSounds { recentSounds.removeLast(recentSounds.count - Self.keepSounds) }
            if let fired { perform(fired.action) }
        }
    }

    // MARK: Rules

    func setRules(_ rules: [SoundRule]) {
        engine.rules = rules
        ruleStore.save(rules)
    }

    func resetRules() { setRules(SoundRule.defaults) }

    // MARK: Actions

    /// The microphone button: tap to start, tap to stop. It follows the same state as the sounds: tapping while dictating ends
    /// dictation like a tongue click; tapping while idle or in review starts it (more text goes on the end of the box).
    func toggleDictation() {
        if session.isHolding {
            log.add(.dictation, "button: stop dictation")
            session.endHold()
        } else {
            log.add(.dictation, "button: start dictation")
            session.beginHold()
        }
    }

    func perform(_ action: FlowAction) {
        switch action {
        case .startDictation: session.beginSoundDictation()
        case .endDictation: session.endSoundDictation()
        case .submit: submit()
        case .clearText: text = ""
        case .none: break
        }
        // A rule can move to dictating when the microphone is not ready; keep the state honest.
        if action == .startDictation, !session.isHolding { engine.setState(.idle) }
    }

    /// Sends the text box to the active Mac (queued in the outbox when it cannot be reached) and clears it.
    /// If speech is still being transcribed, the submit waits for it, so the last words are not left behind.
    func submit() {
        guard session.transcribing > 0 || session.isHolding else { return send() }
        submitPending = true
        Task {
            while session.transcribing > 0 || session.isHolding { try? await Task.sleep(for: .milliseconds(100)) }
            if submitPending { send() }
        }
    }

    private func send() {
        submitPending = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.setState(.idle)
        guard !trimmed.isEmpty else { return }
        let item = delivery.outbox.add(text: trimmed)
        lastSubmittedID = item.id
        log.add(.send, "submitted \(trimmed.count) characters to \(delivery.targets.selected?.name ?? "no computer")")
        text = ""
        Task { await delivery.deliver(item.id) }
    }

    // MARK: Session callbacks

    private func dictationChanged(_ on: Bool) {
        log.add(.dictation, on ? "recording started" : "recording stopped")
        if on {
            engine.setState(.dictating)
        } else if engine.state == .dictating {
            engine.setState(.review)
        }
    }

    private func transcribed(_ words: String, asrMs: Int) {
        log.add(.dictation, "transcribed \(words.count) characters in \(asrMs) ms")
        let ender = LineEnder.match(words, phrases: enabledPhrases)
        lastHeard = Heard(raw: words, lineEnder: ender?.phrase, time: Date())
        guard let ender else {
            text = text.isEmpty ? words : text + " " + words
            return
        }
        // The phrase ends the line: it is not part of the text, and the box goes to the active computer like a second tongue click.
        log.add(.dictation, "spoken line-ender at the end of the transcript: submitting")
        if !ender.remaining.isEmpty { text = text.isEmpty ? ender.remaining : text + " " + ender.remaining }
        if session.isHolding { session.endHold() }
        submit()
    }
}
