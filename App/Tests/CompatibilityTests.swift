import XCTest
@testable import DictationApp

final class SemverTests: XCTestCase {
    func testParsingIgnoresBuildMetadataAndALeadingV() {
        XCTAssertEqual(Semver("0.2.0"), Semver(0, 2, 0))
        XCTAssertEqual(Semver("v1.4.12+3.gabc1234.dirty"), Semver(1, 4, 12))
        for bad in [nil, "", "1.2", "1.2.3.4", "a.b.c", "1.2.x", "-1.0.0", "0.1.0-rc1"] { XCTAssertNil(Semver(bad), bad ?? "nil") }
    }

    func testOrdering() {
        XCTAssertLessThan(Semver(0, 1, 9), Semver(0, 2, 0))
        XCTAssertLessThan(Semver(0, 9, 9), Semver(1, 0, 0))
        XCTAssertGreaterThan(Semver(1, 0, 10), Semver(1, 0, 9))
    }

    func testTheRuleBeforeAndAfterOneDotZero() {
        XCTAssertTrue(Semver(0, 2, 0).isCompatible(with: Semver(0, 2, 7)), "0.x: minor matches, patch free")
        XCTAssertFalse(Semver(0, 2, 0).isCompatible(with: Semver(0, 3, 0)), "0.x: a different minor is breaking")
        XCTAssertFalse(Semver(0, 2, 0).isCompatible(with: Semver(1, 2, 0)))
        XCTAssertTrue(Semver(1, 0, 0).isCompatible(with: Semver(1, 5, 3)), "1.x: major matches, minor free")
        XCTAssertFalse(Semver(1, 5, 0).isCompatible(with: Semver(2, 5, 0)))
    }
}

final class CompatibilityVerdictTests: XCTestCase {
    private let app = Semver(0, 2, 1)
    private let floor = Semver(0, 2, 0)

    private func verdict(agent: String?, minClient: String? = nil, app: Semver? = nil) -> Compatibility.Verdict {
        Compatibility.judge(app: app ?? self.app, agent: agent, minClient: minClient, minimumAgent: floor)
    }

    func testMatchingLineIsCompatible() {
        XCTAssertEqual(verdict(agent: "0.2.0"), .compatible)
        XCTAssertEqual(verdict(agent: "0.2.9", minClient: "0.2.0"), .compatible)
    }

    func testAnAgentThatStatesNoVersionOrTooOldNeedsAnUpdate() {
        XCTAssertEqual(verdict(agent: nil), .updateAgent)
        XCTAssertEqual(verdict(agent: "garbage"), .updateAgent)
        XCTAssertEqual(verdict(agent: "0.1.0"), .updateAgent, "below this app's declared minimum")
    }

    func testAnAgentFromANewerLineMeansTheAppIsBehind() {
        XCTAssertEqual(verdict(agent: "0.3.0"), .updateApp)
        XCTAssertEqual(verdict(agent: "1.0.0"), .updateApp)
    }

    func testTheAgentsMinimumClientWins() {
        XCTAssertEqual(verdict(agent: "0.2.5", minClient: "0.2.4"), .updateApp, "app 0.2.1 is below the agent's minimum")
    }

    func testAnUnknownAppVersionIsNotBlamedForAnything() {
        XCTAssertEqual(Compatibility.judge(app: nil, agent: "0.9.0", minClient: "5.0.0", minimumAgent: floor), .compatible)
    }

    func testABuildBelowItsOwnFloorDoesNotBlameTheAgent() {
        // An untagged checkout stamps the app 0.0.1 while the floor still says 0.2.0: the two Macs and phones that
        // ship from the same tree are the same age, so neither is told to update.
        XCTAssertEqual(Compatibility.judge(app: Semver(0, 0, 1), agent: "0.0.1", minClient: nil, minimumAgent: floor), .compatible)
        XCTAssertEqual(Compatibility.judge(app: Semver(0, 1, 9), agent: "0.1.4", minClient: nil, minimumAgent: Semver(0, 2, 0)),
                       .compatible)
    }

    func testTheFloorStillSpeaksForABuildAtOrAboveIt() {
        XCTAssertEqual(Compatibility.judge(app: Semver(0, 2, 0), agent: "0.1.0", minClient: nil, minimumAgent: floor), .updateAgent)
        XCTAssertEqual(Compatibility.judge(app: Semver(0, 3, 0), agent: "0.1.0", minClient: nil, minimumAgent: floor), .updateAgent)
    }

    func testTheLiveAppDeclaresAMinimumAndKnowsItsVersion() {
        XCTAssertNotNil(Compatibility.minimumAgent, "GREENFIELD_MIN_PEER_VERSION must reach Info.plist")
        XCTAssertNotNil(Compatibility.appVersion, "the app's version comes from the git tag, never typed in")
    }
}

final class CompatibilityWireTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testEveryRequestCarriesTheAppVersion() async throws {
        StubURLProtocol.install { _ in (200, json(["ok": true])) }
        let client = ReceiverClient(session: StubURLProtocol.session(), tailnetConnected: { true })
        let base = URL(string: "http://mac.example.ts.net:47821")!
        _ = await client.send(id: UUID(), text: "hi", to: base, key: nil)
        _ = await client.health(of: base, key: nil)
        _ = await client.peers(of: base, key: nil)
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        for request in StubURLProtocol.requests {
            let sent = request.value(forHTTPHeaderField: Compatibility.appHeader)
            XCTAssertNotNil(Semver(sent), "\(request.url?.path ?? "") sent \(sent ?? "nothing")")
        }
    }

    func testTheClientStillMatchesTheRecordedRequestSamples() async throws {
        StubURLProtocol.install { _ in (200, json(["ok": true])) }
        let client = ReceiverClient(session: StubURLProtocol.session(), tailnetConnected: { true })
        let base = URL(string: "http://mac.example.ts.net:47821")!
        _ = await client.send(id: UUID(), text: "hi", to: base, key: "k")
        _ = await client.health(of: base, key: "k")
        let text = try fixture("request-text.json"), status = try fixture("request-status.json")
        for (sample, request) in [(text, StubURLProtocol.requests[0]), (status, StubURLProtocol.requests[1])] {
            XCTAssertEqual(sample["method"] as? String, request.httpMethod)
            XCTAssertEqual(sample["path"] as? String, request.url?.path)
            for name in (sample["headers"] as? [String: String] ?? [:]).keys {
                XCTAssertNotNil(request.value(forHTTPHeaderField: name), "the sample says the phone sends \(name)")
            }
        }
        let body = StubURLProtocol.requests[0].httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        XCTAssertEqual(Set(body.keys), Set((text["body"] as? [String: Any] ?? [:]).keys), "the body fields are exactly the recorded ones")
    }

    /// The Mac side owns `mac/Tests/Fixtures/status-*.json`, recorded from the real daemon. Each one must parse into a sensible status.
    func testTheMacSidesRecordedStatusSamplesParse() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("mac/Tests/Fixtures")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("status-") }
        try XCTSkipIf(files.isEmpty, "mac/Tests/Fixtures/status-*.json has not landed yet")
        for file in files {
            let data = try Data(contentsOf: folder.appendingPathComponent(file))
            let recorded = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if let code = recorded["_http_status"] as? Int, code != 200 {
                // A refusal sample: the phone must not read it as a healthy computer.
                if case .ready = ReceiverClient.interpretHealth(status: code, data: data) { XCTFail("\(file) must not read as ready") }
                continue
            }
            guard case .ready(let status) = ReceiverClient.interpretHealth(status: 200, data: data) else {
                return XCTFail("\(file) is not ready")
            }
            XCTAssertNotNil(Semver(status.version), "\(file): version must be a semver, got '\(status.version)'")
            XCTAssertNotNil(Semver(status.minClientVersion), "\(file): min_client_version must be a semver")
        }
    }

    func testA426MeansTheAppIsTooOld() {
        XCTAssertEqual(ReceiverClient.interpret(status: 426, data: Data()), .refused(.clientTooOld))
        XCTAssertTrue(ReceiverClient.Refusal.clientTooOld.message.contains("Update the app"))
    }

    func testTheMacsOwnViewIsRead() {
        let view: [String: Any] = ["ok": false, "message": "newest app seen is 0.1.4", "fix": "Update the app"]
        let body = json(["ok": true, "version": "0.2.0", "app_compatible": view])
        guard case .ready(let status) = ReceiverClient.interpretHealth(status: 200, data: body) else { return XCTFail("not ready") }
        XCTAssertEqual(status.appCompatibility, .init(works: false, message: "newest app seen is 0.1.4", fix: "Update the app"))
    }
}

final class CompatibilityHealthTests: XCTestCase {
    private func item(agent: String?, minClient: String? = nil, view: ReceiverClient.DeliveryLine? = nil) -> HealthItem {
        var status = ReceiverClient.MacStatus(name: "macbook", version: agent ?? "")
        status.minClientVersion = minClient
        status.appCompatibility = view
        let computer = HealthInputs.Computer(name: "macbook", address: "macbook.example.ts.net", isActive: true, hasKey: false,
                                             answer: .ready(status))
        return HealthReport.computer(computer, app: Semver(0, 2, 1), minimumAgent: Semver(0, 2, 0))
    }

    func testCompatibleIsSaidPlainly() {
        let good = item(agent: "0.2.3")
        XCTAssertEqual(good.level, .ok)
        XCTAssertTrue(good.detail.contains("Compatible (app 0.2.1)"))
    }

    func testUpdateTheDaemonAndUpdateTheAppEachCarryTheirFix() {
        let old = item(agent: "0.1.0")
        XCTAssertEqual(old.level, .problem)
        XCTAssertTrue(old.detail.contains("Update the Mac daemon"))
        XCTAssertTrue(old.fix?.contains("make -C mac install") ?? false)
        let behind = item(agent: "0.3.0")
        XCTAssertTrue(behind.detail.contains("Update the app"))
        XCTAssertTrue(behind.fix?.contains("newest Greenfield") ?? false)
        XCTAssertTrue(item(agent: nil).detail.contains("too old to state a version"))
    }

    func testTheMacsOwnComplaintIsShownAsAWarning() {
        let warned = item(agent: "0.2.2", view: .init(works: false, message: "newest app seen is 0.1.4", fix: nil))
        XCTAssertEqual(warned.level, .warning)
        XCTAssertTrue(warned.detail.contains("newest app seen is 0.1.4"))
    }
}
