import XCTest
@testable import DictationApp

final class SampleBusTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var chunks: [[Float]] = []
    }

    func testEverySubscriberSeesEveryChunkInOrder() {
        let bus = SampleBus()
        let first = Box(), second = Box()
        let one = bus.subscribe { first.chunks.append($0) }
        let two = bus.subscribe { second.chunks.append($0) }
        bus.publish([1, 2])
        bus.publish([3])
        XCTAssertEqual(first.chunks, [[1, 2], [3]])
        XCTAssertEqual(second.chunks, [[1, 2], [3]])
        withExtendedLifetime((one, two)) {}
    }

    func testCancelledAndReleasedSubscribersStopReceiving() {
        let bus = SampleBus()
        let kept = Box(), cancelled = Box(), released = Box()
        let keep = bus.subscribe { kept.chunks.append($0) }
        let cancel = bus.subscribe { cancelled.chunks.append($0) }
        var temp: SampleBus.Subscription? = bus.subscribe { released.chunks.append($0) }
        XCTAssertEqual(bus.subscriberCount, 3)
        cancel.cancel()
        temp = nil
        bus.publish([9])
        XCTAssertEqual(kept.chunks, [[9]])
        XCTAssertTrue(cancelled.chunks.isEmpty)
        XCTAssertTrue(released.chunks.isEmpty)
        XCTAssertEqual(bus.subscriberCount, 1)
        withExtendedLifetime((keep, temp)) {}
    }

    func testASinkMayCancelItselfWhilePublishing() {
        let bus = SampleBus()
        let seen = Box()
        nonisolated(unsafe) var subscription: SampleBus.Subscription?
        subscription = bus.subscribe { chunk in
            seen.chunks.append(chunk)
            subscription?.cancel()
        }
        bus.publish([1])
        bus.publish([2])
        XCTAssertEqual(seen.chunks, [[1]])
    }
}
