import XCTest
@testable import DictationApp

final class MacTargetTests: XCTestCase {
    func testABareHostGetsTheDefaultPort() {
        let name = "macbook.example.ts.net"
        XCTAssertEqual(MacTarget(name: "a", address: name).baseURL?.absoluteString, "http://\(name):47821")
        XCTAssertEqual(MacTarget(name: "a", address: "100.64.1.2").baseURL?.absoluteString, "http://100.64.1.2:47821")
    }

    func testAnExplicitPortIsKept() {
        XCTAssertEqual(MacTarget(name: "a", address: " mac.ts.net:9000 ").baseURL?.absoluteString, "http://mac.ts.net:9000")
    }

    func testMalformedAddressesAreRejected() {
        for bad in ["", " ", "a b", "http://mac", "mac/path", "mac:abc", "mac:0", "mac:70000", ":7788", "a:1:2"] {
            XCTAssertNil(MacTarget(name: "a", address: bad).baseURL, bad)
        }
    }

    func testValidityNeedsANameAndAnAddress() {
        XCTAssertTrue(MacTarget(name: "Mac", address: "mac.ts.net").isValid)
        XCTAssertFalse(MacTarget(name: " ", address: "mac.ts.net").isValid)
        XCTAssertFalse(MacTarget(name: "Mac", address: "").isValid)
    }
}

final class ReceiverClientTests: XCTestCase {
    private let base = URL(string: "http://mac.ts.net:7788")!
    private let id = UUID()

    private func client() -> ReceiverClient { ReceiverClient(session: StubURLProtocol.session(), tailnetConnected: { true }) }

    func testSendPostsTheContractRequest() async throws {
        StubURLProtocol.install { _ in (200, json(["ok": true, "status": "inserted", "duplicate": false, "ms": 7])) }
        let (outcome, _) = await client().send(id: id, text: "Hello, world.", to: base, key: "s3cret")
        XCTAssertEqual(outcome, .delivered(duplicate: false, macMs: 7))
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/text")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Dictation-Key"), "s3cret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(bodyJSON(request)["id"] as? String, id.uuidString)
        XCTAssertEqual(bodyJSON(request)["text"] as? String, "Hello, world.")
        XCTAssertEqual(bodyJSON(request)["source"] as? String, "greenfield")
        XCTAssertFalse(request.url?.absoluteString.contains("s3cret") ?? true, "the key never goes in the URL")
    }

    func testNoKeyHeaderWhenThereIsNoKey() async {
        StubURLProtocol.install { _ in (200, json(["ok": true])) }
        _ = await client().send(id: id, text: "x", to: base, key: nil)
        XCTAssertNil(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "X-Dictation-Key"))
    }

    func testEveryDocumentedRefusalIsRecognised() {
        let cases: [Int: (String, ReceiverClient.Refusal)] = [
            401: ("unauthorized", .badKey), 409: ("secure_input", .secureInput), 413: ("too_large", .tooLarge),
            400: ("bad_request", .invalidText), 423: ("screen_locked", .locked), 503: ("accessibility_not_granted", .needsAccessibility),
            500: ("insert_failed", .insertFailed)
        ]
        for (status, (error, refusal)) in cases {
            XCTAssertEqual(ReceiverClient.interpret(status: status, data: json(["ok": false, "error": error])), .refused(refusal))
            XCTAssertEqual(ReceiverClient.interpret(status: status, data: Data()), .refused(refusal), "by status alone: \(status)")
        }
    }

    func testADuplicateAnswerCountsAsDelivered() {
        let outcome = ReceiverClient.interpret(status: 200, data: json(["ok": true, "status": "inserted", "duplicate": true]))
        XCTAssertEqual(outcome, .delivered(duplicate: true, macMs: nil))
    }

    func testAnAnswerThatIsNotAReceiverIsNotDelivery() {
        if case .unreachable = ReceiverClient.interpret(status: 200, data: Data("<html>".utf8)) {} else { XCTFail("200 without ok") }
        if case .unreachable = ReceiverClient.interpret(status: 502, data: Data()) {} else { XCTFail("502") }
    }

    func testANetworkErrorIsUnreachableAndKeepsTheText() async {
        StubURLProtocol.install { _ in throw URLError(.timedOut) }
        let (outcome, _) = await client().send(id: id, text: "x", to: base, key: nil)
        guard case .unreachable(let message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.contains("did not answer"))
    }

    func testOversizedTextIsRefusedWithoutASend() async {
        StubURLProtocol.install { _ in (200, json(["ok": true])) }
        let (outcome, _) = await client().send(id: id, text: String(repeating: "a", count: 300_000), to: base, key: nil)
        XCTAssertEqual(outcome, .refused(.tooLarge))
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testHealthStates() {
        let ready = json(["ok": true, "service": "greenfield-inserter", "version": "0.1.0", "name": "MacBook", "screen_locked": false,
                          "secure_input": true, "accessibility": false, "inserted_count": 7])
        let status = ReceiverClient.MacStatus(name: "MacBook", version: "0.1.0", locked: false, secureInput: true, accessibility: false,
                                              insertedCount: 7)
        XCTAssertEqual(ReceiverClient.interpretHealth(status: 200, data: ready), .ready(status))
        XCTAssertEqual(ReceiverClient.interpretHealth(status: 401, data: Data()), .wrongKey)
        let noKey = json(["ok": false, "error": "key_not_configured"])
        XCTAssertEqual(ReceiverClient.interpretHealth(status: 503, data: noKey), .keyNotSetOnMac)
        if case .incompatible = ReceiverClient.interpretHealth(status: 200, data: json(["ok": true, "contract": "2.0"])) {} else {
            XCTFail("a newer stated major is refused")
        }
        if case .ready = ReceiverClient.interpretHealth(status: 200, data: json(["ok": true, "name": "x"])) {} else {
            XCTFail("an agent that states no contract is accepted")
        }
        if case .unreachable = ReceiverClient.interpretHealth(status: 404, data: Data()) {} else { XCTFail("404") }
    }

    func testHealthSendsTheKeyHeader() async {
        StubURLProtocol.install { _ in (200, json(["ok": true, "contract": "1.0"])) }
        _ = await client().health(of: base, key: "abc")
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.path, "/status")
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "X-Dictation-Key"), "abc")
    }
}

@MainActor
final class OutboxTests: XCTestCase {
    func testItemsSurviveARestart() {
        let url = temporaryFile()
        let first = Outbox(url: url)
        let item = first.add(text: "Hello", asrMs: 44)
        let second = Outbox(url: url)
        XCTAssertEqual(second.items.map(\.text), ["Hello"])
        XCTAssertEqual(second.items.first?.id, item.id)
        XCTAssertEqual(second.items.first?.asrMs, 44)
    }

    func testSendingAndFailingUpdateTheItem() {
        let outbox = Outbox(url: nil)
        let id = outbox.add(text: "x").id
        outbox.markAttempt(id, targetName: "MacBook")
        outbox.markFailed(id, reason: "The Mac is locked.")
        XCTAssertEqual(outbox.item(id)?.status, .pending)
        XCTAssertEqual(outbox.item(id)?.lastError, "The Mac is locked.")
        outbox.markSent(id, networkMs: 30, macMs: 5)
        XCTAssertEqual(outbox.item(id)?.status, .sent)
        XCTAssertNil(outbox.item(id)?.lastError)
        XCTAssertEqual(outbox.item(id)?.attempts, 1)
        XCTAssertEqual(outbox.item(id)?.targetName, "MacBook")
    }

    func testOnlySentItemsAreEverDropped() {
        let outbox = Outbox(url: nil)
        let unsent = outbox.add(text: "keep me").id
        for index in 0..<(Outbox.keepSent + 5) {
            let id = outbox.add(text: "sent \(index)").id
            outbox.markSent(id, networkMs: 1, macMs: nil)
        }
        XCTAssertEqual(outbox.items.filter { $0.status == .sent }.count, Outbox.keepSent)
        XCTAssertNotNil(outbox.item(unsent))
        outbox.clearSent()
        XCTAssertEqual(outbox.items.map(\.id), [unsent])
    }

    func testRemoveDeletesOneItem() {
        let outbox = Outbox(url: nil)
        let keep = outbox.add(text: "a").id
        let drop = outbox.add(text: "b").id
        outbox.remove(drop)
        XCTAssertEqual(outbox.items.map(\.id), [keep])
    }
}

@MainActor
final class TargetStoreTests: XCTestCase {
    func testSaveSelectAndRemove() throws {
        let keys = MemoryKeyStore()
        let defaults = isolatedDefaults()
        let store = TargetStore(defaults: defaults, keys: keys)
        let first = MacTarget(name: "MacBook", address: "macbook.ts.net")
        let second = MacTarget(name: "Mini", address: "mini.ts.net")
        try store.save(first, key: "k1")
        try store.save(second, key: "k2")
        XCTAssertEqual(store.selectedID, first.id, "the first Mac added is selected")
        store.select(second.id)
        XCTAssertEqual(store.key(for: second), "k2")

        let reloaded = TargetStore(defaults: defaults, keys: keys)
        XCTAssertEqual(reloaded.targets.map(\.name), ["MacBook", "Mini"])
        XCTAssertEqual(reloaded.selected?.id, second.id)

        reloaded.remove(second.id)
        XCTAssertNil(keys.key(for: second.id), "removing a Mac removes its key")
        XCTAssertEqual(reloaded.selected?.id, first.id)
    }

    func testKeysNeverReachPreferences() throws {
        let defaults = isolatedDefaults()
        let store = TargetStore(defaults: defaults, keys: MemoryKeyStore())
        try store.save(MacTarget(name: "Mac", address: "mac.ts.net"), key: "TOP-SECRET-KEY")
        let stored = defaults.dictionaryRepresentation().values.map { "\($0)" }.joined()
        XCTAssertFalse(stored.contains("TOP-SECRET-KEY"))
    }

    func testEditingWithoutAKeyKeepsTheSavedKey() throws {
        let store = TargetStore(defaults: isolatedDefaults(), keys: MemoryKeyStore())
        var target = MacTarget(name: "Mac", address: "mac.ts.net")
        try store.save(target, key: "kept")
        target.name = "Renamed"
        try store.save(target, key: nil)
        XCTAssertEqual(store.key(for: target), "kept")
        XCTAssertEqual(store.targets.first?.name, "Renamed")
    }

    func testKeychainRoundTrip() throws {
        let keychain = KeychainKeyStore(service: "dictation.tests.\(UUID().uuidString)")
        let id = UUID()
        do { try keychain.setKey("abc123", for: id) } catch let failure as KeychainKeyStore.Failure where failure.status == -34_018 {
            throw XCTSkip("the simulator test host has no keychain access; this runs on a device")
        }
        addTeardownBlock { try? keychain.setKey(nil, for: id) }
        XCTAssertEqual(keychain.key(for: id), "abc123")
        try keychain.setKey("def456", for: id)
        XCTAssertEqual(keychain.key(for: id), "def456")
        try keychain.setKey(nil, for: id)
        XCTAssertNil(keychain.key(for: id))
    }
}

@MainActor
final class PresetComputersTests: XCTestCase {
    func testPresetsAreAddedOnceWithoutKeys() {
        let keys = MemoryKeyStore()
        let defaults = isolatedDefaults()
        let store = TargetStore(defaults: defaults, keys: keys)
        store.seedPresets("alpha=alpha.example.ts.net beta=beta.example.ts.net")
        XCTAssertEqual(store.targets.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(store.selected?.name, "alpha")
        XCTAssertNil(store.key(for: store.targets[0]), "keys are entered by the person, never preset")
        store.remove(store.targets[1].id)

        let again = TargetStore(defaults: defaults, keys: keys)
        again.seedPresets("alpha=alpha.example.ts.net beta=beta.example.ts.net")
        XCTAssertEqual(again.targets.map(\.name), ["alpha"], "a removed preset stays removed")
    }

    func testEmptyOrMalformedPresetsAddNothing() {
        let store = TargetStore(defaults: isolatedDefaults(), keys: MemoryKeyStore())
        store.seedPresets(nil)
        store.seedPresets("")
        store.seedPresets("noequals")
        XCTAssertTrue(store.targets.isEmpty)
    }

    func testAComputerWithoutAKeyIsCheckedAndShownAsReady() async {
        let store = TargetStore(defaults: isolatedDefaults(), keys: MemoryKeyStore())
        store.seedPresets("alpha=alpha.example.ts.net")
        let client = ReceiverClient(session: StubURLProtocol.session(), tailnetConnected: { true })
        let health = TargetHealth(service: DeliveryService(outbox: Outbox(url: nil), targets: store, client: client))
        StubURLProtocol.install { _ in (200, json(["ok": true])) }
        await health.refreshAll()
        XCTAssertEqual(health.state(for: store.targets[0]), .ready(ReceiverClient.MacStatus()))
        XCTAssertNil(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "X-Dictation-Key"))
    }
}

@MainActor
final class PeerDirectoryTests: XCTestCase {
    private func directory() -> (PeerDirectory, TargetStore) {
        let store = TargetStore(defaults: isolatedDefaults(), keys: MemoryKeyStore())
        let client = ReceiverClient(session: StubURLProtocol.session(), tailnetConnected: { true })
        return (PeerDirectory(service: DeliveryService(outbox: Outbox(url: nil), targets: store, client: client)), store)
    }

    func testPeersAnswerIsParsedLeniently() {
        let first: [String: String] = ["name": "macbook", "address": "macbook.example.ts.net.", "version": "0.2.0", "auth": "tailnet"]
        let data = json(["ok": true, "peers": [first, ["name": "no-address"], ["address": "bare.example.ts.net"]]])
        let found = PeerDirectory.parsePeers(data)
        XCTAssertEqual(found.map(\.address), ["macbook.example.ts.net", "bare.example.ts.net"])
        XCTAssertEqual(found.first?.version, "0.2.0")
        XCTAssertEqual(found.last?.name, "bare.example.ts.net")
        XCTAssertTrue(PeerDirectory.parsePeers(Data("nope".utf8)).isEmpty)
    }

    func testOneSeedLeadsToEveryCompatibleComputer() async throws {
        let (directory, store) = directory()
        try store.save(MacTarget(name: "mini0", address: "mini0.example.ts.net"), key: nil)
        StubURLProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/peers")
            return (200, json(["ok": true, "peers": [["name": "mini0", "address": "mini0.example.ts.net"],
                                                     ["name": "macbook", "address": "macbook.example.ts.net"],
                                                     ["name": "studio", "address": "studio.example.ts.net"]]]))
        }
        await directory.refresh()
        XCTAssertEqual(directory.discovered.map(\.name), ["macbook", "studio"], "the seed itself is not offered again")
        directory.add(directory.discovered[0])
        XCTAssertEqual(store.targets.map(\.name), ["mini0", "macbook"])
        XCTAssertNil(store.key(for: store.targets[1]), "no key")
        XCTAssertEqual(directory.discovered.map(\.name), ["studio"])
    }

    func testAnAgentWithoutPeersJustOffersNothing() async throws {
        let (directory, store) = directory()
        try store.save(MacTarget(name: "mini0", address: "mini0.example.ts.net"), key: nil)
        StubURLProtocol.install { _ in (404, json(["ok": false])) }
        await directory.refresh()
        XCTAssertTrue(directory.discovered.isEmpty)
    }

    func testBonjourResultsAreOfferedAndNotDuplicated() {
        let (directory, store) = directory()
        directory.bonjourFound(["Studio Mac", "studio mac", "Laptop"])
        XCTAssertEqual(directory.discovered.map(\.address), ["studio-mac.local", "laptop.local"])
        try? store.save(MacTarget(name: "Laptop", address: "laptop.local"), key: nil)
        directory.bonjourFound(["Studio Mac", "Laptop"])
        XCTAssertEqual(directory.discovered.map(\.address), ["studio-mac.local"])
    }

    func testALinkAddsAComputerWithoutAKey() {
        let (directory, store) = directory()
        let added = directory.handle(link: URL(string: "greenfield://add?name=Desk&address=desk.example.ts.net")!)
        XCTAssertEqual(added?.name, "Desk")
        XCTAssertEqual(store.targets.map(\.address), ["desk.example.ts.net"])
        XCTAssertNil(directory.handle(link: URL(string: "greenfield://add?name=x")!))
        XCTAssertNil(directory.handle(link: URL(string: "https://example.com/add?address=a")!))
        XCTAssertNil(directory.handle(link: URL(string: "greenfield://add?address=bad%20name")!))
    }
}
