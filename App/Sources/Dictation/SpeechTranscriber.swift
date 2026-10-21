import FluidAudio
import Foundation

/// Turns 16 kHz mono float audio into text, on the phone. The first call to `prepare` downloads the model if it is not there yet.
protocol SpeechTranscriber: Sendable {
    /// Whether the model files are already on this phone, so `prepare` will load them instead of downloading.
    func isDownloaded() -> Bool
    /// Downloads (first run only) and loads the model. `progress` is called on an unspecified queue.
    func prepare(progress: @escaping @Sendable (SpeechModelProgress) -> Void) async throws
    func transcribe(_ samples: [Float]) async throws -> String
}

/// Where `prepare` is: fetching files (0...1) or loading and compiling them for this phone.
enum SpeechModelProgress: Equatable, Sendable {
    case downloading(Double)
    case preparing
}

/// NVIDIA Parakeet through FluidAudio's Core ML build. The model is downloaded into the app's own storage on first run, never
/// bundled and never committed (docs/attribution.md).
actor ParakeetTranscriber: SpeechTranscriber {
    enum Failure: Error, CustomStringConvertible {
        case notPrepared
        var description: String { "The speech model is not loaded yet." }
    }

    /// The model every build uses until the benchmark (docs/spike-dictation.md) says otherwise.
    static let defaultVersion = AsrModelVersion.v2

    private let version: AsrModelVersion
    private var manager: AsrManager?

    init(version: AsrModelVersion = ParakeetTranscriber.defaultVersion) { self.version = version }

    /// FluidAudio keeps the model in the app's own Application Support folder, which an in-place update leaves alone.
    nonisolated func isDownloaded() -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    func prepare(progress: @escaping @Sendable (SpeechModelProgress) -> Void) async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: version) { update in
            switch update.phase {
            case .listing: progress(.downloading(0))
            case .downloading: progress(.downloading(update.fractionCompleted))
            case .compiling: progress(.preparing)
            }
        }
        progress(.preparing)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        manager = asr
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw Failure.notPrepared }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let heard = try await manager.transcribe(samples, decoderState: &state).text
        return DictationText.trimmingEdges(DictationText.normalizingNewlines(heard))
    }
}
