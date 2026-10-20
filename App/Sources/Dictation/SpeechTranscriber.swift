import FluidAudio
import Foundation

/// Turns 16 kHz mono float audio into text, on the phone. The first call to `prepare` downloads the model if it is not there yet.
protocol SpeechTranscriber: Sendable {
    /// Downloads (first run only) and loads the model. `progress` is 0...1, called on an unspecified queue.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func transcribe(_ samples: [Float]) async throws -> String
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

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: version) { progress($0.fractionCompleted) }
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        manager = asr
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw Failure.notPrepared }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &state).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
