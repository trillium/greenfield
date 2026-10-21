import KitAssist
import SwiftUI
import UIKit
import XCTest
@testable import DictationApp

/// The request line the raw TCP transport writes keeps the query, so `?since=&epoch=` reaches the window list.
final class SocketRequestLineTests: XCTestCase {
    func testTheQueryIsPartOfTheRequestLine() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://100.84.1.2:47821/assist/windows?since=7&epoch=a%20b")))
        request.httpMethod = "GET"
        let wire = String(bytes: SocketTransport.encode(request, host: "100.84.1.2", port: 47821), encoding: .utf8) ?? ""
        XCTAssertTrue(wire.hasPrefix("GET /assist/windows?since=7&epoch=a%20b HTTP/1.1\r\n"), wire)
    }

    func testARequestWithoutAQueryIsUnchanged() throws {
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://100.84.1.2:47821/status")))
        let wire = String(bytes: SocketTransport.encode(request, host: "100.84.1.2", port: 47821), encoding: .utf8) ?? ""
        XCTAssertTrue(wire.hasPrefix("GET /status HTTP/1.1\r\n"), wire)
    }
}

/// The shell: five tabs in the shared order, Assist among them, the outbox inside Computers, and the tab itself drawn from a real model.
@MainActor
final class AssistTabViewTests: XCTestCase {
    private var contentView: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent("Sources/ContentView.swift"), encoding: .utf8)
        }
    }

    func testTheTabBarHasTheFiveSharedTabsInOrder() throws {
        let labels = try contentView.components(separatedBy: "\n").compactMap { line -> String? in
            guard let range = line.range(of: #"tabItem \{ Label\("([^"]+)""#, options: .regularExpression) else { return nil }
            return String(line[range]).components(separatedBy: "\"")[1]
        }
        XCTAssertEqual(labels, ["Dictate", "Sounds", "Assist", "Computers", "Help"])
        XCTAssertTrue(try contentView.contains("AssistTabView(model: model)"))
        XCTAssertFalse(try contentView.contains("OutboxView"), "the outbox is a screen of Computers, not a sixth tab")
    }

    private func makeModel(answering body: [String: Any]?) throws -> AppModel {
        let reply = body.map(json)
        StubURLProtocol.install { _ in
            guard let reply else { throw URLError(.cannotConnectToHost) }
            return (200, reply)
        }
        let store = TargetStore(defaults: isolatedDefaults(), keys: MemoryKeyStore())
        try store.save(MacTarget(name: "MacBook", address: "macbook.ts.net"), key: nil)
        return AppModel(session: DictationSession(transcriber: ParakeetTranscriber()), outbox: Outbox(url: nil), targets: store,
                        client: ReceiverClient(session: StubURLProtocol.session(), tailnetConnected: { true }),
                        models: testStore(), ruleStore: RuleStore(defaults: isolatedDefaults()))
    }

    /// Hosts the tab on a phone-sized window, waits for the status check it starts for the active computer, and returns the state
    /// that answer leads to.
    private func hostAndWait(_ model: AppModel) async throws -> AssistAvailability? {
        let controller = UIHostingController(rootView: AssistTabView(model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let target = try XCTUnwrap(model.targets.selected)
        for _ in 0..<100 where model.health.answers[target.id] == nil { try await Task.sleep(for: .milliseconds(50)) }
        controller.view.layoutIfNeeded()
        XCTAssertFalse(controller.view.subviews.isEmpty, "the tab lays out")
        window.isHidden = true
        return AssistWiring.availability(selected: target, answer: model.health.answers[target.id])
    }

    func testOpeningTheTabAsksTheActiveMacAndAssistOffLeadsToTheOffState() async throws {
        let model = try makeModel(answering: ["ok": true, "name": "MacBook", "version": currentAgentVersion,
                                              "assist": ["enabled": false, "windows": false, "pointer": false, "capabilities": []]])
        let result = try await hostAndWait(model)
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.path, "/status", "the tab reads the active computer's status")
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.host, "macbook.ts.net")
        XCTAssertEqual(result, .off)
    }

    func testAMacWithAssistOnLeadsToBothTools() async throws {
        let assist: [String: Any] = ["enabled": true, "windows": true, "pointer": true, "capabilities": ["windowTitles"]]
        let model = try makeModel(answering: ["ok": true, "name": "MacBook", "version": currentAgentVersion, "assist": assist])
        let result = try await hostAndWait(model)
        XCTAssertEqual(result, .ready(trackpad: true, windows: true, capabilities: .windowTitles))
    }

    func testAMacThatDoesNotAnswerLeadsToTheUnreachableState() async throws {
        let model = try makeModel(answering: nil)
        let result = try await hostAndWait(model)
        XCTAssertEqual(result, .unreachable)
    }

    func testChoosingAnotherComputerMovesTheTab() async throws {
        let model = try makeModel(answering: ["ok": true, "name": "x", "version": currentAgentVersion,
                                              "assist": ["enabled": false, "windows": false, "pointer": false, "capabilities": []]])
        try model.targets.save(MacTarget(name: "Mini", address: "mini.ts.net"), key: nil)
        let mini = try XCTUnwrap(model.targets.targets.first { $0.name == "Mini" })
        model.targets.select(mini.id)
        let result = try await hostAndWait(model)
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.host, "mini.ts.net", "the tab follows the active computer, not the first one")
        XCTAssertEqual(result, .off)
    }
}
