import XCTest
import KitAssist
@testable import InserterCore

final class AssistWindowsTests: XCTestCase {
    var settings = MutableSettings(AssistSettings(enabled: true))
    var probe = StubProbe()
    var provider = FakeWindowProvider()
    var logger = SpyLogger()
    var clock = ManualClock()
    var service: WindowService!
    var handler: RequestHandler!

    override func setUp() {
        settings = MutableSettings(AssistSettings(enabled: true))
        probe = StubProbe(); provider = FakeWindowProvider(); logger = SpyLogger(); clock = ManualClock()
        build()
    }

    func build(limits: WindowLimits = WindowLimits()) {
        service = WindowService(provider: provider, probe: probe, settings: settings, computerName: { "Studio Mac" }, limits: limits, epoch: "e-test01",
                                clock: { [clock] in clock.now }, sleeper: { [clock] in clock.advance($0) })
        let assist = AssistEndpoints(settings: settings, windows: service, pointer: nil, logger: logger, clock: { [clock] in clock.now })
        handler = RequestHandler(keys: StubKeys(), probe: probe, inserter: SpyInserter(), name: { "Studio Mac" }, identity: FakeIdentity(),
                                 assist: assist, version: "0.4.0", minClientVersion: "0.2.0", logger: logger)
    }

    func get(_ query: String = "", peer: String = "100.64.0.20", headers: [String: String] = [:], path: String = "/assist/windows") -> HTTPResponse {
        handler.handle(HTTPRequest(method: "GET", path: path, headers: headers, peerAddress: peer, query: query))
    }

    func post(_ body: Data, path: String = "/assist/windows/focus", peer: String = "100.64.0.20", headers: [String: String] = [:]) -> HTTPResponse {
        handler.handle(HTTPRequest(method: "POST", path: path, headers: headers, body: body, peerAddress: peer))
    }

    func focus(_ json: String) -> HTTPResponse { post(Data(json.utf8)) }

    func fixtureListing(_ name: String = "snapshot.json") throws -> (WindowsSnapshot, WindowListing) {
        let snapshot = try JSONDecoder().decode(WindowsSnapshot.self, from: KitFixtures.data("windows/" + name))
        return (snapshot, WindowListing(apps: snapshot.apps, frontmost: snapshot.frontmost))
    }

    func snapshot(_ response: HTTPResponse) throws -> WindowsSnapshot {
        XCTAssertEqual(response.status, 200, String(data: response.body, encoding: .utf8) ?? "")
        guard case let .snapshot(s) = try decode(WindowsResponse.self, response) else { XCTFail("not a snapshot"); throw CancellationError() }
        return s
    }

    // MARK: Who may call, and when it is off

    func testEverythingIsOffByDefault() {
        settings.settings = .off
        XCTAssertEqual(get().status, 404)
        XCTAssertEqual(focus(#"{"format":1,"action":"previous","rev":1}"#).status, 404)
        XCTAssertEqual(jsonObject(get())["error"] as? String, "assist_off")
        XCTAssertEqual(provider.reads, 0, "nothing is read from the Mac while assist is off")
        let status = jsonObject(handler.handle(HTTPRequest(method: "GET", path: "/status", peerAddress: "100.64.0.20")))["assist"] as? [String: Any]
        XCTAssertEqual(status?["enabled"] as? Bool, false)
        XCTAssertEqual(status?["windows"] as? Bool, false)
        XCTAssertEqual(status?["pointer"] as? Bool, false)
    }

    func testStatusAdvertisesWhatIsOn() {
        func assist() -> [String: Any] {
            (jsonObject(handler.handle(HTTPRequest(method: "GET", path: "/status", peerAddress: "100.64.0.20")))["assist"] as? [String: Any]) ?? [:]
        }
        XCTAssertEqual(assist()["enabled"] as? Bool, true)
        XCTAssertEqual(assist()["windows"] as? Bool, true)
        XCTAssertEqual(assist()["pointer"] as? Bool, false, "no pointer service here, and its own switch is off")
        XCTAssertEqual(assist()["capabilities"] as? [String], ["windowTitles"])
        settings.settings.windows = false
        XCTAssertEqual(assist()["windows"] as? Bool, false)
        XCTAssertEqual(assist()["enabled"] as? Bool, true, "enabled is the master switch")
    }

    func testAKeyAloneNeverOpensTheAssistRoutes() {
        let key = ["X-Dictation-Key": "good"]
        for (method, path) in [("GET", "/assist/windows"), ("POST", "/assist/windows/focus"), ("POST", "/assist/pointer/session")] {
            let other = handler.handle(HTTPRequest(method: method, path: path, headers: key, body: Data("{}".utf8), peerAddress: "100.64.0.99"))
            XCTAssertEqual(other.status, 403, path)
            XCTAssertEqual(jsonObject(other)["error"] as? String, "assist_need_same_user")
            let nobody = handler.handle(HTTPRequest(method: method, path: path, body: Data("{}".utf8), peerAddress: "100.64.0.99"))
            XCTAssertEqual(nobody.status, 401, "another tailnet user without a key: unauthorized")
            let unknown = handler.handle(HTTPRequest(method: method, path: path, body: Data("{}".utf8), peerAddress: "100.64.0.5"))
            XCTAssertEqual(unknown.status, 503, "if Tailscale cannot say who is calling the request is refused")
        }
        XCTAssertEqual(provider.reads, 0)
    }

    func testThisMacItselfMayAsk() {
        let r = handler.handle(HTTPRequest(method: "GET", path: "/assist/windows", fromLoopback: true))
        XCTAssertEqual(r.status, 200)
    }

    func testTheAppVersionRuleAppliesAndMethodsAreChecked() {
        XCTAssertEqual(get(headers: ["X-Greenfield-App": "0.1.0"]).status, 426)
        XCTAssertEqual(get(headers: ["X-Greenfield-App": "0.4.1"]).status, 200)
        let wrong = handler.handle(HTTPRequest(method: "POST", path: "/assist/windows", body: Data(), peerAddress: "100.64.0.20"))
        XCTAssertEqual(wrong.status, 405)
        XCTAssertEqual(wrong.headers["Allow"], "GET")
        let wrong2 = handler.handle(HTTPRequest(method: "GET", path: "/assist/windows/focus", peerAddress: "100.64.0.20"))
        XCTAssertEqual(wrong2.status, 405)
    }

    // MARK: The list, against the kit's recorded answers

    func testTheListIsWhatTheKitRecorded() throws {
        for name in ["snapshot.json", "snapshot_empty.json", "snapshot_future.json"] {
            let (recorded, input) = try fixtureListing(name)
            provider.value = input
            build()
            let answer = try snapshot(get())
            XCTAssertEqual(answer.apps, recorded.apps, name)
            XCTAssertEqual(answer.frontmost, recorded.frontmost, name)
            XCTAssertEqual(answer.epoch, "e-test01")
            XCTAssertEqual(answer.computer, "Studio Mac")
            XCTAssertFalse(answer.locked)
            let raw = jsonObject(get())
            XCTAssertEqual(raw["format"] as? Int, 1)
        }
    }

    func testTheAnswerHasTheFieldsOfTheRecordedOne() throws {
        let (_, input) = try fixtureListing()
        provider.value = input
        let mine = jsonObject(get())
        let theirs = try KitFixtures.object("windows/snapshot.json")
        XCTAssertEqual(Set(mine.keys), Set(theirs.keys))
        let myApp = try XCTUnwrap((mine["apps"] as? [[String: Any]])?.first), theirApp = try XCTUnwrap((theirs["apps"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(myApp.keys).subtracting(["windows"]).isSubset(of: Set(theirApp.keys)), true)
        let myWindow = try XCTUnwrap((myApp["windows"] as? [[String: Any]])?.first), theirWindow = try XCTUnwrap((theirApp["windows"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(myWindow.keys), Set(theirWindow.keys))
    }

    func testMostRecentlyUsedFirst() throws {
        provider.value = listing([app("a", "A", windows: [window("w-1")]), app("b", "B", windows: [window("w-2")]), app("c", "C", windows: [window("w-3")])],
                                 front: KitAssist.WindowRef(appId: "b", windowId: "w-2"))
        XCTAssertEqual(try snapshot(get()).apps.map(\.appId), ["b", "a", "c"])
        clock.advance(1)
        provider.value.frontmost = KitAssist.WindowRef(appId: "c", windowId: "w-3")
        XCTAssertEqual(try snapshot(get()).apps.map(\.appId), ["c", "b", "a"])
        clock.advance(1)
        provider.value.frontmost = KitAssist.WindowRef(appId: "a", windowId: "w-1")
        XCTAssertEqual(try snapshot(get()).apps.map(\.appId), ["a", "c", "b"])
        clock.advance(1)
        provider.value.apps.removeAll { $0.appId == "c" }
        provider.value.apps.append(app("d", "D"))
        XCTAssertEqual(try snapshot(get()).apps.map(\.appId), ["a", "b", "d"], "an app that quit leaves, a new one joins at the end")
    }

    func testRevisionCountsOnlyRealChanges() throws {
        provider.value = listing([app("a", "A", windows: [window("w-1", "one")])], front: KitAssist.WindowRef(appId: "a", windowId: "w-1"))
        let first = try snapshot(get())
        clock.advance(1)
        XCTAssertEqual(try snapshot(get()).rev, first.rev, "nothing changed")
        provider.value.apps[0].windows[0].title = "two"
        clock.advance(1)
        XCTAssertEqual(try snapshot(get()).rev, first.rev + 1)
    }

    func testUnchangedWhenThePhoneAlreadyHasIt() throws {
        provider.value = listing([app("a", "A")])
        let first = try snapshot(get())
        let again = get("since=\(first.rev)&epoch=\(first.epoch)")
        XCTAssertEqual(again.status, 200)
        XCTAssertEqual(jsonObject(again).keys.sorted(), try KitFixtures.object("windows/unchanged.json").keys.sorted())
        XCTAssertEqual(try decode(WindowsResponse.self, again), .unchanged(epoch: first.epoch, rev: first.rev))
        let otherEpoch = try snapshot(get("since=\(first.rev)&epoch=e-someone-else"))
        XCTAssertEqual(otherEpoch.epoch, "e-test01", "a different epoch gets the full list")
        let older = try snapshot(get("since=\(first.rev - 1)&epoch=\(first.epoch)"))
        XCTAssertEqual(older.rev, first.rev)
    }

    func testBadQueriesAreRefused() {
        XCTAssertEqual(get("since=3").status, 400, "since needs its epoch")
        XCTAssertEqual(get("epoch=e-1").status, 400)
        XCTAssertEqual(get("since=abc&epoch=e-1").status, 400)
        XCTAssertEqual(get("since=-1&epoch=e-1").status, 400)
        XCTAssertEqual(get("since=1&epoch=" + String(repeating: "x", count: 65)).status, 400)
        XCTAssertEqual(get("future=1").status, 200, "a parameter added later is ignored, not refused")
    }

    func testLockedScreenListsNamesOnly() throws {
        let (_, input) = try fixtureListing()
        provider.value = input
        probe.screenLocked = true
        let answer = try snapshot(get())
        XCTAssertTrue(answer.locked)
        XCTAssertNil(answer.frontmost)
        XCTAssertEqual(answer.apps.map(\.appId), input.apps.map(\.appId), "every app is still listed by name, so it can be recognised")
        XCTAssertTrue(answer.apps.allSatisfy { $0.windows.isEmpty })
        XCTAssertFalse(String(data: get().body, encoding: .utf8)!.contains("\"title\""), "no title leaves a locked Mac")
        let recorded = try fixtureListing("snapshot_locked.json").0
        XCTAssertTrue(recorded.locked && recorded.apps.allSatisfy { $0.windows.isEmpty }, "the same shape the kit recorded")
    }

    func testSecureInputPausesTheList() {
        provider.value = listing([app("a", "A", windows: [window("w-1", "Secret plans")])])
        probe.secureInputEnabled = true
        let r = get()
        XCTAssertEqual(r.status, 409)
        XCTAssertEqual(jsonObject(r)["error"] as? String, "secure_input")
        XCTAssertFalse(String(data: r.body, encoding: .utf8)!.contains("Secret"))
    }

    func testTitlesCanStayOnTheMac() throws {
        provider.value = listing([app("a", "A", windows: [window("w-1", "Quarterly numbers")])])
        settings.settings.titles = false
        let answer = try snapshot(get())
        XCTAssertEqual(answer.apps.first?.windows.map(\.title), [""])
        XCTAssertEqual(answer.apps.first?.windows.map(\.windowId), ["w-1"], "the window is still listed and can be switched to")
        XCTAssertEqual((jsonObject(handler.handle(HTTPRequest(method: "GET", path: "/status", peerAddress: "100.64.0.20")))["assist"] as? [String: Any])?["capabilities"] as? [String], [])
    }

    func testHostileTitlesPassThroughBounded() throws {
        let (recorded, input) = try fixtureListing("snapshot_hostile.json")
        provider.value = input
        let answer = try snapshot(get())
        XCTAssertEqual(answer.apps.count, recorded.apps.count)
        let limits = WindowLimits()
        for appInfo in answer.apps {
            XCTAssertLessThanOrEqual(appInfo.name.count, limits.maxNameCharacters)
            for w in appInfo.windows { XCTAssertLessThanOrEqual(w.title.count, limits.maxTitleCharacters) }
        }
        let theirs = recorded.apps.flatMap(\.windows)
        let mine = answer.apps.flatMap(\.windows)
        XCTAssertEqual(mine.map(\.windowId), theirs.map(\.windowId))
        // markup, control characters and direction overrides are passed on as text for the phone to clean; they are never interpreted here
        XCTAssertEqual(mine.filter { $0.title.contains("\n") }.count, theirs.filter { $0.title.contains("\n") }.count)
    }

    func testSizesAreBounded() throws {
        let many = (0..<400).map { i in app("app.\(i)", "App \(i)", windows: (0..<40).map { window("w-\(i)-\($0)", String(repeating: "T", count: 2000)) }) }
        provider.value = listing(many)
        let r = get()
        let answer = try snapshot(r)
        let limits = WindowLimits()
        XCTAssertLessThanOrEqual(answer.apps.count, limits.maxApps)
        XCTAssertLessThanOrEqual(answer.apps.reduce(0) { $0 + $1.windows.count }, limits.maxWindows)
        XCTAssertTrue(answer.apps.allSatisfy { $0.windows.count <= limits.maxWindowsPerApp })
        XCTAssertLessThan(r.body.count, 300_000)
    }

    func testTheListIsReadOnceForAPollingPhone() throws {
        provider.value = listing([app("a", "A")])
        _ = get(); _ = get(); _ = get()
        XCTAssertEqual(provider.reads, 1)
        clock.advance(1)
        _ = get()
        XCTAssertEqual(provider.reads, 2)
    }

    func testListRateLimit() {
        provider.value = listing([app("a", "A")])
        var last = HTTPResponse(status: 0)
        for _ in 0..<21 { last = get() }
        XCTAssertEqual(last.status, 429)
        XCTAssertNotNil(last.headers["Retry-After"])
        clock.advance(1)
        XCTAssertEqual(get().status, 200)
    }

    // MARK: Focus

    func testTheKitsRequestsAreAccepted() throws {
        let (_, input) = try fixtureListing()
        for name in try KitFixtures.names(in: "windows", prefix: "focus_request_") {
            provider.value = input
            build()
            let r = post(try KitFixtures.data("windows/" + name))
            XCTAssertEqual(r.status, 200, name)
            let answer = try decode(FocusResponse.self, r)
            XCTAssertFalse(answer.result == .unknown("x"))
            XCTAssertTrue([FocusResult.ok, .notFound].contains(answer.result), "\(name): \(answer)")
        }
    }

    func testTheKitsInvalidRequestsAreRefused() throws {
        for name in try KitFixtures.names(in: "windows/invalid", prefix: "focus_request_") {
            let r = post(try KitFixtures.data("windows/invalid/" + name))
            XCTAssertEqual(r.status, 400, name)
        }
        XCTAssertEqual(provider.requested, [])
    }

    func testMoreRefusals() {
        XCTAssertEqual(post(Data()).status, 400)
        XCTAssertEqual(post(Data("[]".utf8)).status, 400)
        XCTAssertEqual(post(Data(#"{"format":1,"action":"app","appId":"\#(String(repeating: "a", count: 300))","rev":1}"#.utf8)).status, 400)
        XCTAssertEqual(focus(#"{"format":1,"action":"previous","rev":-1}"#).status, 400)
        XCTAssertEqual(post(Data(repeating: 0x20, count: 1025)).status, 413)
        XCTAssertEqual(post(Data(#"{"format":1,"action":"previous","rev":1,"extra":"\#(String(repeating: "x", count: 1100))"}"#.utf8)).status, 413)
    }

    func setUpTerminal() throws {
        let (_, input) = try fixtureListing()
        provider.value = input
        build()
    }

    func testFocusAWindow() throws {
        try setUpTerminal()
        let r = focus(#"{"format":1,"action":"window","appId":"com.apple.Terminal","windowId":"w-5202","rev":42}"#)
        let answer = try decode(FocusResponse.self, r)
        XCTAssertEqual(answer.result, .ok)
        XCTAssertEqual(answer.frontmost, KitAssist.WindowRef(appId: "com.apple.Terminal", windowId: "w-5202"))
        XCTAssertEqual(provider.requested, [KitAssist.WindowRef(appId: "com.apple.Terminal", windowId: "w-5202")])
        let recorded = try decode(FocusResponse.self, HTTPResponse(status: 200, body: KitFixtures.data("windows/focus_response_ok.json")))
        XCTAssertEqual(Set(jsonObject(r).keys), Set(try KitFixtures.object("windows/focus_response_ok.json").keys))
        XCTAssertEqual(answer.result, recorded.result)
    }

    func testFocusAnApp() throws {
        try setUpTerminal()
        let answer = try decode(FocusResponse.self, focus(#"{"format":1,"action":"app","appId":"com.apple.mail","rev":42}"#))
        XCTAssertEqual(answer.result, .ok)
        XCTAssertEqual(answer.frontmost?.appId, "com.apple.mail")
    }

    func testGoneIsGoneAndNeverSomethingSimilar() throws {
        try setUpTerminal()
        for body in [#"{"format":1,"action":"window","appId":"com.apple.Terminal","windowId":"w-9999","rev":42}"#,
                     #"{"format":1,"action":"window","appId":"com.apple.mail","windowId":"w-5202","rev":42}"#,
                     #"{"format":1,"action":"app","appId":"com.example.nothing","rev":42}"#] {
            let r = focus(body)
            XCTAssertEqual(try decode(FocusResponse.self, r).result, .notFound, body)
            XCTAssertEqual(jsonObject(r)["result"] as? String, "notFound")
        }
        XCTAssertEqual(provider.requested, [], "nothing was asked of the system")
    }

    func testStaleRevisionStillFindsByIdentity() throws {
        try setUpTerminal()
        XCTAssertEqual(try decode(FocusResponse.self, focus(#"{"format":1,"action":"app","appId":"com.apple.mail","rev":1}"#)).result, .ok)
    }

    func testNeverOkBecauseTheRequestArrived() throws {
        try setUpTerminal()
        provider.obeys = false
        let r = try decode(FocusResponse.self, focus(#"{"format":1,"action":"app","appId":"com.apple.mail","rev":42}"#))
        XCTAssertEqual(r.result, .declined)
        XCTAssertEqual(r.reason, "The system did not bring Mail forward.")
        XCTAssertEqual(r.frontmost?.appId, "com.apple.Safari", "the answer says what is really in front")
        XCTAssertGreaterThanOrEqual(provider.reads, 3, "it looked more than once")
    }

    func testWaitsOnlyABoundedTime() throws {
        try setUpTerminal()
        provider.obeys = false
        let before = clock.now
        _ = focus(#"{"format":1,"action":"app","appId":"com.apple.mail","rev":42}"#)
        XCTAssertLessThanOrEqual(clock.now - before, WindowLimits().settleSeconds + WindowLimits().settleStepSeconds + 0.001)
    }

    func testPendingWhenTheFrontMovedButNotToTheTarget() throws {
        try setUpTerminal()
        provider.obeys = false
        var reads = 0
        provider.onRead = { [provider] in
            reads += 1
            if reads >= 2 { provider.value.frontmost = KitAssist.WindowRef(appId: "com.apple.finder", windowId: "w-7001") }
        }
        XCTAssertEqual(try decode(FocusResponse.self, focus(#"{"format":1,"action":"app","appId":"com.apple.mail","rev":42}"#)).result, .pending)
    }

    func testTheSystemRefusingAndAWindowOnAnotherDesktop() throws {
        try setUpTerminal()
        provider.activation = .refused("The app did not accept.")
        var answer = try decode(FocusResponse.self, focus(#"{"format":1,"action":"app","appId":"com.apple.mail","rev":42}"#))
        XCTAssertEqual(answer.result, .declined)
        XCTAssertEqual(answer.reason, "The app did not accept.")
        provider.activation = .unsupported("Windows on other desktops cannot be reached.")
        clock.advance(1)
        answer = try decode(FocusResponse.self, focus(#"{"format":1,"action":"app","appId":"com.apple.mail","rev":42}"#))
        XCTAssertEqual(answer.result, .unsupported)
    }

    func testLockedAndSecureInputRefuseToFocus() throws {
        try setUpTerminal()
        probe.screenLocked = true
        var r = focus(#"{"format":1,"action":"app","appId":"com.apple.mail","rev":42}"#)
        XCTAssertEqual(try decode(FocusResponse.self, r).result, .locked)
        probe.screenLocked = false; probe.secureInputEnabled = true
        r = focus(#"{"format":1,"action":"app","appId":"com.apple.mail","rev":42}"#)
        XCTAssertEqual(try decode(FocusResponse.self, r).result, .denied)
        XCTAssertEqual(provider.requested, [], "nothing was switched")
    }

    func testFocusCanBeSwitchedOffWhileTheListStays() throws {
        try setUpTerminal()
        settings.settings.focus = false
        let r = focus(#"{"format":1,"action":"app","appId":"com.apple.mail","rev":42}"#)
        XCTAssertEqual(try decode(FocusResponse.self, r).result, .denied)
        XCTAssertEqual(get().status, 200)
        XCTAssertEqual(provider.requested, [])
    }

    func testPreviousIsResolvedOnTheMacsOwnOrder() throws {
        provider.value = listing([app("a", "A", windows: [window("w-1")]), app("b", "B", windows: [window("w-2")])], front: KitAssist.WindowRef(appId: "a", windowId: "w-1"))
        _ = get()
        clock.advance(1)
        provider.value.frontmost = KitAssist.WindowRef(appId: "b", windowId: "w-2")
        _ = get()
        clock.advance(1)
        let answer = try decode(FocusResponse.self, focus(#"{"format":1,"action":"previous","rev":0}"#))
        XCTAssertEqual(answer.result, .ok)
        XCTAssertEqual(answer.frontmost, KitAssist.WindowRef(appId: "a", windowId: "w-1"))
        clock.advance(1)
        let back = try decode(FocusResponse.self, focus(#"{"format":1,"action":"previous","rev":0}"#))
        XCTAssertEqual(back.frontmost, KitAssist.WindowRef(appId: "b", windowId: "w-2"), "previous toggles")
    }

    func testPreviousWithNothingToGoBackTo() throws {
        provider.value = listing([app("a", "A", windows: [window("w-1")])], front: KitAssist.WindowRef(appId: "a", windowId: "w-1"))
        XCTAssertEqual(try decode(FocusResponse.self, focus(#"{"format":1,"action":"previous","rev":0}"#)).result, .notFound)
    }

    func testOnlyOneActivationAtATime() throws {
        try setUpTerminal()
        provider.obeys = false
        var nested: HTTPResponse?
        let original = service!
        _ = original
        // while the first request waits for the system, a second one arrives
        let slow = WindowService(provider: provider, probe: probe, settings: settings, computerName: { "Studio Mac" }, epoch: "e-test01",
                                 clock: { [clock] in clock.now }, sleeper: { [weak self] seconds in
                                     guard let self = self else { return }
                                     self.clock.advance(seconds)
                                     if nested == nil { nested = self.focus(#"{"format":1,"action":"app","appId":"com.apple.finder","rev":42}"#) }
                                 })
        let assist = AssistEndpoints(settings: settings, windows: slow, pointer: nil, logger: logger, clock: { [clock] in clock.now })
        handler = RequestHandler(keys: StubKeys(), probe: probe, inserter: SpyInserter(), name: { "Studio Mac" }, identity: FakeIdentity(), assist: assist,
                                 version: "0.4.0", minClientVersion: "0.2.0", logger: logger)
        _ = focus(#"{"format":1,"action":"app","appId":"com.apple.mail","rev":42}"#)
        XCTAssertEqual(nested?.status, 429)
        XCTAssertEqual(provider.requested.map(\.appId), ["com.apple.mail"], "the second request never reached the system")
    }

    func testFocusRateLimit() throws {
        try setUpTerminal()
        var statuses: [Int] = []
        for _ in 0..<21 { statuses.append(focus(#"{"format":1,"action":"app","appId":"com.apple.mail","rev":42}"#).status) }
        XCTAssertEqual(statuses.prefix(20).filter { $0 == 200 }.count, 20)
        XCTAssertEqual(statuses.last, 429)
        clock.advance(1)
        XCTAssertEqual(focus(#"{"format":1,"action":"app","appId":"com.apple.mail","rev":42}"#).status, 200)
    }

    func testEveryResultTheKitRecordsCanBeProduced() throws {
        try setUpTerminal()
        var produced = Set<String>()
        let app = #"{"format":1,"action":"app","appId":"com.apple.mail","rev":42}"#
        func attempt(_ body: String = app, setUp: () -> Void = {}) {
            provider.value.frontmost = KitAssist.WindowRef(appId: "com.apple.Safari", windowId: "w-3101")
            provider.onRead = nil; provider.obeys = true; provider.activation = .asked
            probe.screenLocked = false; settings.settings.focus = true
            clock.advance(1)
            setUp()
            produced.insert(jsonObject(focus(body))["result"] as? String ?? "?")
        }
        attempt()
        attempt { provider.obeys = false }
        attempt {
            var reads = 0
            provider.obeys = false
            provider.onRead = { [provider] in
                reads += 1
                if reads >= 2 { provider.value.frontmost = KitAssist.WindowRef(appId: "com.apple.finder") }
            }
        }
        attempt(#"{"format":1,"action":"app","appId":"gone","rev":42}"#)
        attempt { settings.settings.focus = false }
        attempt { probe.screenLocked = true }
        attempt { provider.activation = .unsupported("x") }
        let recorded = Set(try KitFixtures.names(in: "windows", prefix: "focus_response_").compactMap { name -> String? in
            let value = try KitFixtures.object("windows/" + name)["result"] as? String
            return value == "rateLimited" ? nil : value
        })
        XCTAssertEqual(produced, recorded, "one answer per result in the kit's fixtures")
    }

    // MARK: Privacy

    func testNoLogLineCarriesATitleOrAName() throws {
        let titles = ["Quarterly salaries.xlsx", "Dear diary", "bank-login"]
        provider.value = listing([app("com.example.private", "Secret App Name", windows: titles.enumerated().map { window("w-\($0.offset)", $0.element) })],
                                 front: KitAssist.WindowRef(appId: "com.example.private", windowId: "w-0"))
        _ = get(); clock.advance(1)
        _ = focus(#"{"format":1,"action":"window","appId":"com.example.private","windowId":"w-1","rev":1}"#)
        _ = focus(#"{"format":1,"action":"window","appId":"com.example.private","windowId":"w-404","rev":1}"#)
        _ = focus("not json")
        probe.screenLocked = true; _ = get(); _ = focus(#"{"format":1,"action":"previous","rev":1}"#)
        probe.screenLocked = false; probe.secureInputEnabled = true; _ = get()
        XCTAssertFalse(logger.lines.isEmpty)
        for line in logger.lines {
            for secret in titles + ["Secret App Name", "com.example.private"] { XCTAssertFalse(line.contains(secret), line) }
        }
        XCTAssertTrue(logger.lines.contains { $0.hasPrefix("assist windows list apps=1 windows=3") }, "counts are logged")
        XCTAssertTrue(logger.lines.contains { $0.hasPrefix("assist windows focus action=window result=ok") })
    }

    func testTheLogEndpointMasksATitleThatEverReachedTheLog() {
        let query = try! LogQuery.parse(query: "tail=5").get()
        func page(_ line: String) -> String { LogPage.build(lines: [line], query: query).lines.first ?? "" }
        XCTAssertFalse(page("focus title=Quarterly salaries.xlsx result=ok").contains("salaries"))
        XCTAssertFalse(page(#"list windowTitle: "Dear diary" apps=3"#).contains("diary"))
        XCTAssertFalse(page("app_name=Private Notes pid=3").contains("Private"))
        XCTAssertEqual(page("assist windows list apps=3 windows=9 rev=4 locked=false"), "assist windows list apps=3 windows=9 rev=4 locked=false")
    }
}
