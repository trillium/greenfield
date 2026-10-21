import Foundation

/// One Log line per interval while the app is in the background, counted from the audio callbacks that already run: no timer, no
/// extra wakeup. It is the proof, readable in the app log, that capture kept going while the screen was off.
/// `total` counts every chunk since the app went to the background, so a checker can see it rise line after line.
struct CaptureHeartbeat: Equatable, Sendable {
    static let defaultInterval: TimeInterval = 30

    /// Seconds between lines; a device test can shorten it so a gap shows within a minute.
    var interval: TimeInterval = CaptureHeartbeat.defaultInterval

    private var windowStart: Date?
    private var chunks = 0
    private var total = 0
    private var peakDb: Float = -100

    /// Call once per audio chunk. Returns the line to log when a full interval has passed.
    mutating func tick(now: Date, decibels: Float) -> String? {
        guard let start = windowStart else {
            windowStart = now
            return nil
        }
        chunks += 1
        total += 1
        peakDb = max(peakDb, decibels)
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= interval else { return nil }
        let line = "capture alive in background: \(chunks) audio chunks in \(Int(elapsed.rounded())) s, peak \(Int(peakDb)) dBFS, "
            + "total \(total)"
        chunks = 0
        peakDb = -100
        windowStart = now
        return line
    }

    /// Foreground, or capture stopped: start the next stretch fresh.
    mutating func reset() {
        windowStart = nil
        chunks = 0
        total = 0
        peakDb = -100
    }
}
