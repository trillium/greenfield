import KitUI
import ParrotKit
import SwiftUI
import UIKit
import XCTest
@testable import DictationApp

/// The About screen's credits: what each licence asks for is on the screen, the licence texts are in the app, and a dependency without a
/// credit fails here instead of in review.
@MainActor
final class AttributionTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var info: AboutInfo { AppCredits.info() }
    private func credit(_ id: String) throws -> AboutCredit { try XCTUnwrap(info.credits.first { $0.id == id }, id) }
    private func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }

    // MARK: What the licences ask for

    func testTheSpeechModelCreditHasTheFourThingsCCBYAsksFor() throws {
        let model = try credit("parakeet")
        XCTAssertTrue(model.author.contains("NVIDIA"), "who created it")
        XCTAssertEqual(model.licenceURL?.absoluteString, "https://creativecommons.org/licenses/by/4.0/", "the licence, linked")
        XCTAssertTrue(model.licenceName.contains("CC BY 4.0"))
        XCTAssertEqual(model.sourceURL?.absoluteString, "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2", "a link to the material")
        XCTAssertTrue(model.notice.contains("converted to Core ML"), "what was changed")
        XCTAssertTrue(model.notice.contains("change to the original"))
        XCTAssertTrue(model.notice.contains("Creative Commons Attribution 4.0 International"), "the licence is named in full")
    }

    func testTheCoreMLConversionIsCreditedToItsAuthorWithItsLink() throws {
        let conversion = try credit("parakeet-coreml")
        XCTAssertEqual(conversion.author, "FluidInference")
        XCTAssertEqual(conversion.sourceURL?.absoluteString, "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml")
        XCTAssertTrue(conversion.notice.contains("change to the original"))
        XCTAssertTrue(conversion.notice.contains("does not endorse"))
        XCTAssertEqual(conversion.licenceURL, try credit("parakeet").licenceURL)
    }

    func testFluidAudioIsCreditedUnderApache2WithTheLicenceText() throws {
        let library = try credit("fluidaudio")
        XCTAssertEqual(library.licenceName, "Apache License 2.0")
        XCTAssertEqual(library.packageIDs, ["fluidaudio"])
        XCTAssertEqual(library.sourceURL?.absoluteString, "https://github.com/FluidInference/FluidAudio")
        let text = try XCTUnwrap(library.licenceText)
        XCTAssertTrue(text.contains("Apache License"))
        XCTAssertTrue(text.contains("Version 2.0, January 2004"))
        XCTAssertTrue(library.notice.contains("Apache License, Version 2.0"))
    }

    func testWhatFluidAudioItselfContainsIsCreditedWithItsOwnNotices() throws {
        let inside = try credit("fluidaudio-third-party")
        let text = try XCTUnwrap(inside.licenceText)
        for part in ["fastcluster", "text-processing-rs", "rustfst", "Redistributions in binary form must reproduce the above copyright"] {
            XCTAssertTrue(text.contains(part), part)
        }
        XCTAssertEqual(inside.packageIDs, [], "the package itself is credited once, as fluidaudio")
    }

    func testTheSharedPackageIsCreditedUnderMITWithItsCopyrightLine() throws {
        let kit = try credit("parrotkit")
        XCTAssertEqual(kit.packageIDs, ["parrotkit"])
        let text = try XCTUnwrap(kit.licenceText)
        XCTAssertTrue(text.hasPrefix("MIT License"))
        XCTAssertTrue(text.contains("Copyright (c)"))
        XCTAssertTrue(text.contains("Permission is hereby granted"))
    }

    func testEveryCreditCarriesItsLicenceTextFromTheAppBundleAndTheTextIsTheRealOne() throws {
        for credit in info.credits {
            let text = try XCTUnwrap(credit.licenceText, "\(credit.id): the licence text is bundled")
            XCTAssertGreaterThan(text.count, 1000, credit.id)
        }
        let ccBy = try XCTUnwrap(try credit("parakeet").licenceText)
        XCTAssertTrue(ccBy.hasPrefix("Attribution 4.0 International"))
        XCTAssertTrue(ccBy.contains("Section 3 -- License Conditions"))
        for file in ["CC-BY-4.0", "Apache-2.0-FluidAudio", "FluidAudio-ThirdParty", "MIT-ParrotKit"] {
            let onDisk = try read("App/Sources/Licences/\(file).txt")
            XCTAssertEqual(AppCredits.licenceText(file), onDisk, "\(file) in the bundle is the file in git")
        }
    }

    func testAMissingLicenceFileLeavesTheLinkInsteadOfBlankText() {
        XCTAssertNil(AppCredits.licenceText("No-Such-Licence"))
        XCTAssertNil(AppCredits.licenceText("CC-BY-4.0", bundle: Bundle(for: AttributionTests.self)))
    }

    // MARK: The screen

    /// concept: H6
    func testH6TheHelpScreenMountsTheSharedAboutScreenWithThisAppsCredits() throws {
        let source = try read("App/Sources/Views/AboutView.swift")
        XCTAssertTrue(source.contains("AboutInfoView(info: AppCredits.info())"))
        XCTAssertTrue(source.contains(".aboutStrings(AppCredits.strings)"))
        XCTAssertFalse(source.contains("LabeledContent"), "the draft's own rows are gone")
        let build = BuildInfo()
        XCTAssertEqual(info.appVersion, build.version)
        XCTAssertEqual(info.appBuild, build.build)
        XCTAssertEqual(info.kitVersion, ParrotKitInfo.version)
        XCTAssertEqual(info.appName, "Greenfield")
        XCTAssertEqual(info.credits.map(\.id), ["parakeet", "parakeet-coreml", "fluidaudio", "fluidaudio-third-party", "parrotkit"])
    }

    func testTheAboutScreenDrawsWithTheseCreditsInEveryAppearance() {
        func draw<V: View>(_ view: V) {
            let host = UIHostingController(rootView: view)
            host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 800)
            host.view.layoutIfNeeded()
        }
        let screen = NavigationStack { AboutInfoView(info: info) }.aboutStrings(AppCredits.strings)
        draw(screen)
        draw(screen.environment(\.colorScheme, .dark))
        draw(screen.environment(\.dynamicTypeSize, .accessibility5))
    }

    func testTheHonestyLinesNameWhereEachKindOfDataGoes() {
        let lines = AppCredits.strings.onDeviceLines.joined(separator: " ")
        for phrase in ["speech model runs on this phone", "sounds", "Teach", "your own trainer", "only when you press Train",
                       "Text goes only to the computers you chose", "Assist"] {
            XCTAssertTrue(lines.contains(phrase), phrase)
        }
    }

    func testNoCreditCarriesAPathAnAddressOrAnEmail() {
        let all = info.credits.flatMap { [$0.name, $0.author, $0.licenceName, $0.role ?? "", $0.notice] } + info.footnotes
            + AppCredits.strings.onDeviceLines
        for text in all {
            let personal = #"/Users/|/private/|\.ts\.net|@[A-Za-z0-9.-]+\.[a-z]{2,}|\b\d{1,3}(\.\d{1,3}){3}\b"#
            XCTAssertNil(text.range(of: personal, options: .regularExpression), text)
        }
        for url in info.credits.flatMap({ [$0.sourceURL, $0.licenceURL] }).compactMap({ $0 }) {
            XCTAssertTrue(AboutLinks.isSafe(url), url.absoluteString)
        }
    }

    // MARK: Every dependency has a credit

    private func project() throws -> AboutPackages.Project {
        try AboutPackages.project(fromYAML: read("project.yml"), target: "DictationApp")
    }

    func testEveryPackageTheAppShipsHasACredit() throws {
        let project = try project()
        XCTAssertGreaterThanOrEqual(project.declared.count, 4, "the manifest was read")
        XCTAssertTrue(project.linked.contains("fluidaudio") && project.linked.contains("parrotkit"))
        XCTAssertEqual(info.uncredited(project.linked), [], "a package the app links has no credit in AppCredits")
    }

    func testEveryPackageOnlyTheBenchmarkAppUsesIsNamedInTheThirdPartyNotices() throws {
        let project = try project()
        let notices = try read("THIRD_PARTY_NOTICES.md").lowercased()
        let unnamed = project.notLinked.filter { !notices.contains($0) }
        XCTAssertEqual(unnamed.sorted(), [], "a package declared in project.yml is neither credited nor named in THIRD_PARTY_NOTICES.md")
        XCTAssertFalse(project.notLinked.isEmpty, "the benchmark packages were found")
    }

    func testEveryResolvedPinIsCreditedOrNamedWhenThePackageResolvedFileExists() throws {
        let file = root.appendingPathComponent("DictationApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        guard let data = try? Data(contentsOf: file) else { return }
        let notices = try read("THIRD_PARTY_NOTICES.md").lowercased()
        let pinned = AboutPackages.identities(inPackageResolved: data)
        XCTAssertFalse(pinned.isEmpty)
        let missing = info.uncredited(pinned).filter { !notices.contains($0) }
        XCTAssertEqual(missing, [], "pinned in Package.resolved but neither credited nor named in THIRD_PARTY_NOTICES.md")
    }

    func testANewDependencyWithoutACreditFailsTheCheck() throws {
        let declare = "  NewThing:\n    url: https://github.com/someone/new-thing.git\n    from: 1.0.0\n  ParrotKit:\n    path:"
        let link = "    dependencies:\n      - package: FluidAudio\n      - package: NewThing\n      - package: ParrotKit\n"
        let yaml = try read("project.yml")
            .replacingOccurrences(of: "  ParrotKit:\n    path:", with: declare)
            .replacingOccurrences(of: "    dependencies:\n      - package: FluidAudio\n      - package: ParrotKit\n", with: link)
        let added = try AboutPackages.project(fromYAML: yaml, target: "DictationApp")
        XCTAssertTrue(added.linked.contains("new-thing"), "the edit put the dependency into the app target")
        XCTAssertEqual(info.uncredited(added.linked), ["new-thing"])
    }
}
