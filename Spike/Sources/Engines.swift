import FluidAudio
import Foundation
import MoonshineVoice
import WhisperKit

/// One speech recogniser under test. `prepare` downloads (if needed) and loads; the two phases are timed separately by the runner.
protocol SpikeEngine: AnyObject {
    var id: String { get }
    /// What the result table calls it, with the exact model and package version.
    var label: String { get }
    func download() async throws
    func load() async throws
    func transcribe(_ samples: [Float]) async throws -> String
}

enum SpikeEngines {
    static let packageVersions = [
        "FluidAudio": "0.17.7", "WhisperKit (argmax-oss-swift)": "1.1.1", "MoonshineVoice (moonshine-swift)": "0.1.5"
    ]

    private static func parakeet(_ version: AsrModelVersion, _ name: String) -> (String) -> SpikeEngine {
        { ParakeetEngine(id: $0, version: version, label: "\(name) (FluidAudio)") }
    }

    private static func whisper(_ variant: String, _ name: String) -> (String) -> SpikeEngine {
        { WhisperEngine(id: $0, variant: variant, label: "\(name) (WhisperKit)") }
    }

    private static func moonshine(_ arch: ModelArch, _ name: String) -> (String) -> SpikeEngine {
        { MoonshineEngine(id: $0, arch: arch, label: "\(name) (MoonshineVoice)") }
    }

    private static let table: [(id: String, make: (String) -> SpikeEngine)] = [
        ("parakeet-v2", parakeet(.v2, "Parakeet TDT 0.6B v2")),
        ("parakeet-v3", parakeet(.v3, "Parakeet TDT 0.6B v3")),
        ("parakeet-ultra", parakeet(.ultra, "Parakeet Ultra")),
        ("parakeet-tdt-ctc-110m", parakeet(.tdtCtc110m, "Parakeet TDT-CTC 110M")),
        ("whisper-large-v3-626mb", whisper("openai_whisper-large-v3-v20240930_626MB", "Whisper large-v3 20240930 (626 MB)")),
        ("whisper-small-216mb", whisper("openai_whisper-small_216MB", "Whisper small (216 MB)")),
        ("whisper-base-en", whisper("openai_whisper-base.en", "Whisper base.en")),
        ("moonshine-medium-streaming", moonshine(.mediumStreaming, "Moonshine Medium Streaming")),
        ("moonshine-small-streaming", moonshine(.smallStreaming, "Moonshine Small Streaming")),
        ("moonshine-tiny-streaming", moonshine(.tinyStreaming, "Moonshine Tiny Streaming"))
    ]

    static var all: [String] { table.map(\.id) }

    static func make(_ id: String) -> SpikeEngine? {
        table.first { $0.id == id }?.make(id)
    }
}

final class ParakeetEngine: SpikeEngine {
    let id: String
    let label: String
    private let version: AsrModelVersion
    private var models: AsrModels?
    private var manager: AsrManager?

    init(id: String, version: AsrModelVersion, label: String) {
        self.id = id
        self.version = version
        self.label = label
    }

    func download() async throws {
        _ = try await AsrModels.download(version: version)
    }

    func load() async throws {
        let loaded = try await AsrModels.downloadAndLoad(version: version)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(loaded)
        models = loaded
        manager = asr
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw SpikeError.notLoaded }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &state).text
    }
}

final class WhisperEngine: SpikeEngine {
    let id: String
    let label: String
    private let variant: String
    private var folder: URL?
    private var kit: WhisperKit?

    init(id: String, variant: String, label: String) {
        self.id = id
        self.variant = variant
        self.label = label
    }

    func download() async throws {
        folder = try await WhisperKit.download(variant: variant)
    }

    func load() async throws {
        if folder == nil { try await download() }
        let config = WhisperKitConfig(modelFolder: folder?.path, verbose: false, prewarm: false, load: true, download: false)
        kit = try await WhisperKit(config)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let kit else { throw SpikeError.notLoaded }
        let options = DecodingOptions(language: "en", skipSpecialTokens: true, withoutTimestamps: true)
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

final class MoonshineEngine: SpikeEngine {
    let id: String
    let label: String
    private let arch: ModelArch
    private var transcriber: Transcriber?

    init(id: String, arch: ModelArch, label: String) {
        self.id = id
        self.arch = arch
        self.label = label
    }

    func download() async throws {
        let spec = ModelSpec.stt(language: "en", modelArch: arch)
        let directory = try ModelCache.directory(for: spec)
        _ = try await AssetDownloader().ensureModelPresent(root: directory, spec: spec, onProgress: nil)
    }

    func load() async throws {
        transcriber = try await Transcriber.load(language: "en", modelArch: arch)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let transcriber else { throw SpikeError.notLoaded }
        let transcript = try transcriber.transcribeWithoutStreaming(audioData: samples, sampleRate: 16_000)
        return transcript.lines.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

enum SpikeError: Error, CustomStringConvertible {
    case notLoaded
    case missingAudio(String)
    case unknownEngine(String)

    var description: String {
        switch self {
        case .notLoaded: return "engine is not loaded"
        case .missingAudio(let name): return "missing audio clip \(name)"
        case .unknownEngine(let id): return "unknown engine \(id)"
        }
    }
}
