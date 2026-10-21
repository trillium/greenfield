@preconcurrency import AVFoundation

/// Live microphone as 16 kHz mono float PCM, the format the endpointer and the speech model expect.
/// AVAudioEngine taps the input node in the hardware format; every buffer is converted (rate and channels) before it is handed on.
/// There is exactly ONE tap. Consumers (the dictation recorder now, a sound-trigger detector later) subscribe to `bus` instead of
/// installing taps of their own: a second `installTap` on the same bus throws.
final class AudioCapture: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case permissionDenied
        case noInput
        case converter
        case session(String)

        var description: String {
            switch self {
            case .permissionDenied: return "Microphone access is off. Turn it on in Settings > Dictation."
            case .noInput: return "No microphone input is available."
            case .converter: return "Cannot convert the microphone format to 16 kHz mono."
            case .session(let message): return "Audio session: \(message)"
            }
        }
    }

    static let sampleRate = 16_000.0
    static let tapFrames: AVAudioFrameCount = 4096

    /// The session this app holds while listening. Mixable, so another app's playback (music, a podcast, a video) neither interrupts the
    /// mic nor is silenced by it; an exclusive `.record` session was interrupted by any of them and, once backgrounded, iOS then refused
    /// to reactivate it . Phone calls, Siri and alarms still interrupt. `.defaultToSpeaker` keeps the other app's
    /// sound on the speaker instead of the earpiece, which `.playAndRecord` would otherwise pick; this app plays nothing itself.
    static let sessionCategory = AVAudioSession.Category.playAndRecord
    static let sessionMode = AVAudioSession.Mode.measurement
    static let sessionOptions: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker]

    /// What the audio system tells us about the mic. The audio owner turns these into `ListenMachine` events.
    enum Event: Equatable, Sendable {
        case interruptionBegan(reason: String)
        case interruptionEnded(shouldResume: Bool)
        /// The engine stopped itself: the route or the hardware format changed under it.
        case configurationChanged
        case routeChanged(reason: String)
        case mediaServicesReset
    }

    private let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    private var engine = AVAudioEngine()
    private var observers: [NSObjectProtocol] = []
    private var onSamples: (@Sendable ([Float]) -> Void)?
    private(set) var isRunning = false
    /// Every converted chunk is published here, on the audio thread. Subscribe before or after `start`.
    let bus = SampleBus()

    /// What the heartbeat adds to its Log line: whether the engine is really running and which category the session holds, so a
    /// background run shows that the audio session stayed up (a deactivated session would stop the engine).
    var diagnostics: String {
        let session = AVAudioSession.sharedInstance()
        let mixing = session.categoryOptions.contains(.mixWithOthers) ? "mixable" : "exclusive"
        return "engine \(engine.isRunning ? "running" : "stopped"), session \(session.category.rawValue), \(mixing)"
    }

    /// Asks once; later calls return the stored answer. The system prompt needs a person to tap Allow the first time.
    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    static var permissionDenied: Bool { AVAudioApplication.shared.recordPermission == .denied }

    /// Starts capture and publishes every chunk on `bus`. See `start(onSamples:onEvent:)` for the threading rules.
    func start(onEvent: @escaping @Sendable (Event) -> Void) throws {
        let bus = bus
        try start(onSamples: { bus.publish($0) }, onEvent: onEvent)
    }

    /// Must be called while the app is in the foreground: the record session is started here, and with `UIBackgroundModes` = `audio`
    /// it then keeps running, and can be reactivated after an interruption, once the app is in the background.
    /// `onSamples` runs on the audio thread: keep it short. `onEvent` runs on whatever thread the notification came on.
    func start(onSamples: @escaping @Sendable ([Float]) -> Void, onEvent: @escaping @Sendable (Event) -> Void) throws {
        guard !isRunning else { return }
        self.onSamples = onSamples
        do { try bringUp() } catch {
            self.onSamples = nil
            throw error
        }
        observe(onEvent)
        isRunning = true
    }

    /// Brings the mic back after an interruption, a route or format change or a media-services reset: reactivates the session and
    /// restarts the engine with a fresh tap, so a new hardware format (headphones, Bluetooth) is picked up. Safe when nothing stopped.
    func resume(rebuildEngine: Bool = false) throws {
        guard isRunning else { return }
        if rebuildEngine { engine = AVAudioEngine() }
        try bringUp()
    }

    func stop() {
        guard isRunning else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onSamples = nil
        isRunning = false
    }

    /// Category, session, converter, tap, engine: the same steps for the first start and every resume.
    private func bringUp() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(Self.sessionCategory, mode: Self.sessionMode, options: Self.sessionOptions)
            try session.setPreferredSampleRate(Self.sampleRate)
            try session.setActive(true)
        } catch {
            throw Failure.session(Self.describe(error))
        }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw Failure.noInput }
        guard let target = output, let converter = AVAudioConverter(from: hardware, to: target) else { throw Failure.converter }
        guard let onSamples else { throw Failure.session("capture was stopped") }
        input.installTap(onBus: 0, bufferSize: Self.tapFrames, format: hardware) { buffer, _ in
            let samples = Self.convert(buffer, with: converter, to: target)
            if !samples.isEmpty { onSamples(samples) }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure.session(Self.describe(error))
        }
    }

    private func observe(_ onEvent: @escaping @Sendable (Event) -> Void) {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { note in
                let info = note.userInfo
                let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                if type == .began {
                    onEvent(.interruptionBegan(reason: Self.interruptionReason(info?[AVAudioSessionInterruptionReasonKey] as? UInt)))
                } else if type == .ended {
                    let raw = info?[AVAudioSessionInterruptionOptionKey] as? UInt
                    let options = raw.map(AVAudioSession.InterruptionOptions.init)
                    onEvent(.interruptionEnded(shouldResume: options?.contains(.shouldResume) ?? false))
                }
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { _ in
                onEvent(.configurationChanged)
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { note in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                onEvent(.routeChanged(reason: Self.routeReason(raw)))
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { _ in
                onEvent(.mediaServicesReset)
            }
        ]
    }

    /// The system's message plus its error code, and the code as the four letters Apple documents it by (`!pri` insufficient priority,
    /// `!rec` cannot start recording, `!int` cannot interrupt others, `!act` busy), so a failed resume in the Log says why.
    static func describe(_ error: Error) -> String {
        let detail = error as NSError
        return "\(error.localizedDescription) [\(detail.domain) \(detail.code)\(fourCharacterCode(detail.code))]"
    }

    static func fourCharacterCode(_ code: Int) -> String {
        guard code > 0x2020_2020, code <= Int(UInt32.max) else { return "" }
        let bytes = (0..<4).map { UInt8((code >> (8 * (3 - $0))) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "" }
        guard let letters = String(bytes: bytes, encoding: .ascii) else { return "" }
        return " '\(letters)'"
    }

    /// Test only (`-live-fake-interruptions`): posts what iOS posts when a call starts or ends. The engine is not touched.
    static func postSyntheticInterruption(_ type: AVAudioSession.InterruptionType) {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if type == .ended { info[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue }
        let session = AVAudioSession.sharedInstance()
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: session, userInfo: info)
    }

    /// `AVAudioSession.InterruptionReason` by raw value: `appWasSuspended` is deprecated and `routeDisconnected` needs iOS 17.
    static func interruptionReason(_ raw: UInt?) -> String {
        switch raw {
        case nil, 0: return "another app, a call or Siri took the audio"
        case 1: return "the app was suspended"
        case 2: return "the built-in microphone was muted"
        case 4: return "the audio route was disconnected"
        default: return "audio interruption (reason \(raw ?? 0))"
        }
    }

    static func routeReason(_ raw: UInt?) -> String {
        guard let raw, let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return "unknown" }
        switch reason {
        case .newDeviceAvailable: return "new input or output connected"
        case .oldDeviceUnavailable: return "input or output disconnected"
        case .categoryChange: return "audio category changed"
        case .override: return "route overridden"
        case .wakeFromSleep: return "woke from sleep"
        case .noSuitableRouteForCategory: return "no suitable route for the category"
        case .routeConfigurationChange: return "route configuration changed"
        default: return "reason \(raw)"
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to target: AVAudioFormat) -> [Float] {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        nonisolated(unsafe) var supplied = false
        var failure: NSError?
        let status = converter.convert(to: converted, error: &failure) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, failure == nil, let channel = converted.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength)))
    }
}
