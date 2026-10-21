import KitHealth
import XCTest
@testable import DictationApp

/// The phone's support log: secrets and dictated text are pushed through every logger and the outbox, and none can come out.
@MainActor
final class SupportLogTests: XCTestCase {
    // Built at run time so no secret scanner mistakes a test canary for a real credential.
    private let canary = "canary-" + String(repeating: "7f3a9c", count: 7)
    private let dictated = "my bank password is hunter2-ZEBRA and the card is 4111-1111-1111-1111"

    private struct Rig {
        let support: SupportLog
        let log: EventLog
        let outbox: Outbox
    }

    private func makeRig(url: URL? = nil) -> Rig {
        let log = EventLog(url: nil)
        let outbox = Outbox(url: nil)
        let info: [String: Any] = ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45"]
        return Rig(support: SupportLog(log: log, outbox: outbox, url: url, info: info), log: log, outbox: outbox)
    }

    func testDictatedTextAndKeysNeverReachTheSupportLog() {
        let rig = makeRig()
        let (support, log, outbox) = (rig.support, rig.log, rig.outbox)
        let item = outbox.add(text: dictated, asrMs: 321)
        outbox.markAttempt(item.id, targetName: "Mac mini")
        outbox.markFailed(item.id, reason: "refused: X-Dictation-Key: \(canary) was wrong")
        let sent = outbox.add(text: dictated + " again")
        outbox.markSent(sent.id, networkMs: 40, macMs: 5, delivery: "confirmed")
        // what the app's own loggers write: lengths and timings, never the words
        log.add(.dictation, "transcribed \(dictated.count) characters in 321 ms")
        log.add(.send, "submitted \(dictated.count) characters to Mac mini")
        log.add(.send, "could not reach Mac mini: header Authorization: Bearer \(canary)")
        log.add(.model, "speech model failed: token=\(canary)")
        let text = support.render()
        for needle in ["hunter2", "ZEBRA", "4111", "bank password", canary, "7f3a9c7f3a9c"] {
            XCTAssertFalse(text.contains(needle), "the support log contains \(needle):\n\(text)")
        }
        XCTAssertTrue(text.contains("chars=\(dictated.count)"), "the length of each text is kept")
        XCTAssertTrue(text.contains("id=\(item.id.uuidString)"))
        XCTAssertTrue(text.contains("status=pending") && text.contains("status=sent"))
        XCTAssertTrue(text.contains("error=refused: X-Dictation-Key: <redacted>"))
        XCTAssertTrue(text.contains("[send] submitted \(dictated.count) characters"))
        XCTAssertTrue(text.contains("# app: v1.2.3 (45)"))
    }

    func testEveryLineStartsWithATimeSoSinceCanFilterIt() {
        let rig = makeRig()
        let (support, log, outbox) = (rig.support, rig.log, rig.outbox)
        log.add(.app, "one", date: Date(timeIntervalSince1970: 1_800_000_000))
        outbox.add(text: "x")
        let lines = support.render().split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            let first = String(line.split(separator: " ").first ?? "")
            XCTAssertNotNil(ISO8601DateFormatter().date(from: first), String(line))
        }
    }

    func testTheFileIsWrittenAndFollowsTheLog() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("support-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let rig = makeRig(url: url)
        let (support, log) = (rig.support, rig.log)
        XCTAssertNotNil(support.writeNow())
        log.add(.app, "later event")
        try await Task.sleep(for: .seconds(2.6))
        XCTAssertTrue((try? String(contentsOf: url, encoding: .utf8))?.contains("later event") ?? false)
        XCTAssertTrue(support.isAvailable)
    }

    func testAnUnwritableFileIsReportedNotHidden() {
        let support = makeRig(url: URL(fileURLWithPath: "/nonexistent-folder/support-log.txt")).support
        XCTAssertNil(support.writeNow())
        XCTAssertFalse(support.isAvailable)
        var input = HealthInputs()
        input.logsAvailable = support.isAvailable
        let item = AppHealth.report(input).items.first { $0.id == "logs" }
        XCTAssertEqual(item?.level, .warning)
        XCTAssertNotNil(item?.fix)
    }

    func testHealthSaysLogsAreAvailable() {
        var input = HealthInputs()
        input.loggedEvents = 12
        let item = AppHealth.report(input).items.first { $0.id == "logs" }
        XCTAssertEqual(item?.title, "Logs available")
        XCTAssertEqual(item?.level, .ok)
        XCTAssertTrue(item?.detail.contains("12 events") ?? false)
    }

    func testTheOutboxFileItselfIsNotWhatLeavesThePhone() {
        // outbox.json keeps the words so a failed send can be retried; the support log never reads them.
        XCTAssertEqual(SupportLog.containerPath, "Library/Application Support/support-log.txt")
        let inContainer = SupportLog.containerPath.replacingOccurrences(of: "Library/", with: "")
        XCTAssertTrue(SupportLog.standardURL.path.hasSuffix(inContainer))
        let item = OutboxItem(text: dictated)
        XCTAssertFalse(SupportLog.line(item).contains("hunter2"))
    }
}
