import Foundation

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
final class SoundListener: @unchecked Sendable {
    let labels: [String]
    private let detector: SoundDetector
    private var subscription: SampleBus.Subscription?
    private let onEvents: @Sendable ([SoundEvent]) -> Void
    /// The library allows one thread at a time; the microphone's audio thread is the normal caller and a test feed may be another.
    private let lock = NSLock()

    /// `onEvents` runs on the main queue.
    init(detector: SoundDetector, bus: SampleBus, onEvents: @escaping @Sendable ([SoundEvent]) -> Void) {
        self.detector = detector
        labels = detector.labels
        self.onEvents = onEvents
        subscription = bus.subscribe { [weak self] chunk in self?.hear(chunk) }
    }

    func cancel() { subscription?.cancel() }

    private func hear(_ chunk: [Float]) {
        lock.lock()
        let events = detector.push(chunk)
        lock.unlock()
        guard !events.isEmpty else { return }
        let deliver = onEvents
        // The main queue keeps order: two sounds in a row must reach the rules in the order they happened.
        DispatchQueue.main.async { deliver(events) }
    }
}
