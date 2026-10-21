import Foundation
import KitAssist

/// Where pointer events end up. The pointer service knows nothing about the operating system: it hands the events of an authenticated
/// session to a sink. Tests and every harness use `RecordingSink`; only `CGEventPointerSink` moves a real cursor, and only the daemon
/// builds that one (see `docs/assist-pointer.md`).
public protocol PointerSink: AnyObject {
    /// What this sink can render, so the phone hides the rest (`AssistCapabilities` bits sent in HELLO_ACK).
    var capabilities: AssistCapabilities { get }
    /// Applies the events in order. Events the sink cannot render are ignored.
    func apply(_ events: [PointerEvent])
}

/// Remembers every event it was given and does nothing else. The sink for tests, and for a daemon that must not inject.
public final class RecordingSink: PointerSink {
    public var capabilities: AssistCapabilities
    private let lock = NSLock()
    private var recorded: [PointerEvent] = []

    public init(capabilities: AssistCapabilities = []) { self.capabilities = capabilities }

    public var events: [PointerEvent] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    public func apply(_ events: [PointerEvent]) {
        lock.lock(); defer { lock.unlock() }
        recorded += events
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        recorded = []
    }
}
