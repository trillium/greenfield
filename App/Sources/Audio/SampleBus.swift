import Foundation

/// Fans the single microphone tap out to any number of consumers. `AudioCapture` publishes each 16 kHz mono chunk here from the audio
/// thread; a sink must copy what it needs and return quickly (no model call, no blocking I/O on the audio thread).
/// Sinks are called in subscription order. Subscribing and cancelling are safe from any thread, including from inside a sink.
final class SampleBus: @unchecked Sendable {
    typealias Sink = @Sendable ([Float]) -> Void

    /// Cancels its subscription when `cancel()` is called or when it is released.
    final class Subscription: @unchecked Sendable {
        private weak var bus: SampleBus?
        fileprivate let id: Int

        fileprivate init(bus: SampleBus, id: Int) {
            self.bus = bus
            self.id = id
        }

        func cancel() { bus?.remove(id) }
        deinit { cancel() }
    }

    private let lock = NSLock()
    private var sinks: [(id: Int, sink: Sink)] = []
    private var nextID = 0

    /// Number of live subscribers.
    var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sinks.count
    }

    /// Keep the returned subscription for as long as the sink should receive audio.
    func subscribe(_ sink: @escaping Sink) -> Subscription {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        sinks.append((nextID, sink))
        return Subscription(bus: self, id: nextID)
    }

    func publish(_ samples: [Float]) {
        lock.lock()
        let current = sinks
        lock.unlock()
        for entry in current { entry.sink(samples) }
    }

    fileprivate func remove(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        sinks.removeAll { $0.id == id }
    }
}
