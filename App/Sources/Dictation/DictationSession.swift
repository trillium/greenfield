import Foundation
import Observation

/// Thread-safe holder for the utterance buffer: the audio thread appends, the main actor presses and releases.
final class UtteranceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: UtteranceBuffer
    private var onUtterance: (@Sendable (UtteranceBuffer.Utterance, Bool) -> Void)?
    private var lastAudio: Date?

    /// When the microphone last delivered audio, for the Health screen.
    var lastAudioAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastAudio
    }

    init(config: UtteranceBuffer.Config = .init()) { buffer = UtteranceBuffer(config: config) }

    func setHandler(_ handler: @escaping @Sendable (UtteranceBuffer.Utterance, Bool) -> Void) {
        lock.lock()
        onUtterance = handler
        lock.unlock()
    }

    /// Audio thread. Hands a finished utterance to the handler, outside the lock.
    func append(_ chunk: [Float]) {
        lock.lock()
        lastAudio = Date()
        buffer.append(chunk)
        let finished = buffer.takeFinished()
        let silent = finished.map(buffer.isSilent) ?? false
        let handler = onUtterance
        lock.unlock()
        if let finished { handler?(finished, silent) }
    }

    func begin(preRollSeconds: Double? = nil) {
        lock.lock()
        buffer.beginHold(preRollSeconds: preRollSeconds)
        lock.unlock()
    }

    /// Marks the release; the tail arrives through `append` (or is already here when `tailSeconds` is negative).
    /// Returns false when nothing was being held.
    @discardableResult
    func end(tailSeconds: Double? = nil) -> Bool {
        lock.lock()
        guard buffer.isHolding else {
            lock.unlock()
            return false
        }
        buffer.endHold(tailSeconds: tailSeconds)
        let finished = buffer.takeFinished()
        let silent = finished.map(buffer.isSilent) ?? false
        let handler = onUtterance
        lock.unlock()
        if let finished { handler?(finished, silent) }
        return true
    }

    /// Finishes an utterance whose tail never arrived (the microphone stopped), or returns nil.
    func flush() -> (UtteranceBuffer.Utterance, Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard let utterance = buffer.takeFinished(flush: true) else { return nil }
        return (utterance, buffer.isSilent(utterance))
    }

    func reset() {
        lock.lock()
        buffer.reset()
        lock.unlock()
    }
}

/// Hold to talk: the microphone runs while the screen is open, a press marks the start of an utterance, a release sends it to the
/// speech model, and the text goes to `onTranscript`. One audio tap serves everything; this class only subscribes to its bus.
@MainActor
@Observable
final class DictationSession {
    enum ModelState: Equatable {
        case notLoaded
        /// Fetching the model for the first time (0...1).
        case downloading(Double)
        /// On this phone already; loading and preparing it.
        case loading
        case ready
        case failed(String)
    }

    enum Notice: Equatable {
        case none, nothingHeard, failed(String)
    }

    private(set) var model: ModelState = .notLoaded
    private(set) var isHolding = false
    private(set) var transcribing = 0
    private(set) var notice: Notice = .none
    private(set) var listen = ListenMachine()
    private(set) var micDenied = false
    private(set) var lastTranscript: String?
    private(set) var log: [String] = []

    let capture: AudioCapture
    private let transcriber: SpeechTranscriber
    private let gate = UtteranceGate()
    private var subscription: SampleBus.Subscription?
    private var resumeTask: Task<Void, Never>?
    private var releaseGuard: Task<Void, Never>?
    /// Called with each non-empty transcript and the speech model's time in milliseconds.
    var onTranscript: (@MainActor (String, Int) -> Void)?
    /// Diagnostics: microphone and model events as they happen.
    var onLog: (@MainActor (EventLog.Category, String) -> Void)?
    /// Called when recording starts (true) or stops (false), whatever started it: the button, a sound, or a lost microphone.
    var onDictating: (@MainActor (Bool) -> Void)?

    /// `listen` is injectable so a test can start from a microphone that is already running.
    init(capture: AudioCapture = AudioCapture(), transcriber: SpeechTranscriber, listen: ListenMachine = ListenMachine()) {
        self.capture = capture
        self.listen = listen
        self.transcriber = transcriber
        gate.setHandler { [weak self] utterance, silent in
            Task { @MainActor in await self?.finish(utterance, silent: silent) }
        }
    }

    /// The microphone delivered audio in the last two seconds.
    var audioFlowing: Bool { gate.lastAudioAt.map { Date().timeIntervalSince($0) < 2 } ?? false }
    var modelOnDisk: Bool { transcriber.isDownloaded() }
    var isModelReady: Bool { model == .ready }
    var micReady: Bool { listen.isCapturing }
    var canHold: Bool { isModelReady && micReady && !isHolding }

    // MARK: Model

    func prepareModel() async {
        switch model {
        case .notLoaded, .failed: break
        case .downloading, .loading, .ready: return
        }
        model = transcriber.isDownloaded() ? .loading : .downloading(0)
        onLog?(.model, transcriber.isDownloaded() ? "speech model already on this phone, loading" : "speech model downloading")
        do {
            try await transcriber.prepare { [weak self] update in
                Task { @MainActor in
                    guard let self else { return }
                    switch (update, self.model) {
                    case (.downloading(let fraction), .downloading), (.downloading(let fraction), .loading):
                        self.model = .downloading(fraction)
                    case (.preparing, .downloading), (.preparing, .loading): self.model = .loading
                    default: break
                    }
                }
            }
            model = .ready
            onLog?(.model, "speech model ready")
        } catch {
            model = .failed(String(describing: error))
            onLog?(.model, "speech model failed: \(error)")
        }
    }

    // MARK: Microphone

    /// Asks for permission if needed and starts the one tap. Call while the app is in the foreground.
    func startListening() async {
        guard !listen.isCapturing else { return }
        guard await AudioCapture.requestPermission() else {
            micDenied = true
            return
        }
        micDenied = false
        attach()
        do {
            try capture.start(onEvent: { [weak self] event in Task { @MainActor in self?.audioEvent(event) } })
            apply(listen.handle(.started))
        } catch {
            subscription = nil
            apply(listen.handle(.interruptionBegan(reason: String(describing: error))))
        }
    }

    /// Subscribes the utterance buffer to the microphone's bus (done by `startListening`; a test calls it to feed the bus directly).
    func attach() {
        subscription = capture.bus.subscribe { [gate] chunk in gate.append(chunk) }
    }

    func stopListening() {
        abortHold()
        resumeTask?.cancel()
        capture.stop()
        subscription = nil
        gate.reset()
        apply(listen.handle(.stopped))
    }

    func sceneChanged(foreground: Bool) async {
        if foreground { await startListening() } else { stopListening() }
    }

    func retryMicrophone() async {
        if listen.isCapturing { return }
        if !capture.isRunning { await startListening(); return }
        apply(listen.handle(.retryRequested))
    }

    private func audioEvent(_ event: AudioCapture.Event) {
        switch event {
        case .interruptionBegan(let reason): apply(listen.handle(.interruptionBegan(reason: reason)))
        case .interruptionEnded(let shouldResume): apply(listen.handle(.interruptionEnded(shouldResume: shouldResume)))
        case .configurationChanged: apply(listen.handle(.captureLost(reason: "audio configuration changed")))
        case .routeChanged(let reason): apply(listen.handle(.routeChanged(reason: reason)))
        case .mediaServicesReset: apply(listen.handle(.captureLost(reason: "audio services were reset")))
        }
    }

    private func apply(_ outcome: ListenMachine.Outcome) {
        log.append(contentsOf: outcome.log)
        for line in outcome.log { onLog?(.mic, line) }
        if log.count > 200 { log.removeFirst(log.count - 200) }
        for action in outcome.actions {
            switch action {
            case .cancelResume: resumeTask?.cancel()
            case .flushUtterance:
                abortHold()
                gate.reset()
            case .resume(let delay):
                resumeTask?.cancel()
                resumeTask = Task { [weak self] in
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    guard !Task.isCancelled else { return }
                    self?.attemptResume()
                }
            }
        }
    }

    private func attemptResume() {
        do {
            try capture.resume(rebuildEngine: true)
            apply(listen.handle(.resumeSucceeded))
        } catch {
            apply(listen.handle(.resumeFailed(AudioCapture.describe(error))))
        }
    }

    // MARK: Dictating (the hold button and the sound rules share this)

    func beginHold() { beginDictation(preRollSeconds: nil) }
    func endHold() { endDictation(tailSeconds: nil) }

    /// A sound started dictation: no pre-roll, the sound is not part of the speech.
    func beginSoundDictation() { beginDictation(preRollSeconds: 0) }

    /// A sound ended dictation: the last moments (the sound itself) are cut off.
    func endSoundDictation() { endDictation(tailSeconds: -Self.soundTrimSeconds) }

    static let soundTrimSeconds = 0.3

    private func beginDictation(preRollSeconds: Double?) {
        guard canHold else { return }
        notice = .none
        isHolding = true
        releaseGuard?.cancel()
        gate.begin(preRollSeconds: preRollSeconds)
        onDictating?(true)
    }

    private func endDictation(tailSeconds: Double?) {
        guard isHolding else { return }
        isHolding = false
        onDictating?(false)
        guard gate.end(tailSeconds: tailSeconds) else { return }
        guard tailSeconds == nil else { return }
        // The tail normally arrives with the next audio chunk; if the microphone died there is none, so cut at what we have.
        releaseGuard = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, let (utterance, silent) = self.gate.flush() else { return }
            await self.finish(utterance, silent: silent)
        }
    }

    private func abortHold() {
        let wasHolding = isHolding
        isHolding = false
        releaseGuard?.cancel()
        if wasHolding { onDictating?(false) }
    }

    // MARK: Transcription

    /// The shared path for a finished utterance: the live microphone and the on-device self test both end here.
    func finish(_ utterance: UtteranceBuffer.Utterance, silent: Bool) async {
        releaseGuard?.cancel()
        guard !silent else {
            notice = .nothingHeard
            return
        }
        transcribing += 1
        defer { transcribing -= 1 }
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let text = try await transcriber.transcribe(utterance.pcm)
            let ms = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            guard !text.isEmpty else {
                notice = .nothingHeard
                return
            }
            notice = .none
            lastTranscript = text
            onTranscript?(text, ms)
        } catch {
            notice = .failed(String(describing: error))
        }
    }
}
