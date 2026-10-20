import XCTest
@testable import DictationApp

@MainActor
final class DeliveryServiceTests: XCTestCase {
    private struct Rig {
        let service: DeliveryService
        let outbox: Outbox
        let store: TargetStore
    }

    private func makeService(targets: [MacTarget] = [MacTarget(name: "MacBook", address: "macbook.ts.net")]) throws -> Rig {
        let store = TargetStore(defaults: isolatedDefaults(), keys: MemoryKeyStore())
        for target in targets { try store.save(target, key: "key-\(target.name)") }
        let outbox = Outbox(url: nil)
        let client = ReceiverClient(session: StubURLProtocol.session(), tailnetConnected: { true })
        let service = DeliveryService(outbox: outbox, targets: store, client: client)
        return Rig(service: service, outbox: outbox, store: store)
    }

    func testDeliveryMarksTheItemSent() async throws {
        StubURLProtocol.install { _ in (200, json(["ok": true, "status": "inserted", "duplicate": false, "ms": 4])) }
        let rig = try makeService()
        let (service, outbox) = (rig.service, rig.outbox)
        let id = outbox.add(text: "Hello").id
        let outcome = await service.deliver(id)
        XCTAssertEqual(outcome, .delivered(duplicate: false, macMs: 4, delivery: nil))
        XCTAssertEqual(outbox.item(id)?.status, .sent)
        XCTAssertEqual(outbox.item(id)?.macMs, 4)
        XCTAssertEqual(outbox.item(id)?.targetName, "MacBook")
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "X-Dictation-Key"), "key-MacBook")
    }

    func testAFailureKeepsTheTextAndAResendReusesTheId() async throws {
        StubURLProtocol.install { _ in throw URLError(.notConnectedToInternet) }
        let rig = try makeService()
        let (service, outbox) = (rig.service, rig.outbox)
        let id = outbox.add(text: "Important words").id
        _ = await service.deliver(id)
        XCTAssertEqual(outbox.item(id)?.status, .pending)
        XCTAssertEqual(outbox.item(id)?.text, "Important words")
        XCTAssertNotNil(outbox.item(id)?.lastError)

        StubURLProtocol.install { _ in (200, json(["ok": true, "status": "inserted", "duplicate": false])) }
        _ = await service.deliver(id)
        XCTAssertEqual(outbox.item(id)?.status, .sent)
        XCTAssertEqual(outbox.item(id)?.attempts, 2)
        XCTAssertEqual(bodyJSON(StubURLProtocol.requests[0])["id"] as? String, id.uuidString, "the same id on resend")
    }

    func testARefusalIsExplainedAndKeepsTheText() async throws {
        StubURLProtocol.install { _ in (423, json(["ok": false, "error": "screen_locked"])) }
        let rig = try makeService()
        let (service, outbox) = (rig.service, rig.outbox)
        let id = outbox.add(text: "x").id
        _ = await service.deliver(id)
        XCTAssertEqual(outbox.item(id)?.status, .pending)
        XCTAssertEqual(outbox.item(id)?.lastError, ReceiverClient.Refusal.locked.message)
    }

    func testAComputerWithoutAKeyIsContactedWithoutTheHeader() async throws {
        StubURLProtocol.install { _ in (200, json(["ok": true, "status": "inserted", "duplicate": false])) }
        let rig = try makeService()
        let target = try XCTUnwrap(rig.store.selected)
        try rig.store.save(target, key: "")
        let id = rig.outbox.add(text: "x").id
        _ = await rig.service.deliver(id)
        XCTAssertEqual(rig.outbox.item(id)?.status, .sent, "tailnet identity is the credential; no key is needed")
        XCTAssertNil(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "X-Dictation-Key"))
    }

    func testADaemonThatAsksForAKeyIsExplainedNotHidden() async throws {
        StubURLProtocol.install { _ in (401, json(["ok": false, "error": "unauthorized"])) }
        let rig = try makeService()
        let target = try XCTUnwrap(rig.store.selected)
        try rig.store.save(target, key: "")
        let id = rig.outbox.add(text: "x").id
        _ = await rig.service.deliver(id)
        XCTAssertEqual(rig.outbox.item(id)?.status, .pending)
        XCTAssertTrue(rig.outbox.item(id)?.lastError?.contains("asks for a key") ?? false)
        XCTAssertTrue(rig.outbox.item(id)?.lastError?.contains("Advanced") ?? false)
    }

    func testNoMacSelectedKeepsTheTextWithoutSending() async throws {
        StubURLProtocol.install { _ in (200, json(["ok": true])) }
        let rig = try makeService(targets: [])
        let (service, outbox) = (rig.service, rig.outbox)
        let id = outbox.add(text: "x").id
        let outcome = await service.deliver(id)
        XCTAssertNil(outcome)
        XCTAssertEqual(outbox.item(id)?.status, .pending)
        XCTAssertTrue(outbox.item(id)?.lastError?.contains("No computer") ?? false)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testOnlyTheSelectedMacIsContacted() async throws {
        StubURLProtocol.install { _ in (200, json(["ok": true])) }
        let first = MacTarget(name: "MacBook", address: "macbook.ts.net")
        let second = MacTarget(name: "Mini", address: "mini.ts.net")
        let rig = try makeService(targets: [first, second])
        let (service, outbox, store) = (rig.service, rig.outbox, rig.store)
        store.select(second.id)
        _ = await service.deliver(outbox.add(text: "x").id)
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.host }, ["mini.ts.net"])
    }

    func testAFailingMacDoesNotFallBackToAnother() async throws {
        StubURLProtocol.install { _ in throw URLError(.cannotConnectToHost) }
        let first = MacTarget(name: "MacBook", address: "macbook.ts.net")
        let second = MacTarget(name: "Mini", address: "mini.ts.net")
        let rig = try makeService(targets: [first, second])
        let (service, outbox) = (rig.service, rig.outbox)
        _ = await service.deliver(outbox.add(text: "x").id)
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.host }, ["macbook.ts.net"])
    }

    func testASentItemIsNeverSentAgain() async throws {
        StubURLProtocol.install { _ in (200, json(["ok": true])) }
        let rig = try makeService()
        let (service, outbox) = (rig.service, rig.outbox)
        let id = outbox.add(text: "x").id
        _ = await service.deliver(id)
        let second = await service.deliver(id)
        XCTAssertNil(second)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testResendAllGoesOldestFirstAndStopsAtTheFirstFailure() async throws {
        let rig = try makeService()
        let (service, outbox) = (rig.service, rig.outbox)
        let older = outbox.add(text: "older").id
        let middle = outbox.add(text: "middle").id
        let newest = outbox.add(text: "newest").id
        let counter = Counter()
        StubURLProtocol.install { _ in
            counter.increment() == 2 ? (423, json(["ok": false, "error": "screen_locked"])) : (200, json(["ok": true]))
        }
        await service.resendAll()
        XCTAssertEqual(outbox.item(older)?.status, .sent)
        XCTAssertEqual(outbox.item(middle)?.status, .pending, "the second send was refused")
        XCTAssertEqual(outbox.item(newest)?.status, .pending, "nothing after the failure was tried")
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testHealthUsesTheSavedKey() async throws {
        StubURLProtocol.install { _ in (200, json(["ok": true, "name": "MacBook"])) }
        let rig = try makeService()
        let (service, store) = (rig.service, rig.store)
        let health = await service.health(of: try XCTUnwrap(store.selected))
        XCTAssertEqual(health, .ready(ReceiverClient.MacStatus(name: "MacBook")))
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "X-Dictation-Key"), "key-MacBook")
    }

    func testHealthDotStates() {
        XCTAssertEqual(TargetHealth.state(from: .wrongKey), .wrongKey)
        let plain = ReceiverClient.MacStatus(name: "x", version: "0.1.0")
        XCTAssertEqual(TargetHealth.state(from: .ready(plain)), .ready(plain))
        var locked = plain
        locked.locked = true
        if case .notice = TargetHealth.state(from: .ready(locked)) {} else { XCTFail("locked") }
        var unapproved = plain
        unapproved.accessibility = false
        if case .notice(let message) = TargetHealth.state(from: .ready(unapproved)) {
            XCTAssertTrue(message.contains("Accessibility"))
        } else { XCTFail("accessibility") }
        XCTAssertEqual(TargetHealth.state(from: .keyNotSetOnMac), .keyNotSetOnMac)
        if case .unreachable = TargetHealth.state(from: .unreachable("x")) {} else { XCTFail("unreachable") }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
