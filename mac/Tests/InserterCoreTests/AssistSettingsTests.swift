import XCTest
@testable import InserterCore

final class AssistSettingsTests: XCTestCase {
    var directory: URL!
    var paths: InserterPaths!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("assist-settings-\(UUID().uuidString)")
        paths = InserterPaths(directory: directory)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testEverythingIsOffByDefault() {
        let s = AssistSettings()
        XCTAssertFalse(s.enabled)
        XCTAssertFalse(s.windowsAvailable)
        XCTAssertFalse(s.pointerAvailable)
        XCTAssertFalse(s.pointer, "the pointer needs its own switch even when assist is on")
        XCTAssertEqual(FileAssistSettings(paths: paths).current(), .off, "no file means off")
    }

    func testAMalformedFileIsOffNeverGuessed() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = FileAssistSettings(paths: paths)
        for text in ["", "not json", "[]", #"{"enabled":"true"}"#, #"{"enabled":1}"#, #"{"enabled":true,"pointer":"yes"}"#] {
            try text.write(to: paths.assistFile, atomically: true, encoding: .utf8)
            XCTAssertEqual(file.current(), .off, text)
        }
        try #"{"enabled":true,"unknown":5}"#.write(to: paths.assistFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(file.current(), AssistSettings(enabled: true), "unknown keys are ignored")
    }

    func testSavedPrivatelyAndFollowedAtOnce() throws {
        let file = FileAssistSettings(paths: paths)
        try file.save(AssistSettings(enabled: true, pointer: true))
        XCTAssertEqual(file.current(), AssistSettings(enabled: true, pointer: true))
        let mode = try FileManager.default.attributesOfItem(atPath: paths.assistFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        for i in 0..<20 {   // flips within one instant, with files of the same size, are all seen
            try file.update { $0.enabled = i % 2 == 0; $0.pointer = i % 2 != 0 }
            XCTAssertEqual(file.current().enabled, i % 2 == 0)
            XCTAssertEqual(file.current().pointer, i % 2 != 0)
        }
    }

    func testTheKillSwitchReachesTheRoutesWithoutARestart() throws {
        let file = FileAssistSettings(paths: paths)
        let handler = RequestHandler(keys: StubKeys(), probe: StubProbe(), inserter: SpyInserter(), name: { "Mac" }, identity: FakeIdentity(),
                                     assist: AssistEndpoints(settings: file, windows: WindowService(provider: FakeWindowProvider(), probe: StubProbe(), settings: file,
                                                                                                    computerName: { "Mac" }), pointer: nil),
                                     version: "0.4.0", minClientVersion: "0.2.0")
        func status() -> Int { handler.handle(HTTPRequest(method: "GET", path: "/assist/windows", peerAddress: "100.64.0.20")).status }
        XCTAssertEqual(status(), 404)
        try file.update { $0.enabled = true }
        XCTAssertEqual(status(), 200)
        try file.update { $0.enabled = false }
        XCTAssertEqual(status(), 404)
    }

    func testTheRateLimitRefills() {
        let limit = RateLimit(perSecond: 2, burst: 3)
        XCTAssertEqual((0..<5).map { _ in limit.allow(at: 10) }, [true, true, true, false, false])
        XCTAssertTrue(limit.allow(at: 10.5))
        XCTAssertFalse(limit.allow(at: 10.5))
        XCTAssertTrue(limit.allow(at: 20))
        XCTAssertTrue(limit.allow(at: 5), "a clock that went backwards does not lock it")
    }
}
