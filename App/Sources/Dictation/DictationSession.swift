import Foundation
import Observation

/// Thread-safe holder for the utterance buffer: the audio thread appends, the main actor presses and releases.
final class UtteranceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: UtteranceBuffer
    private var onUtterance: (@Sendable (UtteranceBuffer.Utterance, Bool) -> Void)?

    init(config: UtteranceBuffer.Config = .init()) { buffer = UtteranceBuffer(config: config) }

    func setHandler(_ handler: @escaping @Sendable (UtteranceBuffer.Utterance, Bool) -> Void) {
        lock.lock()
        onUtterance = handler
        lock.unlock()
    }

    /// Audio thread. Hands a finished utterance to the handler, outside the lock.
    func append(_ chunk: [Float]) {
        lock.lock()
        buffer.append(chunk)
        let finished = buffer.takeFinished()
        let silent = finished.map(buffer.isSilent) ?? false
        let handler = onUtterance
        lock.unlock()
        if let finished { handler?(finished, silent) }
    }

    func begin() {
        lock.lock()
        buffer.beginHold()
        lock.unlock()
    }

    /// Marks the release; the tail arrives through `append`. Returns false when nothing was being held.
    @discardableResult
    func end() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard buffer.isHolding else { return false }
        buffer.endHold()
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
        case notLoaded, loading(Double), ready, failed(String)
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

    init(capture: AudioCapture = AudioCapture(), transcriber: SpeechTranscriber) {
        self.capture = capture
        self.transcriber = transcriber
        gate.setHandler { [weak self] utterance, silent in
            Task { @MainActor in await self?.finish(utterance, silent: silent) }
        }
    }

    var isModelReady: Bool { model == .ready }
    var micReady: Bool { listen.isCapturing }
    var canHold: Bool { isModelReady && micReady && !isHolding }

    // MARK: Model

    func prepareModel() async {
        switch model {
        case .notLoaded, .failed: break
        case .loading, .ready: return
        }
        model = .loading(0)
        do {
            try await transcriber.prepare { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .loading = self.model else { return }
                    self.model = .loading(fraction)
                }
            }
            model = .ready
        } catch {
            model = .failed(String(describing: error))
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
        subscription = capture.bus.subscribe { [gate] chunk in gate.append(chunk) }
        do {
            try capture.start(onEvent: { [weak self] event in Task { @MainActor in self?.audioEvent(event) } })
            apply(listen.handle(.started))
        } catch {
            subscription = nil
            apply(listen.handle(.interruptionBegan(reason: String(describing: error))))
        }
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

    // MARK: Hold to talk

    func beginHold() {
        guard canHold else { return }
        notice = .none
        isHolding = true
        releaseGuard?.cancel()
        gate.begin()
    }

    func endHold() {
        guard isHolding else { return }
        isHolding = false
        guard gate.end() else { return }
        // The tail normally arrives with the next audio chunk; if the microphone died there is none, so cut at what we have.
        releaseGuard = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, let (utterance, silent) = self.gate.flush() else { return }
            await self.finish(utterance, silent: silent)
        }
    }

    private func abortHold() {
        isHolding = false
        releaseGuard?.cancel()
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
