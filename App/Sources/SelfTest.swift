import AVFoundation
import Foundation

/// A hands-free run of the real pipeline on the phone, for checking a build without anyone speaking or touching the screen.
/// Launch arguments (read from UserDefaults): `-selftest-wav <file in Documents>`, `-selftest-target host[:port]`,
/// `-selftest-key <key>`, `-selftest-play YES` (play the clip through the speaker and let the microphone hear it, instead of
/// feeding the audio in directly), `-selftest-exit YES`. Result lines start with `SELFTEST` on the console.
@MainActor
struct SelfTest {
    let model: AppModel
    let defaults = UserDefaults.standard

    static func runIfRequested(_ model: AppModel) async {
        let test = SelfTest(model: model)
        if let name = test.defaults.string(forKey: "selftest-sounds") {
            await test.runSounds(wav: name)
        } else if let name = test.defaults.string(forKey: "selftest-wav") {
            await test.run(wav: name)
        } else {
            return
        }
        if test.defaults.bool(forKey: "selftest-exit") { exit(0) }
    }

    /// Feeds a recording through the microphone's sample bus (so the detector and the rules see it as live audio) and prints every
    /// sound recognised and every rule that fired. `-selftest-sounds <file in Documents>`.
    private func runSounds(wav name: String) async {
        for _ in 0..<40 where model.flow.modelName.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
        guard !model.flow.modelName.isEmpty else { return say("detector not running: \(model.flow.detectorProblem ?? "unknown")") }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        guard let samples = try? Self.load(url), !samples.isEmpty else { return say("cannot read \(name)") }
        say("detector model \(model.flow.modelName), \(model.flow.detectorLabels.count) classes; clip \(samples.count / 16_000) s")
        let bus = model.session.capture.bus
        var index = 0
        while index < samples.count {
            let end = min(index + 4096, samples.count)
            bus.publish(Array(samples[index..<end]))
            index = end
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .seconds(1))
        let heard = Array(model.flow.recentSounds.reversed())
        say("heard \(heard.count) sounds")
        for sound in heard {
            let event = sound.event
            let fired = sound.firedRule.map { " FIRED \($0)" } ?? ""
            let time = String(format: "%.2f", event.time), probability = String(format: "%.3f", event.probability)
            say("t=\(time) \(event.pattern) \(event.topClass) p=\(probability)\(fired)")
        }
        say("final state \(model.flow.state.title)")
    }

    private func say(_ line: String) { print("SELFTEST \(line)") }

    private func run(wav name: String) async {
        configureTarget()
        say("waiting for the model")
        guard await waitForModel() else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        guard let samples = try? Self.load(url), !samples.isEmpty else { return say("cannot read \(name)") }
        let play = defaults.bool(forKey: "selftest-play")
        let seconds = String(format: "%.1f", Double(samples.count) / 16_000)
        say("model ready; clip \(seconds) s; mode \(play ? "speaker to microphone" : "direct")")
        let before = model.outbox.items.count
        if play {
            guard await waitForMicrophone() else { return say("microphone not ready") }
            await playThroughMicrophone(url: url)
        } else {
            await model.session.finish(.init(pcm: samples, peakDb: UtteranceBuffer.peakDb(samples)), silent: false)
        }
        for _ in 0..<40 where model.flow.text.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
        say("text box: \(model.flow.text)")
        model.flow.submit()
        await waitForDelivery(after: before)
        report(after: before)
    }

    private func configureTarget() {
        guard let address = defaults.string(forKey: "selftest-target") else { return }
        let target = MacTarget(name: "Self test", address: address)
        do {
            try model.targets.save(target, key: defaults.string(forKey: "selftest-key") ?? "")
        } catch {
            say("target save failed: \(error)")
        }
        model.targets.select(target.id)
    }

    private func waitForModel() async -> Bool {
        let start = Date()
        var last = ""
        for _ in 0..<1200 {
            let now = ModelStatusLine.text(for: model.session.model)
            if now != last {
                say(String(format: "[%.1f s] %@", Date().timeIntervalSince(start), now))
                last = now
            }
            if model.session.isModelReady { return true }
            if case .failed(let message) = model.session.model {
                say("model failed: \(message)")
                return false
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        say("model not ready after 10 minutes")
        return false
    }

    private func waitForMicrophone() async -> Bool {
        for _ in 0..<40 where !model.session.micReady { try? await Task.sleep(for: .milliseconds(250)) }
        return model.session.micReady
    }

    private func waitForDelivery(after count: Int) async {
        for _ in 0..<80 {
            if model.outbox.items.count > count, model.outbox.items.first?.status == .sent { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func report(after count: Int) {
        guard let item = model.outbox.items.first, model.outbox.items.count > count else {
            return say("no transcript: \(model.session.notice)")
        }
        say("text: \(item.text)")
        say("status: \(item.status.rawValue) attempts \(item.attempts) asrMs \(item.asrMs ?? -1) networkMs \(item.networkMs ?? -1) "
            + "macMs \(item.macMs ?? -1) error \(item.lastError ?? "none")")
    }

    private func playThroughMicrophone(url: URL) async {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.volume = 1
        model.session.beginHold()
        try? await Task.sleep(for: .milliseconds(500))
        player.play()
        while player.isPlaying { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(400))
        model.session.endHold()
    }

    private static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let capacity = AVAudioFrameCount(file.length)
        guard file.processingFormat.sampleRate == 16_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return [] }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }
}
