import AVFoundation
import Foundation
import UIKit

struct ClipResult: Codable {
    let voice: String
    let id: String
    let seconds: Double
    let ms: Double
    let rtf: Double
    let reference: String
    let hypothesis: String
    let substitutions: Int
    let deletions: Int
    let insertions: Int
    let referenceWords: Int
    let formatted: Bool
}

struct EngineReport: Codable {
    var engine = "", label = "", tag = "", device = "", systemVersion = ""
    var thermalBefore = "", thermalAfter = ""
    /// Seconds spent waiting for the phone to cool to `nominal` before this run started.
    var coolWaitSeconds = 0.0
    var downloadMs = 0.0, loadMs = 0.0, coldFirstUtteranceMs = 0.0
    var footprintBeforeMB = 0.0, footprintAfterLoadMB = 0.0, peakMB = 0.0, peakResidentMB = 0.0
    var availableBeforeMB: Double?, availableAfterLoadMB: Double?, minAvailableMB: Double?
    var latencyP50Ms = 0.0, latencyP95Ms = 0.0, rtfP50 = 0.0, rtfP95 = 0.0
    var wer = 0.0, formattedRate = 0.0
    var long: ClipResult?
    var loopCount = 0
    var loopFootprintMB: Double?
    var clips: [ClipResult] = []
    var error: String?

    /// Fills the accuracy and latency summary from the clips (pass 1) and the warm repeat (pass 2).
    mutating func summarise(warm: [ClipResult]) {
        let totals = clips.reduce(SpikeMath.WordErrors()) {
            $0 + SpikeMath.WordErrors(substitutions: $1.substitutions, deletions: $1.deletions, insertions: $1.insertions,
                                      referenceWords: $1.referenceWords)
        }
        wer = totals.rate
        formattedRate = clips.isEmpty ? 0 : Double(clips.filter(\.formatted).count) / Double(clips.count)
        latencyP50Ms = SpikeMath.percentile(warm.map(\.ms), 50)
        latencyP95Ms = SpikeMath.percentile(warm.map(\.ms), 95)
        rtfP50 = SpikeMath.percentile(warm.map(\.rtf), 50)
        rtfP95 = SpikeMath.percentile(warm.map(\.rtf), 95)
    }
}

/// Runs one engine over the fixed phrase set and reports timings, memory and accuracy. Audio comes from `Spike/Audio` in the bundle
/// (made on the Mac with `tools/spike/make_phrases.sh`; never committed).
final class SpikeRunner: @unchecked Sendable {
    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void) { self.log = log }

    static func thermalName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func deviceModel() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    /// A throttled phone makes every number after it wrong, so each run starts from a cool phone (up to `maxSeconds`).
    static func waitUntilNominal(maxSeconds: Double, log: @Sendable (String) -> Void) async -> Double {
        let start = Date()
        while ProcessInfo.processInfo.thermalState != .nominal, Date().timeIntervalSince(start) < maxSeconds {
            log("thermal state \(thermalName()): waiting to cool down")
            try? await Task.sleep(for: .seconds(15))
        }
        return Date().timeIntervalSince(start)
    }

    func run(engineID: String, tag: String, loopCount: Int) async -> EngineReport {
        let waited = await Self.waitUntilNominal(maxSeconds: 1200, log: log)
        let sampler = PeakSampler()
        defer { sampler.stop() }
        var report = EngineReport(engine: engineID, label: SpikeEngines.make(engineID)?.label ?? engineID, tag: tag,
                                  device: Self.deviceModel(), systemVersion: UIDevice.current.systemVersion,
                                  thermalBefore: Self.thermalName(), coolWaitSeconds: waited, footprintBeforeMB: Memory.footprintMB(),
                                  availableBeforeMB: Memory.availableMB(), loopCount: loopCount)
        do {
            try await measure(&report, engineID: engineID, sampler: sampler)
        } catch {
            report.error = String(describing: error)
            log("FAILED: \(error)")
        }
        report.peakMB = sampler.peakMB
        report.peakResidentMB = sampler.peakResidentMB
        report.minAvailableMB = sampler.minAvailableMB
        report.thermalAfter = Self.thermalName()
        return report
    }

    private func measure(_ report: inout EngineReport, engineID: String, sampler: PeakSampler) async throws {
        guard let engine = SpikeEngines.make(engineID) else { throw SpikeError.unknownEngine(engineID) }
        let phrases = try Self.loadPhrases()
        let voices = Self.voices()
        log("engine \(engine.label): download")
        report.downloadMs = try await Self.time { try await engine.download() }
        log("engine \(engine.label): load (\(Int(report.downloadMs)) ms download)")
        report.loadMs = try await Self.time { try await engine.load() }
        report.footprintAfterLoadMB = Memory.footprintMB()
        report.availableAfterLoadMB = Memory.availableMB()
        log("loaded in \(Int(report.loadMs)) ms, footprint \(Int(report.footprintAfterLoadMB)) MB")

        let samples = try Self.loadSamples(voices: voices, phrases: phrases)
        let warm = try await runPasses(engine, &report, samples: samples, voices: voices, phrases: phrases)
        if let voice = voices.first(where: { samples["\($0)-long"] != nil }), let pcm = samples["\(voice)-long"] {
            report.long = try await Self.transcribe(engine, pcm, voice: voice, phrase: phrases.long)
        }
        if report.loopCount > 0 {
            let pool = phrases.phrases.compactMap { samples["\(voices[0])-\($0.id)"] }
            for index in 0..<report.loopCount { _ = try await engine.transcribe(pool[index % pool.count]) }
            report.loopFootprintMB = Memory.footprintMB()
        }
        report.summarise(warm: warm)
    }

    private static func loadSamples(voices: [String], phrases: SpikePhrases) throws -> [String: [Float]] {
        var samples: [String: [Float]] = [:]
        for voice in voices {
            // The long passage is only spoken by one voice.
            let wanted = hasClip(voice: voice, id: phrases.long.id) ? phrases.phrases + [phrases.long] : phrases.phrases
            for phrase in wanted { samples["\(voice)-\(phrase.id)"] = try loadClip(voice: voice, id: phrase.id) }
        }
        return samples
    }

    /// Pass 1 fills `report.clips` (accuracy; its first call is the cold first utterance). Pass 2 returns the warm repeat (latency).
    private func runPasses(_ engine: SpikeEngine, _ report: inout EngineReport, samples: [String: [Float]], voices: [String],
                           phrases: SpikePhrases) async throws -> [ClipResult] {
        var warm: [ClipResult] = []
        for pass in 1...2 {
            for voice in voices {
                for phrase in phrases.phrases {
                    guard let pcm = samples["\(voice)-\(phrase.id)"] else { continue }
                    let result = try await Self.transcribe(engine, pcm, voice: voice, phrase: phrase)
                    if pass == 2 { warm.append(result); continue }
                    if report.clips.isEmpty { report.coldFirstUtteranceMs = result.ms }
                    report.clips.append(result)
                }
            }
        }
        return warm
    }

    private static func time(_ work: () async throws -> Void) async throws -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try await work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func transcribe(_ engine: SpikeEngine, _ pcm: [Float], voice: String,
                                   phrase: SpikePhrases.Phrase) async throws -> ClipResult {
        var text = ""
        let ms = try await time { text = try await engine.transcribe(pcm) }
        let seconds = Double(pcm.count) / 16_000
        let errors = SpikeMath.wordErrors(reference: phrase.text, hypothesis: text)
        return ClipResult(voice: voice, id: phrase.id, seconds: seconds, ms: ms, rtf: ms / 1000 / seconds, reference: phrase.text,
                          hypothesis: text, substitutions: errors.substitutions, deletions: errors.deletions,
                          insertions: errors.insertions, referenceWords: errors.referenceWords, formatted: SpikeMath.looksFormatted(text))
    }

    private static func audioFolder() -> URL? { Bundle.main.url(forResource: "Audio", withExtension: nil) }

    static func voices() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: audioFolder()?.path ?? "")) ?? []
        return Set(names.compactMap { $0.hasSuffix("-p01.wav") ? String($0.dropLast("-p01.wav".count)) : nil }).sorted()
    }

    static func loadPhrases() throws -> SpikePhrases {
        guard let url = Bundle.main.url(forResource: "phrases", withExtension: "json") else {
            throw SpikeError.missingAudio("phrases.json")
        }
        return try SpikePhrases.decode(Data(contentsOf: url))
    }

    static func hasClip(voice: String, id: String) -> Bool {
        guard let url = audioFolder()?.appendingPathComponent("\(voice)-\(id).wav") else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    static func loadClip(voice: String, id: String) throws -> [Float] {
        guard let url = audioFolder()?.appendingPathComponent("\(voice)-\(id).wav") else { throw SpikeError.missingAudio("\(voice)-\(id)") }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw SpikeError.missingAudio("\(url.path) is not readable") }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw SpikeError.missingAudio("\(url.lastPathComponent): \(error)") }
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw SpikeError.missingAudio("\(voice)-\(id) is not 16 kHz mono")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else { throw SpikeError.missingAudio("\(voice)-\(id) has no samples") }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }
}
