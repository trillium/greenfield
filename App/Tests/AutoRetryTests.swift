import XCTest
@testable import DictationApp

@MainActor
final class AutoRetryTests: XCTestCase {
    private let app = Semver(0, 2, 0)

    private struct Rig {
        let retry: AutoRetry
        let outbox: Outbox
        let log: EventLog
    }

    private func rig(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) throws -> Rig {
        StubURLProtocol.install(handler)
        let store = TargetStore(defaults: isolatedDefaults(), keys: MemoryKeyStore())
        try store.save(MacTarget(name: "macbook", address: "macbook.example.ts.net"), key: nil)
        let outbox = Outbox(url: nil)
        let client = ReceiverClient(session: StubURLProtocol.session(), tailnetConnected: { true })
        let service = DeliveryService(outbox: outbox, targets: store, client: client)
        let log = EventLog(url: nil)
        service.log = log
        let retry = AutoRetry(service: service, log: log, app: app, minimumAgent: Semver(0, 2, 0),
                          pause: { _ in try? await Task.sleep(for: .milliseconds(5)) })
        return Rig(retry: retry, outbox: outbox, log: log)
    }

    func testNothingQueuedMeansNothingToDo() async throws {
        let rig = try rig { _ in (200, json(["ok": true])) }
        let waiting = await rig.retry.runOnce()
        XCTAssertFalse(waiting)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "an empty outbox does not even ask the computer")
    }

    func testItWaitsWhileTheComputerCannotInsertThenSendsEverythingOldestFirst() async throws {
        let ready = Flag()
        let rig = try rig { request in
            if request.url?.path == "/status" { return (200, ready.value ? agentStatus() : agentStatus(accessibility: false)) }
            return (200, json(["ok": true, "delivery": "confirmed"]))
        }
        let first = rig.outbox.add(text: "first").id
        let second = rig.outbox.add(text: "second").id
        rig.outbox.markFailed(first, reason: "needs Accessibility approval")
        rig.outbox.markFailed(second, reason: "needs Accessibility approval")

        var waiting = await rig.retry.runOnce()
        XCTAssertTrue(waiting)
        XCTAssertEqual(rig.outbox.pending.count, 2, "needs Accessibility: nothing sent")
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url?.path == "/text" })
        XCTAssertTrue(rig.log.export().contains("auto-retry waiting: macbook: needs Accessibility approval"))

        ready.value = true
        waiting = await rig.retry.runOnce()
        XCTAssertFalse(waiting, "everything went")
        XCTAssertTrue(rig.outbox.pending.isEmpty)
        let sent = StubURLProtocol.requests.filter { $0.url?.path == "/text" }.compactMap { bodyJSON($0)["id"] as? String }
        XCTAssertEqual(sent, [first.uuidString, second.uuidString], "oldest first, same ids")
        XCTAssertTrue(rig.log.export().contains("can insert text, retrying 2 queued"))
    }

    func testTheWaitBetweenLooksGrowsAndResets() async throws {
        let ready = Flag()
        let rig = try rig { request in
            request.url?.path == "/status" ? (200, ready.value ? agentStatus() : agentStatus(locked: true)) : (200, json(["ok": true]))
        }
        rig.outbox.add(text: "x")
        XCTAssertEqual(rig.retry.interval, 5)
        for expected in [10.0, 20, 40, 80, 120, 120] {
            _ = await rig.retry.runOnce()
            XCTAssertEqual(rig.retry.interval, expected)
        }
        ready.value = true
        _ = await rig.retry.runOnce()
        XCTAssertEqual(rig.retry.interval, 5, "back to the short wait after a success")
    }

    func testEachBlockerIsNamed() {
        let rig = try? rig { _ in (200, json(["ok": true])) }
        let retry = rig?.retry
        var plain = ReceiverClient.MacStatus(name: "m", version: "0.2.3")
        XCTAssertNil(retry?.blocker(in: .ready(plain)))
        plain.locked = true
        XCTAssertEqual(retry?.blocker(in: .ready(plain)), "its screen is locked")
        plain.locked = false
        plain.delivery = .init(works: false, message: "paste failed", fix: nil)
        XCTAssertTrue(retry?.blocker(in: .ready(plain))?.contains("cannot insert text") ?? false)
        XCTAssertNotNil(retry?.blocker(in: .unreachable("timed out")))
        XCTAssertNotNil(retry?.blocker(in: .wrongKey))
        XCTAssertEqual(retry?.blocker(in: .ready(.init(name: "m", version: "0.1.0"))), "app and agent versions do not match")
    }

    func testTheLoopRunsByItselfAndCanBeStopped() async throws {
        let rig = try rig { request in
            request.url?.path == "/status" ? (200, agentStatus()) : (200, json(["ok": true]))
        }
        rig.outbox.add(text: "hello")
        rig.retry.start()
        for _ in 0..<100 where !rig.outbox.pending.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        rig.retry.stop()
        XCTAssertTrue(rig.outbox.pending.isEmpty, "it retried without anyone tapping")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

private func agentStatus(accessibility: Bool = true, locked: Bool = false) -> Data {
    json(["ok": true, "name": "macbook", "version": "0.2.3", "accessibility": accessibility, "screen_locked": locked,
          "secure_input": false, "min_client_version": "0.2.0"])
}
