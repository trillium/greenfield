import Foundation

/// Streaming energy endpointer: feed 16 kHz mono float PCM in chunks of any size, get back finished utterances.
/// 10 ms frames, a speech frame is one above `thresholdDb` (dBFS of the frame's mean square). A segment starts after
/// `startFrames` consecutive speech frames (and includes `preRollFrames` before them), and ends after `hangoverFrames`
/// of non-speech (keeping `tailFrames` of the quiet after the last speech frame). Segments are cut at `maxFrames`.
/// Fixed thresholds are right for clean audio. For a live microphone set `floorMarginDb`: the threshold then follows a slow
/// estimate of the room's noise floor (never below `thresholdDb`), so a noisy room does not hold an utterance open.
struct Endpointer {
    struct Config: Equatable {
        var thresholdDb: Float = -45
        var startFrames = 3
        var preRollFrames = 20
        var hangoverFrames = 60
        var tailFrames = 20
        var maxFrames = 2000
        /// nil keeps the threshold fixed. Otherwise a speech frame must also be this far above the tracked noise floor.
        var floorMarginDb: Float?
    }

    struct Segment {
        /// Absolute sample indices in the stream, `end` exclusive.
        let start: Int
        let end: Int
        let pcm: [Float]
        let forcedCut: Bool
    }

    static let frameSamples = 160

    let config: Config
    private var buffer: [Float] = []
    /// Stream index of `buffer[0]`; always a multiple of `frameSamples`.
    private var bufferStart = 0
    private var framesSeen = 0
    private var consecutiveLoud = 0
    private var segmentStartFrame: Int?
    private var lastLoudFrame = 0
    private var floorDb: Float?

    /// True while an utterance is open (speech started, hangover not yet over).
    var isSpeaking: Bool { segmentStartFrame != nil }

    init(config: Config = Config()) { self.config = config }

    mutating func feed(_ chunk: [Float]) -> [Segment] {
        buffer += chunk
        var done: [Segment] = []
        while buffer.count - (framesSeen * Self.frameSamples - bufferStart) >= Self.frameSamples {
            let offset = framesSeen * Self.frameSamples - bufferStart
            let level = Self.decibels(buffer[offset..<(offset + Self.frameSamples)])
            let loud = level > threshold(for: level)
            if let segment = step(loud: loud) { done.append(segment) }
        }
        trim()
        return done
    }

    /// Ends an utterance that is still open when the stream stops.
    mutating func finish() -> [Segment] {
        defer { segmentStartFrame = nil; consecutiveLoud = 0 }
        guard let startFrame = segmentStartFrame else { return [] }
        return [cut(from: startFrame, to: min(lastLoudFrame + 1 + config.tailFrames, framesSeen), forced: false)]
    }

    /// The floor only learns from frames that are not clearly speech, and only while no utterance is open.
    private mutating func threshold(for level: Float) -> Float {
        guard let margin = config.floorMarginDb else { return config.thresholdDb }
        let floor = floorDb ?? level
        let effective = max(config.thresholdDb, floor + margin)
        if segmentStartFrame == nil && level <= effective { floorDb = floor + (level - floor) * 0.05 } else { floorDb = floor }
        return effective
    }

    private mutating func step(loud: Bool) -> Segment? {
        let frame = framesSeen
        framesSeen += 1
        guard let startFrame = segmentStartFrame else {
            consecutiveLoud = loud ? consecutiveLoud + 1 : 0
            if consecutiveLoud >= config.startFrames {
                segmentStartFrame = max(frame - (config.startFrames - 1) - config.preRollFrames, bufferStart / Self.frameSamples)
                lastLoudFrame = frame
            }
            return nil
        }
        if loud { lastLoudFrame = frame }
        if frame - lastLoudFrame >= config.hangoverFrames {
            return close(from: startFrame, to: lastLoudFrame + 1 + config.tailFrames, forced: false)
        }
        if frame + 1 - startFrame >= config.maxFrames {
            return close(from: startFrame, to: frame + 1, forced: true)
        }
        return nil
    }

    private mutating func close(from startFrame: Int, to endFrame: Int, forced: Bool) -> Segment {
        segmentStartFrame = nil
        consecutiveLoud = 0
        return cut(from: startFrame, to: endFrame, forced: forced)
    }

    private func cut(from startFrame: Int, to endFrame: Int, forced: Bool) -> Segment {
        let first = startFrame * Self.frameSamples, last = endFrame * Self.frameSamples
        return Segment(start: first, end: last, pcm: Array(buffer[(first - bufferStart)..<(last - bufferStart)]), forcedCut: forced)
    }

    /// Idle: keep only what a pre-roll could still need. Speaking: keep everything since the segment began.
    private mutating func trim() {
        let keepFrame = segmentStartFrame ?? max(framesSeen - config.preRollFrames - config.startFrames, 0)
        let drop = keepFrame * Self.frameSamples - bufferStart
        guard drop > 0 else { return }
        buffer.removeFirst(drop)
        bufferStart += drop
    }

    static func decibels(_ frame: ArraySlice<Float>) -> Float {
        let meanSquare = frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count)
        return 10 * log10(meanSquare + 1e-10)
    }
}
