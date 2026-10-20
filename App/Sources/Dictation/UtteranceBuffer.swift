import Foundation

/// Keeps the most recent microphone audio and cuts one utterance out of it between a press and a release.
/// The microphone runs all the time while the screen is open, so the half second before the finger lands is already here: a
/// speaker who starts talking as they press does not lose their first word. Value type; the owner serialises access.
struct UtteranceBuffer {
    struct Config: Equatable {
        /// Audio kept from before the press.
        var preRollSeconds = 0.4
        /// Audio kept after the release, for a word still ending when the finger lifts (the microphone is still running).
        var tailSeconds = 0.15
        /// A hold longer than this is cut off.
        var maxHoldSeconds = 120.0
        /// Quieter than this over the whole hold counts as silence, not speech.
        var silenceDb: Float = -55
    }

    struct Utterance: Equatable {
        var pcm: [Float]
        var seconds: Double { Double(pcm.count) / AudioCapture.sampleRate }
        /// Peak 10 ms frame level in dBFS.
        var peakDb: Float
    }

    let config: Config
    private var samples: [Float] = []
    /// Stream index of `samples[0]`.
    private var firstIndex = 0
    private var holdStart: Int?
    private var holdEnd: Int?

    init(config: Config = Config()) { self.config = config }

    /// True between `beginHold()` and the end of the tail after `endHold()`.
    var isHolding: Bool { holdStart != nil && holdEnd == nil }
    var hasPendingTail: Bool { holdStart != nil && holdEnd != nil }

    private var streamEnd: Int { firstIndex + samples.count }
    private static func count(_ seconds: Double) -> Int { Int((seconds * AudioCapture.sampleRate).rounded()) }

    mutating func append(_ chunk: [Float]) {
        samples += chunk
        if let start = holdStart, holdEnd == nil, streamEnd - start > Self.count(config.maxHoldSeconds) {
            holdEnd = start + Self.count(config.maxHoldSeconds)
        }
        trim()
    }

    /// `preRollSeconds` overrides the configured pre-roll (a sound that starts dictation wants none: it is not part of the speech).
    mutating func beginHold(preRollSeconds: Double? = nil) {
        holdStart = max(streamEnd - Self.count(preRollSeconds ?? config.preRollSeconds), firstIndex)
        holdEnd = nil
    }

    /// Marks the release. The utterance is complete `tailSeconds` of audio later (`takeFinished`), or at once with `flush: true`.
    /// A negative `tailSeconds` ends the utterance that much before now, for a sound that ends dictation: the sound itself is cut off.
    mutating func endHold(tailSeconds: Double? = nil) {
        guard let start = holdStart, holdEnd == nil else { return }
        holdEnd = max(streamEnd + Self.count(tailSeconds ?? config.tailSeconds), start)
    }

    /// The utterance once the tail has arrived (nil before that, or when nothing was held). Resets the hold.
    mutating func takeFinished(flush: Bool = false) -> Utterance? {
        guard let start = holdStart, let end = holdEnd else { return nil }
        guard flush || streamEnd >= end else { return nil }
        let stop = min(end, streamEnd)
        defer { holdStart = nil; holdEnd = nil; trim() }
        guard stop > start else { return nil }
        let pcm = Array(samples[(start - firstIndex)..<(stop - firstIndex)])
        return Utterance(pcm: pcm, peakDb: Self.peakDb(pcm))
    }

    /// The audio held so far in the current hold (nil when not holding), for listening in while dictation is still going.
    func heldSoFar() -> [Float]? {
        guard let start = holdStart, holdEnd == nil, streamEnd > start else { return nil }
        return Array(samples[(start - firstIndex)..<(streamEnd - firstIndex)])
    }

    /// True when the last `seconds` of `pcm` are all below `threshold` dB: a pause after speech.
    static func endsQuiet(_ pcm: [Float], seconds: Double, below threshold: Float = -48) -> Bool {
        let count = Int(seconds * AudioCapture.sampleRate)
        guard pcm.count >= count, count > 0 else { return false }
        return peakDb(Array(pcm[(pcm.count - count)...])) < threshold
    }

    /// True when the utterance is too quiet to contain speech.
    func isSilent(_ utterance: Utterance) -> Bool { utterance.peakDb < config.silenceDb }

    /// Drops everything: a microphone loss must not splice audio from before and after.
    mutating func reset() {
        samples = []
        firstIndex = 0
        holdStart = nil
        holdEnd = nil
    }

    private mutating func trim() {
        let keepFrom = holdStart ?? (streamEnd - Self.count(config.preRollSeconds))
        let drop = min(keepFrom - firstIndex, samples.count)
        guard drop > 0 else { return }
        samples.removeFirst(drop)
        firstIndex += drop
    }

    static func peakDb(_ pcm: [Float]) -> Float {
        var peak: Float = -100
        var index = 0
        while index < pcm.count {
            let end = min(index + Endpointer.frameSamples, pcm.count)
            peak = max(peak, Endpointer.decibels(pcm[index..<end]))
            index = end
        }
        return peak
    }
}
