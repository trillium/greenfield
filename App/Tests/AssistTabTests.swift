import KitAssist
import KitAssistNet
import KitHealth
import KitUI
import XCTest
@testable import DictationApp

/// The Assist tab is the kit's screens; these pin what this app decides: which state the computer's status leads to, the words that name
/// this app's helper, the one informational Health line, and the transports for the daemon contract. Nothing here sends a pointer event.
final class AssistWiringTests: XCTestCase {
    private let mac = MacTarget(name: "MacBook", address: "macbook.example.ts.net")

    private func status(_ assist: [String: Any]?) -> ReceiverClient.Health {
        var body: [String: Any] = ["ok": true, "name": "MacBook", "version": currentAgentVersion, "accessibility": true]
        if let assist { body["assist"] = assist }
        return ReceiverClient.interpretHealth(status: 200, data: json(body))
    }

    // MARK: what the status leads to

    func testNoComputerAndNoAnswerYet() {
        XCTAssertEqual(AssistWiring.availability(selected: nil, answer: nil), .noComputer)
        XCTAssertNil(AssistWiring.availability(selected: mac, answer: nil), "not answered yet: the tab says it is looking")
    }

    func testAnAssistObjectDecidesTheTab() {
        let off = status(["enabled": false, "windows": false, "pointer": false, "capabilities": []])
        XCTAssertEqual(AssistWiring.availability(selected: mac, answer: off), .off)
        let none = status(["enabled": true, "windows": false, "pointer": false, "capabilities": []])
        XCTAssertEqual(AssistWiring.availability(selected: mac, answer: none), .toolsOff)
        let windowsOnly = status(["enabled": true, "windows": true, "pointer": false, "capabilities": ["windowTitles"]])
        XCTAssertEqual(AssistWiring.availability(selected: mac, answer: windowsOnly),
                       .ready(trackpad: false, windows: true, capabilities: .windowTitles))
        let both = status(["enabled": true, "windows": true, "pointer": true, "capabilities": ["zoom", "nativeMomentum"]])
        XCTAssertEqual(AssistWiring.availability(selected: mac, answer: both),
                       .ready(trackpad: true, windows: true, capabilities: [.zoom, .nativeMomentum]))
    }

    func testAnAgentWithoutAssistToolsIsUnsupportedNotOff() {
        XCTAssertEqual(AssistWiring.availability(selected: mac, answer: status(nil)), .unsupported)
    }

    func testAnAgentThatCannotBeUsedOrReachedLeadsToTheMatchingState() {
        XCTAssertEqual(AssistWiring.availability(selected: mac, answer: .unreachable("no")), .unreachable)
        for answer in [ReceiverClient.Health.wrongKey, .keyNotSetOnMac, .incompatible("old")] {
            XCTAssertEqual(AssistWiring.availability(selected: mac, answer: answer), .unsupported, "\(answer)")
        }
    }

    func testAnAgentThatTheAppMustNotTalkToLeadsToUnsupportedEvenWithAssistOn() {
        let on = AssistStatus(enabled: true, windows: true, pointer: true)
        let tooOld = ReceiverClient.MacStatus(name: "x", version: "0.1.0", assist: on)
        XCTAssertEqual(AssistWiring.availability(selected: mac, answer: .ready(tooOld)), .unsupported)
    }

    // MARK: words

    func testTheOneNextStepWhenAssistIsOffNamesTheCommandOnTheMac() {
        let step = AssistWiring.strings.turnOnStep
        XCTAssertTrue(step.contains("greenfield-inserter assist on"))
        XCTAssertTrue(step.contains("check again"))
        let (title, shown) = AssistWiring.strings.failure(.off, computer: "MacBook")
        XCTAssertEqual(title, "Assist is off on MacBook")
        XCTAssertEqual(shown, step)
    }

    func testTheWordsThatAreNotThisAppsStayTheKits() {
        XCTAssertEqual(AssistWiring.strings.trackpadRow, AssistStrings.standard.trackpadRow)
        XCTAssertEqual(AssistWiring.strings.assistTitle, "Assist")
    }

    // MARK: status parsing

    func testTheStatusAnswerCarriesTheAssistObject() {
        let answer = status(["enabled": true, "windows": true, "pointer": false, "capabilities": ["zoom", "unknownBit"]])
        guard case .ready(let found) = answer else {
            return XCTFail("a status with an assist object is ready")
        }
        XCTAssertEqual(found.assist, AssistStatus(enabled: true, windows: true, pointer: false, capabilities: .zoom))
    }

    func testAMalformedAssistObjectIsTreatedAsNone() {
        guard case .ready(let found) = ReceiverClient.interpretHealth(
            status: 200, data: json(["ok": true, "version": currentAgentVersion, "assist": "yes"])) else { return XCTFail("still ready") }
        XCTAssertNil(found.assist)
    }

    // MARK: Health

    private func input(assist: AssistStatus?, active: Bool = true) -> HealthInputs {
        var input = HealthInputs()
        input.speechModel = .ready
        input.microphonePermission = .granted
        input.microphoneStatus = .listening
        input.audioFlowing = true
        input.detectorModel = "Bundled model"
        input.detectorListening = true
        input.computers = [.init(name: "mini0", address: "mini0.example.ts.net", isActive: active, hasKey: false,
                                 answer: .ready(ReceiverClient.MacStatus(name: "mini0", version: currentAgentVersion, insertedCount: 1,
                                                                         assist: assist)))]
        return input
    }

    func testAssistOffIsAnInformationalLineWithTheOneStepAndNotAFailure() throws {
        let report = AppHealth.report(input(assist: AssistStatus(enabled: false, windows: false, pointer: false)))
        let line = try XCTUnwrap(report.items.first { $0.id == "assist-mini0" })
        XCTAssertEqual(line.level, .ok, "off is how assist ships; it is not a problem")
        XCTAssertTrue(line.detail.contains("Assist is off on mini0"))
        XCTAssertTrue(try XCTUnwrap(line.fix).contains("greenfield-inserter assist on"))
        XCTAssertNil(report.items.first { $0.level != .ok && $0.id.contains("assist") })
        XCTAssertTrue(report.problems.allSatisfy { !$0.id.contains("assist") })
    }

    func testAssistOnOrAbsentSaysNothing() {
        for assist in [AssistStatus(enabled: true, windows: true, pointer: true), nil] {
            XCTAssertNil(AppHealth.report(input(assist: assist)).items.first { $0.id.hasPrefix("assist") }, "\(String(describing: assist))")
        }
    }

    func testTheAssistLineNeverTurnsAHealthyReportIntoAWarning() {
        let off = AppHealth.report(input(assist: AssistStatus(enabled: false, windows: false, pointer: false)))
        XCTAssertEqual(off.worst, .ok)
    }

    // MARK: transports

    func testTransportsAreMadeForAReachableAddressOnly() {
        XCTAssertNotNil(AssistWiring.transports(for: mac))
        XCTAssertNil(AssistWiring.transports(for: MacTarget(name: "x", address: "has a space")))
    }

    @MainActor
    func testTheCacheKeepsOneSetOfTransportsPerComputerAndRebuildsWhenItChanges() {
        let cache = AssistTransportCache()
        let target = mac
        var built = 0
        let make: (MacTarget) -> AssistTransports? = { made in
            built += 1
            return AssistWiring.transports(for: made)
        }
        _ = cache.transports(for: target, make: make)
        _ = cache.transports(for: target, make: make)
        XCTAssertEqual(built, 1)
        var moved = target
        moved.address = "other.example.ts.net"
        _ = cache.transports(for: moved, make: make)
        XCTAssertEqual(built, 2)
    }

    func testTailnetNamesNeedTheTailnetAndNothingIsSentWithoutIt() async {
        StubURLProtocol.install { _ in (200, json([:])) }
        let transport = AppAssistHTTPTransport(named: URLSessionTransport(session: StubURLProtocol.session()), tailnetConnected: { false })
        let request = URLRequest(url: URL(string: "http://macbook.example.ts.net:47821/status")!)
        do {
            _ = try await transport.send(request)
            XCTFail("off the tailnet there is no route")
        } catch {
            XCTAssertTrue(error is URLError)
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testAddressesTakeTheSocketRouteAndNamesTakeURLSession() async throws {
        let socket = RecordingHTTPTransport()
        StubURLProtocol.install { _ in (404, json(["error": "assist_off"])) }
        let transport = AppAssistHTTPTransport(named: URLSessionTransport(session: StubURLProtocol.session()), address: socket,
                                               tailnetConnected: { true })
        let viaAddress = try await transport.send(URLRequest(url: URL(string: "http://100.84.1.2:47821/status")!))
        let viaName = try await transport.send(URLRequest(url: URL(string: "http://macbook.example.ts.net:47821/status")!))
        XCTAssertEqual(socket.sent.map(\.host), ["100.84.1.2"])
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.host }, ["macbook.example.ts.net"])
        XCTAssertEqual(viaAddress.status, 200)
        XCTAssertEqual(viaName.status, 404)
    }

    func testTheKitClientReadsAssistFromTheStatusOverThisAppsTransport() async throws {
        StubURLProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/status")
            XCTAssertNotNil(request.value(forHTTPHeaderField: AppVersion.header) ?? (AppVersion.current == nil ? "none" : nil))
            let assist: [String: Any] = ["enabled": true, "windows": true, "pointer": false, "capabilities": ["windowTitles"]]
            return (200, json(["ok": true, "assist": assist]))
        }
        let transport = AppAssistHTTPTransport(named: URLSessionTransport(session: StubURLProtocol.session()), tailnetConnected: { true })
        let client = AssistHTTPClient(baseURL: try XCTUnwrap(mac.baseURL), headers: AssistWiring.headers(), transport: transport)
        let found = try await client.status()
        XCTAssertEqual(found, AssistStatus(enabled: true, windows: true, pointer: false, capabilities: .windowTitles))
    }

    func testAnAssistRouteThatIsOffReadsAsOff() async throws {
        StubURLProtocol.install { _ in (404, json(["ok": false, "error": "assist_off"])) }
        let transport = AppAssistHTTPTransport(named: URLSessionTransport(session: StubURLProtocol.session()), tailnetConnected: { true })
        let client = AssistHTTPClient(baseURL: try XCTUnwrap(mac.baseURL), transport: transport)
        do {
            _ = try await client.list(since: nil)
            XCTFail("a 404 is assist off")
        } catch {
            XCTAssertEqual(error as? AssistError, .off)
        }
    }
}

private final class RecordingHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var sent: [URL] { lock.withLock { urls } }

    func send(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        lock.withLock { urls.append(request.url!) }
        return (200, json(["ok": true]))
    }
}
