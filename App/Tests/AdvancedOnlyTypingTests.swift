import Foundation
import XCTest

/// The app must never ask a person to type a computer, an address or a key: the only screen that does is Advanced,
/// behind the "Advanced" row. That promise lives in the shape of the view sources, so these read them.
final class AdvancedOnlyTypingTests: XCTestCase {
    /// Only these two screens may hold a typing field: the last-resort computer form and the sound phrase list.
    private let mayType = ["AdvancedComputerView.swift", "SoundsView.swift"]

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func viewsDirectory() throws -> URL {
        try XCTUnwrap(URL(fileURLWithPath: root.path).appendingPathComponent("App/Sources/Views"))
    }

    /// The screens a new person walks through. Anything here is the normal flow and may not ask for typing.
    private let normalFlow = ["OnboardingView.swift", "TargetsView.swift", "TargetPicker.swift", "QRScannerView.swift",
                           "DictateView.swift", "HealthView.swift"]

    /// The words that turn a label into an instruction to type something.
    private let asksToType = ["type", "types", "typed", "typing", "key", "keys", "address", "addresses", "hostname", "tailnetname", "ip"]

    private func strings(in source: String) -> [String] {
        let pattern = try? NSRegularExpression(pattern: #"\"([^"\\\n]|\\.)*\""#)
        let range = NSRange(source.startIndex..., in: source)
        return (pattern?.matches(in: source, range: range) ?? []).compactMap { match in
            let line = (source as NSString).substring(with: match.range)
            // A literal that interpolates is built at run time, so its words are the format string's, not its own.
            return line.contains("(") ? nil : line
        }
    }

    func testOnlyTheAdvancedScreenAndTheSoundPhrasesHoldATypingField() throws {
        let folder = try viewsDirectory()
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        try XCTSkipIf(files.isEmpty, "App/Sources/Views is empty")
        let offenders = files.filter { file in
            guard !mayType.contains(file) else { return false }
            let source = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            return source?.contains("TextField") == true || source?.contains("SecureField") == true
        }
        XCTAssertEqual(offenders, [], "typing fields outside Advanced: \(offenders.joined(separator: ", "))")
    }

    func testTheAdvancedScreenHoldsTheComputerAndKeyFields() throws {
        let source = try String(contentsOf: viewsDirectory().appendingPathComponent("AdvancedComputerView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("SecureField"), "Advanced must be where a key is typed")
        XCTAssertTrue(source.contains(#"TextField("Tailnet name or address""#), "Advanced must be where a computer is typed")
        XCTAssertTrue(source.contains("Keychain"), "a typed key is kept in the Keychain on that phone only")
    }

    func testTheComputersScreenReachesTheTypingOnlyThroughTheAdvancedRow() throws {
        let source = try String(contentsOf: viewsDirectory().appendingPathComponent("TargetsView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(#"Label("Advanced""#), "the Computers screen must offer the Advanced row")
        XCTAssertTrue(source.contains("AdvancedComputerView(model: model)"), "the Advanced row must lead to the typing screen")
        XCTAssertFalse(source.contains("TextField"), "the Computers screen must not type a computer")
        XCTAssertFalse(source.contains("SecureField"), "the Computers screen must not type a key")
    }

    func testNoScreenInTheNormalFlowAsksForAKeyAnAddressOrTyping() throws {
        let folder = try viewsDirectory()
        // "type" and friends only read as an instruction when a person is being asked to do it; these say so instead.
        let allowed = ["no key", "nothing to type", "without typing", "no typing", "no address", "no typing."]
        let offenders = normalFlow.flatMap { file -> [String] in
            let source = (try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)) ?? ""
            return strings(in: source)
                .filter { line in
                    let words = line.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
                    let asks = words.contains { asksToType.contains($0) }
                    return asks && !allowed.contains(where: { line.lowercased().contains($0) })
                }
        }
        XCTAssertEqual(offenders, [], "the normal flow must not ask for typing: \(offenders.joined(separator: " | "))")
    }
}
