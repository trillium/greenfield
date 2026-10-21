import Foundation
import KitHealth
import XCTest
@testable import DictationApp

/// Nothing the phone shows may ask a person to type a key or an address. The Mac side is set up by running its installer,
/// and this app finds the computer on its own; Advanced is the one screen with a typing field, and it is never the fix
/// for a red state a new person walks into. These pin that over the sources and over the messages the app can produce.
final class NoTypingAsksTests: XCTestCase {
    /// Verbs only a person at a keyboard can carry out.
    private static let hands = "type|types|typed|typing|enter|enters|entering|paste|pastes|pasting"
    private static let offers = "fill in|fill out|write|give|put|supply|provide|add|adds|adding"
    private static let verbs = "\(hands)|\(offers)"
    /// Nouns only a person at a keyboard knows.
    private static let nouns = "key|keys|address|addresses|hostname|tailnet name|ip"
    /// A verb near a noun reads as an instruction to type something that only a person at a keyboard knows.
    /// The third is the wording a fix used when a saved key was refused: "or enter the right one".
    private var asksToTypeSomething: [String] {
        ["\\b(?:\(Self.verbs))\\b[^\"]{0,60}\\b(?:\(Self.nouns))\\b",
         "\\b(?:\(Self.nouns))\\b[^\"]{0,40}\\b(?:\(Self.verbs))\\b",
         "\\benter\\s+(it|them|the\\s+right\\s+one|the\\s+same\\s+one)\\b"]
    }

    private func asks(_ line: String) -> Bool {
        asksToTypeSomething.contains { line.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    private func strings(in source: String) -> [String] {
        let pattern = try? NSRegularExpression(pattern: #"\"([^"\\\n]|\\.)*\""#)
        let range = NSRange(source.startIndex..., in: source)
        return (pattern?.matches(in: source, range: range) ?? []).compactMap { match in
            let line = (source as NSString).substring(with: match.range)
            // A literal that interpolates is built at run time, so its words are the format string's, not its own.
            return line.contains("(") ? nil : line
        }
    }

    private var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Sources")
    }

    func testNoSourceAsksForTypingAKeyOrAnAddress() throws {
        let folder = sources
        let files = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }, "no Swift sources found under App/Sources")
        XCTAssertGreaterThan(files.count, 20, "the scan must actually read the sources")
        let offenders = files.compactMap { file -> String? in
            // Advanced is the one screen built for typing; it is the documented exception, not a red state.
            guard file.lastPathComponent != "AdvancedComputerView.swift" else { return nil }
            let source = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            return strings(in: source).first(where: asks).map { "\(file.lastPathComponent): \($0)" }
        }
        XCTAssertEqual(offenders, [], "these lines ask for typing: \(offenders.joined(separator: " | "))")
    }

    /// Every state the phone can be in, so a new red state cannot slip in with a typing fix.
    private func everyState() -> [HealthInputs] {
        let computer = HealthInputs.Computer(name: "macbook", address: "macbook.example.ts.net", isActive: true,
                                             hasKey: false, answer: nil)
        var states: [HealthInputs] = []
        for speech in [DictationSession.ModelState.ready, .loading, .downloading(0.42), .failed("no network"), .notLoaded] {
            for microphone in [ListenMachine.Status.listening, .off, .interrupted("a call"), .gaveUp("no audio")] {
                var input = HealthInputs()
                input.speechModel = speech
                input.microphonePermission = .granted
                input.microphoneStatus = microphone
                input.audioFlowing = microphone == .listening
                input.detectorModel = "Bundled model"
                input.detectorListening = microphone == .listening
                input.tailnetConnected = true
                input.computers = [computer]
                states.append(input)
            }
        }
        for permission in [HealthInputs.Permission.granted, .denied, .undetermined] {
            var input = states[0]
            input.microphonePermission = permission
            states.append(input)
        }
        var noMicrophone = states[0]
        noMicrophone.microphonePermission = .denied
        noMicrophone.microphoneStatus = .off
        states.append(noMicrophone)
        var noModel = states[0]
        noModel.speechModel = .failed("no network")
        noModel.speechModelOnDisk = false
        states.append(noModel)
        var noDetector = states[0]
        noDetector.detectorModel = ""
        states.append(noDetector)
        var brokenDetector = states[0]
        brokenDetector.detectorProblem = "bad model"
        states.append(brokenDetector)
        var silentDetector = states[0]
        silentDetector.detectorListening = false
        states.append(silentDetector)
        return states + edgeStates(states[0])
    }

    /// The states around the computer: off the tailnet, none found, none chosen.
    private func edgeStates(_ base: HealthInputs) -> [HealthInputs] {
        var offTailnet = base
        offTailnet.tailnetConnected = false
        offTailnet.computers = [.init(name: "mini0", address: "100.90.1.2:47821", isActive: true, hasKey: false, answer: nil)]
        var nothing = base
        nothing.computers = []
        nothing.queued = 3
        var noActive = base
        noActive.computers = [.init(name: "mini0", address: "mini0.example.ts.net", isActive: false, hasKey: true, answer: nil)]
        return [offTailnet, nothing, noActive]
    }

    /// The answers a Mac can give, so every branch of the per-computer item is walked once.
    private func everyAnswer() -> [ReceiverClient.Health] {
        var noAccessibility = ReceiverClient.MacStatus(name: "macbook", version: "0.3.0")
        noAccessibility.accessibility = false
        var locked = ReceiverClient.MacStatus(name: "macbook", version: "0.3.0")
        locked.locked = true
        var secure = ReceiverClient.MacStatus(name: "macbook", version: "0.3.0")
        secure.secureInput = true
        var old = ReceiverClient.MacStatus(name: "macbook", version: "0.1.0")
        old.delivery = .init(works: false, message: "the paste could not be set up", fix: nil)
        var views = ReceiverClient.MacStatus(name: "macbook", version: "0.3.0")
        views.appCompatibility = .init(works: false, message: "this app is older", fix: "Update the app")
        return [.ready(ReceiverClient.MacStatus(name: "macbook", version: "0.3.0")), .wrongKey, .keyNotSetOnMac,
                .incompatible("the app is too old"), .unreachable("timed out"),
                .ready(noAccessibility), .ready(locked), .ready(secure), .ready(old), .ready(views)]
    }

    func testNoHealthItemAsksForTypingAnything() {
        let items = everyState().flatMap { AppHealth.report($0).items }
            + everyAnswer().flatMap { answer -> [HealthItem] in
                [AppHealth.computer(.init(name: "macbook", address: "macbook.example.ts.net", isActive: true,
                                            hasKey: true, answer: answer)),
                 AppHealth.computer(.init(name: "macbook", address: "macbook.example.ts.net", isActive: true,
                                            hasKey: false, answer: answer))]
            }
        XCTAssertGreaterThan(items.count, 40, "the matrix must cover the report, not one state of it")
        let offenders = items.flatMap { item -> [String] in
            [item.detail, item.fix ?? ""].filter(asks).map { "\(item.id): \($0)" }
        }
        XCTAssertEqual(offenders, [], "these Health lines ask for typing: \(offenders.joined(separator: " | "))")
        XCTAssertGreaterThanOrEqual(items.filter { $0.level == .problem }.count, 12, "the matrix must reach the red states")
    }

    func testTheNoComputerFixNamesTheInstallerAndNotAForm() {
        var input = HealthInputs()
        input.computers = []
        let item = AppHealth.report(input).items.first { $0.id == "computers" }
        XCTAssertEqual(item?.fix, "Run mac/install.sh on the Mac, then leave this app open: the computer turns up here on its own.")
        XCTAssertEqual(item?.level, .problem)
    }

    func testAWrongKeyIsFixedOnTheMacOrByRemovingASavedOne() {
        let named = { (hasKey: Bool) in
            AppHealth.computer(.init(name: "macbook", address: "macbook.example.ts.net", isActive: true,
                                       hasKey: hasKey, answer: .wrongKey))
        }
        let saved = named(true)
        let keyless = named(false)
        XCTAssertTrue(saved.fix?.contains("remove the saved key") ?? false, "a saved one is removed, not retyped")
        XCTAssertTrue(keyless.fix?.contains("make -C mac install") ?? false, "a Mac that asks for one gets the installer")
        for item in [saved, keyless] { XCTAssertFalse(asks(item.fix ?? ""), item.fix ?? "") }
    }

    func testNoRefusalMessageAsksForTypingAnything() {
        let refusals: [ReceiverClient.Refusal] = [.badKey, .keyNotConfigured, .secureInput, .locked, .needsAccessibility,
                                                 .invalidText, .tooLarge, .insertFailed, .clientTooOld, .other]
        XCTAssertEqual(refusals.count, 10)
        for refusal in refusals {
            XCTAssertFalse(refusal.message.isEmpty, "\(refusal.rawValue) says nothing")
            XCTAssertFalse(asks(refusal.message), "\(refusal.rawValue): \(refusal.message)")
        }
    }

    @MainActor
    func testNoComputerHealthSummaryAsksForTypingAnything() {
        let states: [TargetHealth.State] = [.unknown, .checking, .ready(ReceiverClient.MacStatus(name: "m", version: "0.3.0")),
                                            .notice("working"), .wrongKey, .keyNotSetOnMac, .incompatible("too old"),
                                            .unreachable("timed out")]
        XCTAssertEqual(states.count, 8)
        for state in states {
            XCTAssertFalse(state.summary.isEmpty, "\(state) says nothing")
            XCTAssertFalse(asks(state.summary), state.summary)
        }
    }
}
