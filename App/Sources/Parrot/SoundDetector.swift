import Foundation
import ParrotKit

/// One recognised sound: which configured pattern fired and how sure the model was.
struct SoundEvent: Equatable, Sendable, Identifiable {
    let id = UUID()
    /// End of the 30 ms window, in seconds of audio since the detector started listening.
    let time: Double
    /// The pattern that fired, e.g. "tongue-click" (the name rules refer to).
    let pattern: String
    /// The model's most likely class for the window, e.g. "alviolar_tongue_click".
    let topClass: String
    let probability: Double
    /// RMS of the window times 1000.
    let power: Double
}

struct SoundDetectorError: Error, CustomStringConvertible {
    let operation: String
    let message: String
    var description: String { "\(operation) failed: \(message)" }
}

/// The sound-detector library (`pq_*` C interface) wrapped in Swift. One detector must be driven from one thread at a time, so
/// this class is not `Sendable`; `SoundListener` owns it and calls it only from the audio thread.
final class SoundDetector {
    static var abiVersion: Int { Int(pq_abi_version()) }
    static var libraryVersion: String { String(cString: pq_version()) }

    /// Class names in the model's own order.
    let labels: [String]
    private var handle: OpaquePointer?
    private let sink: EventSink

    /// - Parameter patternsJSON: patterns for this model; nil uses the set built into the library, which matches the bundled model.
    init(model: [UInt8], patternsJSON: String? = nil) throws {
        guard Self.abiVersion == Int(PQ_ABI_VERSION) else {
            let message = "library ABI \(Self.abiVersion), app built for \(PQ_ABI_VERSION)"
            throw SoundDetectorError(operation: "pq_abi_version", message: message)
        }
        guard let created = model.withUnsafeBufferPointer({ pq_new($0.baseAddress, $0.count, patternsJSON) }) else {
            throw SoundDetectorError(operation: "pq_new", message: String(cString: pq_last_error()))
        }
        handle = created
        labels = Self.decodeLabels(pq_labels_json(created))
        sink = EventSink(labels: labels)
    }

    deinit { pq_close(handle) }

    /// Push 16 kHz mono samples in any chunk size; returns the sounds recognised in this chunk, in order.
    func push(_ samples: [Float]) -> [SoundEvent] {
        sink.events.removeAll(keepingCapacity: true)
        let user = Unmanaged.passUnretained(sink).toOpaque()
        samples.withUnsafeBufferPointer { pq_push(handle, $0.baseAddress, $0.count, soundEventCallback, user) }
        return sink.events
    }

    private static func decodeLabels(_ raw: UnsafeMutablePointer<CChar>?) -> [String] {
        guard let raw else { return [] }
        defer { pq_string_free(raw) }
        return (try? JSONDecoder().decode([String].self, from: Data(String(cString: raw).utf8))) ?? []
    }
}

/// Collects the events one `pq_push` call fires. The C callback cannot capture, so it finds this object through `user`.
private final class EventSink {
    let labels: [String]
    var events: [SoundEvent] = []
    init(labels: [String]) { self.labels = labels }

    func append(time: Double, power: Double, probs: UnsafeBufferPointer<Float>, pattern: String, top: Int) {
        let valid = top >= 0 && top < probs.count && top < labels.count
        events.append(SoundEvent(time: time, pattern: pattern, topClass: valid ? labels[top] : "?",
                                 probability: valid ? Double(probs[top]) : 0, power: power))
    }
}

private let soundEventCallback: pq_event_fn = { user, time, power, probs, count, pattern, top in
    guard let user, let pattern else { return }
    Unmanaged<EventSink>.fromOpaque(user).takeUnretainedValue()
        .append(time: time, power: power, probs: UnsafeBufferPointer(start: probs, count: count),
                pattern: String(cString: pattern), top: top)
}

/// Subscribes a detector to the microphone's sample bus and reports what it hears on the main queue, in order.
/// The detector runs on the audio thread (one thread, as the library requires); nothing else touches it.
///
/// The input gain from the Levels screen is applied here, to the samples the detector hears and to the level meter, and nowhere else:
/// speech recognition takes its audio from the bus untouched.
final class SoundListener: @unchecked Sendable {
    /// 16 kHz mono, the bus's own format, so audio time is samples over this.
    private static let sampleRate = 16_000.0

    let labels: [String]
    private let detector: SoundDetector
    private var subscription: SampleBus.Subscription?
    private let onEvents: @Sendable ([SoundEvent]) -> Void
    private let onReading: (@Sendable (LevelReading) -> Void)?
    private let gain: Double
    /// The library allows one thread at a time; the microphone's audio thread is the normal caller and a test feed may be another.
    private let lock = NSLock()
    // Meter state, guarded by `lock`.
    private var scaled: [Float] = []
    private var sumOfSquares = 0.0
    private var counted = 0
    private var samplesSeen = 0
    private var pendingFired: [FiredSound] = []

    /// `onEvents` and `onReading` run on the main queue. `onReading` gets the input level (after the gain) about twenty times a second and
    /// whatever fired since the last one; nil leaves the meter arithmetic off.
    init(detector: SoundDetector, bus: SampleBus, gain: Double = 1, onReading: (@Sendable (LevelReading) -> Void)? = nil,
         onEvents: @escaping @Sendable ([SoundEvent]) -> Void) {
        self.detector = detector
        labels = detector.labels
        self.gain = gain
        self.onReading = onReading
        self.onEvents = onEvents
        subscription = bus.subscribe { [weak self] chunk in self?.hear(chunk) }
    }

    func cancel() { subscription?.cancel() }

    private func hear(_ chunk: [Float]) {
        lock.lock()
        if gain != 1 { chunk.withUnsafeBufferPointer { InputGain.apply($0, gain: gain, into: &scaled) } }
        let events = detector.push(gain == 1 ? chunk : scaled)
        let reading = meter(gain == 1 ? chunk : scaled, events: events)
        lock.unlock()
        let deliver = onEvents
        // The main queue keeps order: two sounds in a row must reach the rules in the order they happened.
        if !events.isEmpty { DispatchQueue.main.async { deliver(events) } }
        if let reading, let onReading { DispatchQueue.main.async { onReading(reading) } }
    }

    /// Adds this chunk to the level being averaged and returns a reading when one is due. Called with the lock held.
    private func meter(_ heard: [Float], events: [SoundEvent]) -> LevelReading? {
        guard onReading != nil else { return nil }
        sumOfSquares += heard.withUnsafeBufferPointer { InputLevel.sumOfSquares($0) }
        counted += heard.count
        samplesSeen += heard.count
        pendingFired += events.map { FiredSound(name: $0.pattern, probability: $0.probability, power: $0.power, at: $0.time) }
        guard counted >= InputLevel.updateStride || !events.isEmpty else { return nil }
        let reading = LevelReading(at: Double(samplesSeen) / Self.sampleRate,
                                   power: InputLevel.power(sumOfSquares: sumOfSquares, count: counted), fired: pendingFired)
        sumOfSquares = 0
        counted = 0
        pendingFired = []
        return reading
    }
}
