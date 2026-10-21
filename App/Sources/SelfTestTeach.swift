import Foundation
import ParrotKit

/// `-selftest-teach YES`: a whole Teach run on the phone with made-up audio, never anyone's recordings. It records the baseline and two
/// synthetic sounds through the real recording path (the app's sample bus into a `TeachModel`), trains on the real trainer found by
/// discovery, installs the returned model through a `ParrotModelStore` that runs the app's detector check, switches to it, goes back, and
/// finally feeds one synthetic sound through a detector built from the new model. The library and the store live in a temporary folder, so
/// the models and settings a person uses are untouched. Result lines start with `SELFTEST`.
@MainActor
extension SelfTest {
    func runTeach() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-teach-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "selftest.teach.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let store = ParrotModelStore.app(directory: root.appendingPathComponent("models"))
        let bus = SampleBus()
        let teach = TeachModel(library: TeachLibrary(directory: root.appendingPathComponent("library")), store: store,
                               microphone: SessionMicrophone(bus: bus, makeReady: { nil }), addressProvider: model.trainers,
                               configuration: model.trainerConfiguration, policy: .activateKeepingPrevious, defaults: defaults,
                               makeClient: AppTeach.makeClient)

        say("teach: looking for the trainer")
        await model.peers.refresh()
        await model.trainers.refresh()
        for trainer in model.trainers.trainers {
            say("teach: trainer \(trainer.name) source=\(trainer.source.rawValue): \(model.trainers.probe(for: trainer).summary)")
        }
        guard let chosen = model.trainers.chosen else { return say("teach: FAIL no trainer was found") }
        say("teach: chosen trainer \(chosen.name) (found by itself, nothing typed)")

        await recordEverything(teach, bus: bus)
        say("teach: canTrain=\(teach.progress.canTrain) next=\(teach.nextStep) checklist=\(teach.checklist.done)/\(teach.checklist.total)")

        let before = store.activeID
        guard case let .review(review) = await train(teach) else { return say("teach: FAIL ended in \(teach.training)") }
        let labels = review.entry.labels.joined(separator: ",")
        say("teach: model \(review.entry.name) labels=\(labels) patterns=\(review.entry.patterns.joined(separator: ","))")
        say("teach: accuracy=\(review.accuracy.map { String(format: "%.3f", $0) } ?? "none") perSound=\(review.perSound)")
        say("teach: active before=\(before ?? "built-in") after=\(store.activeID ?? "built-in") isActive=\(review.isActive) "
            + "canGoBack=\(review.canGoBack)")
        say("teach: installed models \(store.list().map(\.name))")

        await checkRecognises(store: store)

        teach.goBackToPreviousModel()
        say("teach: went back, active=\(store.activeID ?? "built-in"), still installed \(store.list().count) model(s)")
        say("teach: PASS the run reached a model, installed it through the store (detector check) and switched to it")
    }

    /// The baseline and two made-up sounds, 41 s each, through the real recording path: the bus into a `TeachModel` take.
    private func recordEverything(_ teach: TeachModel, bus: SampleBus) async {
        let kinds: [(String, [Float])] = [
            ("background_noise_regular", Synthetic.room(seconds: 41)),
            ("background_noise_talking", Synthetic.talking(seconds: 41)),
            ("silence", Synthetic.silence(seconds: 41)),
            ("synthetic_click", Synthetic.clicks(seconds: 41)),
            ("synthetic_whistle", Synthetic.whistles(seconds: 41))
        ]
        for label in ["synthetic_click", "synthetic_whistle"] { _ = try? teach.addSound(named: label) }
        for (label, samples) in kinds {
            teach.startRecording(label)
            for _ in 0..<100 where teach.recording == nil || bus.subscriberCount == 0 { try? await Task.sleep(for: .milliseconds(20)) }
            var index = 0
            while index < samples.count {
                let end = min(index + 4096, samples.count)
                bus.publish(Array(samples[index..<end]))
                index = end
                try? await Task.sleep(for: .milliseconds(1))
            }
            teach.stopRecording()
            say("teach: recorded \(label): \(teach.library.milliseconds(label) / 1000) s")
        }
    }

    /// Starts the run and prints every state it passes through until it ends or 20 minutes pass.
    private func train(_ teach: TeachModel) async -> TeachTrainer.State {
        let started = Date()
        teach.train()
        var last = ""
        while Date().timeIntervalSince(started) < 1_200 {
            let now = "\(teach.training)"
            if now != last, !now.hasPrefix("review") {
                say("teach: +\(Int(Date().timeIntervalSince(started))) s \(now)")
                last = now
            }
            if case .review = teach.training { break }
            if case .failed = teach.training { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return teach.training
    }

    /// Builds a detector from the model now in use and plays a synthetic click and a synthetic whistle through it.
    private func checkRecognises(store: ParrotModelStore) async {
        guard let source = try? store.source(),
              let detector = try? SoundDetector(model: source.model, patternsJSON: source.patternsJSON) else {
            return say("teach: could not build a detector from the new model")
        }
        say("teach: detector from the new model has \(detector.labels.count) classes")
        for (name, samples) in [("click", Synthetic.clicks(seconds: 6)), ("whistle", Synthetic.whistles(seconds: 6)),
                                ("silence", Synthetic.silence(seconds: 6))] {
            var events: [SoundEvent] = []
            var index = 0
            while index < samples.count {
                events += detector.push(Array(samples[index..<min(index + 4096, samples.count)]))
                index += 4096
            }
            let counts = Dictionary(grouping: events.filter { !$0.pattern.hasPrefix("suppress") }, by: \.pattern).mapValues(\.count)
            say("teach: synthetic \(name) -> patterns fired \(counts)")
        }
    }
}

/// Made-up audio for the self test: deterministic, no voice, nothing recorded from a person.
enum Synthetic {
    private struct Noise {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: state >> 11) % 20_000) / 10_000 - 1
        }
    }

    static func room(seconds: Int) -> [Float] {
        var noise = Noise()
        return (0..<(seconds * 16_000)).map { index in noise.next() * (0.03 + 0.01 * sin(Float(index) / 40_000)) }
    }

    static func silence(seconds: Int) -> [Float] {
        var noise = Noise()
        return (0..<(seconds * 16_000)).map { _ in noise.next() * 0.001 }
    }

    /// Voiced, syllable-shaped noise: a harmonic stack under a 4 Hz envelope.
    static func talking(seconds: Int) -> [Float] {
        var noise = Noise()
        return (0..<(seconds * 16_000)).map { index in
            let time = Float(index) / 16_000
            let envelope = max(0, sin(time * 2 * .pi * 4)) * (0.6 + 0.4 * sin(time * 0.9))
            let pitch = 110 + 30 * sin(time * 1.3)
            var voiced: Float = 0
            for harmonic in 1...8 { voiced += sin(time * 2 * .pi * pitch * Float(harmonic)) / Float(harmonic) }
            return (voiced * 0.12 + noise.next() * 0.02) * envelope
        }
    }

    /// Short loud decaying bursts of noise about every 0.6 s.
    static func clicks(seconds: Int) -> [Float] {
        var noise = Noise()
        var output = [Float](repeating: 0, count: seconds * 16_000)
        var start = 4_000
        while start + 400 < output.count {
            for offset in 0..<200 { output[start + offset] = noise.next() * 0.8 * exp(-Float(offset) / 40) }
            start += 9_600 + Int(abs(noise.next()) * 1_600)
        }
        return output.map { $0 + noise.next() * 0.002 }
    }

    /// 2.5 kHz tone bursts of 150 ms about every 0.8 s.
    static func whistles(seconds: Int) -> [Float] {
        var noise = Noise()
        var output = [Float](repeating: 0, count: seconds * 16_000)
        var start = 5_000
        while start + 2_400 < output.count {
            for offset in 0..<2_400 {
                let fade = min(1, Float(min(offset, 2_400 - offset)) / 200)
                output[start + offset] = sin(Float(offset) / 16_000 * 2 * .pi * 2_500) * 0.5 * fade
            }
            start += 12_800 + Int(abs(noise.next()) * 1_600)
        }
        return output.map { $0 + noise.next() * 0.002 }
    }
}
