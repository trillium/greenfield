import XCTest
@testable import DictationApp

final class SoundRulesTests: XCTestCase {
    func testKittyCmereTwiceStartsDictation() {
        var engine = RuleEngine()
        XCTAssertNil(engine.hear("kitty-cmere", at: 1.0), "one is not enough")
        XCTAssertEqual(engine.state, .idle)
        let rule = engine.hear("kitty-cmere", at: 1.6)
        XCTAssertEqual(rule?.action, .startDictation)
        XCTAssertEqual(engine.state, .dictating)
    }

    func testTwoKittiesTooFarApartDoNotFire() {
        var engine = RuleEngine()
        XCTAssertNil(engine.hear("kitty-cmere", at: 1.0))
        XCTAssertNil(engine.hear("kitty-cmere", at: 3.0), "outside the 1.5 s window")
        XCTAssertEqual(engine.state, .idle)
        XCTAssertNotNil(engine.hear("kitty-cmere", at: 3.8), "but the 3.0 and 3.8 pair is inside it")
    }

    func testTheDefaultFlowEndToEnd() {
        var engine = RuleEngine()
        _ = engine.hear("kitty-cmere", at: 1.0)
        _ = engine.hear("kitty-cmere", at: 1.5)
        XCTAssertEqual(engine.state, .dictating)
        XCTAssertEqual(engine.hear("tongue-click", at: 5.0)?.action, .endDictation)
        XCTAssertEqual(engine.state, .review)
        XCTAssertEqual(engine.hear("tongue-click", at: 7.0)?.action, .submit)
        XCTAssertEqual(engine.state, .idle)
    }

    func testASoundThatNoRuleUsesInThisStateDoesNothing() {
        var engine = RuleEngine()
        XCTAssertNil(engine.hear("tongue-click", at: 1.0), "a click does nothing while idle")
        XCTAssertNil(engine.hear("hiss", at: 2.0))
        XCTAssertEqual(engine.state, .idle)
    }

    func testTheSameSoundIsIgnoredBrieflyAfterItFires() {
        var engine = RuleEngine(state: .dictating)
        XCTAssertEqual(engine.hear("tongue-click", at: 5.0)?.action, .endDictation)
        XCTAssertNil(engine.hear("tongue-click", at: 5.2), "a double report of one click must not also submit")
        XCTAssertEqual(engine.state, .review)
        XCTAssertEqual(engine.hear("tongue-click", at: 5.6)?.action, .submit)
    }

    func testDisabledRulesNeverFire() {
        var rules = SoundRule.defaults
        rules[1].enabled = false
        var engine = RuleEngine(rules: rules, state: .dictating)
        XCTAssertNil(engine.hear("tongue-click", at: 1.0))
        XCTAssertEqual(engine.state, .dictating)
    }

    func testRulesAreEditable() {
        let trigger = SoundTrigger(sound: "hiss", count: 3, withinSeconds: 2)
        let custom = SoundRule(trigger: trigger, from: .idle, to: .review, action: .clearText)
        var engine = RuleEngine(rules: [custom])
        XCTAssertNil(engine.hear("hiss", at: 0))
        XCTAssertNil(engine.hear("hiss", at: 1))
        XCTAssertEqual(engine.hear("hiss", at: 1.9)?.action, .clearText)
        XCTAssertEqual(engine.state, .review)
    }

    func testMovingTheStateByHandForgetsHalfCountedSounds() {
        var engine = RuleEngine()
        _ = engine.hear("kitty-cmere", at: 1.0)
        engine.setState(.idle)
        XCTAssertNil(engine.hear("kitty-cmere", at: 1.2), "the first kitty was forgotten")
    }

    func testRulesRoundTripThroughStorage() {
        let defaults = UserDefaults(suiteName: "rules.\(UUID().uuidString)")!
        let store = RuleStore(defaults: defaults)
        XCTAssertEqual(store.load(), SoundRule.defaults, "defaults until something is saved")
        var edited = SoundRule.defaults
        edited[0].trigger.count = 3
        store.save(edited)
        XCTAssertEqual(store.load(), edited)
    }
}

@MainActor
final class FlowControllerTests: XCTestCase {
    private func event(_ pattern: String, _ time: Double) -> SoundEvent {
        SoundEvent(time: time, pattern: pattern, topClass: "x", probability: 0.97, power: 20)
    }

    private func controller() -> FlowController {
        let store = TargetStore(defaults: isolatedDefaults(), keys: MemoryKeyStore())
        let client = ReceiverClient(session: StubURLProtocol.session(), tailnetConnected: { true })
        let delivery = DeliveryService(outbox: Outbox(url: nil), targets: store, client: client)
        return FlowController(session: DictationSession(transcriber: ParakeetTranscriber()), delivery: delivery,
                              models: ParrotModelStore(directory: temporaryFile(), bundled: { [] }),
                              ruleStore: RuleStore(defaults: isolatedDefaults()))
    }

    func testHeardSoundsAreShownEvenWhenNoRuleFires() {
        let flow = controller()
        flow.heard([event("hiss", 1)])
        XCTAssertEqual(flow.lastSound?.event.pattern, "hiss")
        XCTAssertNil(flow.lastSound?.firedRule)
        XCTAssertEqual(flow.recentSounds.count, 1)
    }

    func testTheRecentListIsBounded() {
        let flow = controller()
        for index in 0..<(FlowController.keepSounds + 20) { flow.heard([event("hiss", Double(index))]) }
        XCTAssertEqual(flow.recentSounds.count, FlowController.keepSounds)
    }

    func testAFiredRuleIsRecordedAndMovesTheState() {
        let flow = controller()
        flow.heard([event("kitty-cmere", 1.0), event("kitty-cmere", 1.4)])
        // The microphone is not running in a unit test, so dictation cannot start and the state falls back to idle.
        XCTAssertEqual(flow.recentSounds.first?.firedRule, "kitty-cmere × 2: Idle → Dictating")
        XCTAssertEqual(flow.state, .idle)
    }

    func testEditedRulesAreSaved() {
        let flow = controller()
        var rules = flow.rules
        rules[0].trigger.count = 3
        flow.setRules(rules)
        XCTAssertEqual(flow.rules[0].trigger.count, 3)
        flow.resetRules()
        XCTAssertEqual(flow.rules, SoundRule.defaults)
    }

    func testTheHintNamesTheNextSound() {
        let flow = controller()
        XCTAssertTrue(flow.hint.contains("kitty-cmere × 2"))
    }
}

private final class ScriptedTranscriber: SpeechTranscriber, @unchecked Sendable {
    func isDownloaded() -> Bool { true }
    func prepare(progress: @escaping @Sendable (SpeechModelProgress) -> Void) async throws {}
    func transcribe(_ samples: [Float]) async throws -> String { "Hello from the test." }
}

/// The whole flow with the real session, buffer, rules and delivery; only the microphone is replaced by publishing on its bus.
@MainActor
final class EndToEndFlowTests: XCTestCase {
    private func tone(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16_000)).map { 0.2 * sin(Float($0) * 0.1) } }

    private struct Rig {
        let flow: FlowController
        let session: DictationSession
        let outbox: Outbox
    }

    private func rig(withMac: Bool) async throws -> Rig {
        var machine = ListenMachine()
        _ = machine.handle(.started)
        let session = DictationSession(transcriber: ScriptedTranscriber(), listen: machine)
        await session.prepareModel()
        let store = TargetStore(defaults: isolatedDefaults(), keys: MemoryKeyStore())
        if withMac { try store.save(MacTarget(name: "MacBook", address: "macbook.ts.net"), key: "k") }
        let outbox = Outbox(url: nil)
        let client = ReceiverClient(session: StubURLProtocol.session(), tailnetConnected: { true })
        let delivery = DeliveryService(outbox: outbox, targets: store, client: client)
        let models = ParrotModelStore(directory: temporaryFile(), bundled: { [] })
        let flow = FlowController(session: session, delivery: delivery, models: models, ruleStore: RuleStore(defaults: isolatedDefaults()))
        session.attach()
        return Rig(flow: flow, session: session, outbox: outbox)
    }

    private func event(_ pattern: String, _ time: Double) -> SoundEvent {
        SoundEvent(time: time, pattern: pattern, topClass: "x", probability: 0.99, power: 30)
    }

    func testKittyTwiceThenClickThenClickDictatesAndSubmits() async throws {
        StubURLProtocol.install { _ in (200, json(["ok": true, "status": "inserted", "duplicate": false])) }
        let rig = try await rig(withMac: true)
        let (flow, session, outbox) = (rig.flow, rig.session, rig.outbox)
        let bus = session.capture.bus
        bus.publish(tone(1))
        flow.heard([event("kitty-cmere", 1.0), event("kitty-cmere", 1.3)])
        XCTAssertEqual(flow.state, .dictating)
        XCTAssertTrue(session.isHolding)

        bus.publish(tone(2))
        flow.heard([event("tongue-click", 3.5)])
        XCTAssertEqual(flow.state, .review)
        XCTAssertFalse(session.isHolding)
        for _ in 0..<100 where flow.text.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(flow.text, "Hello from the test.")

        flow.heard([event("tongue-click", 5.0)])
        XCTAssertEqual(flow.state, .idle)
        XCTAssertEqual(flow.text, "", "submitted text leaves the box")
        XCTAssertEqual(outbox.items.first?.text, "Hello from the test.")
        for _ in 0..<100 where outbox.items.first?.status != .sent { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(outbox.items.first?.status, .sent)
    }

    func testWithoutAMacTheSubmitQueuesInTheOutbox() async throws {
        let rig = try await rig(withMac: false)
        let (flow, session, outbox) = (rig.flow, rig.session, rig.outbox)
        session.capture.bus.publish(tone(1))
        flow.heard([event("kitty-cmere", 1.0), event("kitty-cmere", 1.3)])
        session.capture.bus.publish(tone(1))
        flow.heard([event("tongue-click", 3.5)])
        for _ in 0..<100 where flow.text.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        flow.heard([event("tongue-click", 5.0)])
        for _ in 0..<100 where outbox.items.first?.lastError == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(outbox.items.first?.status, .pending)
        XCTAssertTrue(outbox.items.first?.lastError?.contains("No Mac") ?? false)
    }

    func testHoldButtonDrivesTheSameState() async throws {
        let rig = try await rig(withMac: false)
        let (flow, session) = (rig.flow, rig.session)
        session.capture.bus.publish(tone(1))
        session.beginHold()
        XCTAssertEqual(flow.state, .dictating)
        session.capture.bus.publish(tone(1))
        session.endHold()
        XCTAssertEqual(flow.state, .review)
        session.capture.bus.publish(tone(0.3))
        for _ in 0..<100 where flow.text.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(flow.text, "Hello from the test.")
    }
}
