import XCTest
@testable import DictationApp

final class OnboardingTests: XCTestCase {
    private func ready() -> OnboardingInputs {
        var input = OnboardingInputs()
        input.microphone = .granted
        input.localNetwork = .granted
        input.tailnetConnected = true
        input.speechModel = .ready
        input.detectorListening = true
        input.computers = 1
        input.readyComputers = 1
        input.hasChosenComputer = true
        return input
    }

    /// Everything that can go wrong at once: every fix should still be one tap.
    private func blocked() -> OnboardingInputs {
        var input = ready()
        input.microphone = .denied
        input.localNetwork = .denied
        input.tailnetConnected = false
        input.speechModel = .failed("the download stopped")
        input.detectorListening = false
        input.detectorProblem = "the microphone is busy"
        input.computers = 0
        input.readyComputers = 0
        input.hasChosenComputer = false
        return input
    }

    /// Half done: the first three are fine, the rest is not.
    private func partway() -> OnboardingInputs {
        var input = ready()
        input.speechModel = .notLoaded
        input.detectorListening = false
        return input
    }

    func testEverythingDoneIsReady() {
        XCTAssertTrue(Onboarding.checklist(ready()).allSatisfy(\.isDone))
        XCTAssertTrue(Onboarding.readyLine(ready()).ready)
    }

    func testTheReadyLineNamesExactlyOneNextStepInOrder() {
        var input = ready()
        input.tailnetConnected = false
        input.speechModel = .downloading(0.5)
        let line = Onboarding.readyLine(input)
        XCTAssertFalse(line.ready)
        XCTAssertTrue(line.text.contains("Tailscale"), line.text)
        XCTAssertFalse(line.text.contains("Speech model"), "only the first step is shown")
    }

    func testEveryNotDoneItemOffersAFixExceptWhileWorking() {
        var input = OnboardingInputs()
        input.microphone = .denied
        input.speechModel = .downloading(0.2)
        for item in Onboarding.checklist(input) where !item.isDone {
            if case .working = item.state { continue }
            XCTAssertNotNil(item.fix, item.title)
            XCTAssertNotNil(item.fixLabel, item.title)
        }
        XCTAssertEqual(Onboarding.checklist(input).first?.fix, .openSettings, "a denied microphone goes to Settings")
    }

    func testTheModelItemShowsProgress() {
        var input = ready()
        input.speechModel = .downloading(0.42)
        let item = Onboarding.checklist(input).first { $0.id == "speech" }
        XCTAssertEqual(item?.state, .working(0.42))
        XCTAssertTrue(item?.detail.contains("42%") ?? false)
    }

    func testLocalNetworkPermissionIsReadFromTheBrowserState() {
        XCTAssertEqual(PeerDirectory.permission(for: .ready), .granted)
        XCTAssertEqual(PeerDirectory.permission(for: .waiting(.dns(-65_570))), .denied)
        XCTAssertNil(PeerDirectory.permission(for: .waiting(.dns(-1))))
    }

    func testTheChecklistOrderIsTheOrderANewPersonMeetsTheProblems() {
        XCTAssertEqual(Onboarding.checklist(OnboardingInputs()).map(\.id),
                       ["microphone", "localnetwork", "tailscale", "speech", "detector", "computer"])
    }

    func testEveryItemHasItsOwnNameAndSomethingToRead() {
        let items = Onboarding.checklist(OnboardingInputs())
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "two items share an id")
        for item in items {
            XCTAssertFalse(item.title.isEmpty, item.id)
            XCTAssertFalse(item.detail.isEmpty, item.id)
        }
        XCTAssertEqual(Set(items.map(\.title)).count, items.count, "two items share a title")
    }

    func testANewPhoneHasNothingDoneYet() {
        let items = Onboarding.checklist(OnboardingInputs())
        XCTAssertFalse(items.contains(where: \.isDone))
        XCTAssertFalse(Onboarding.readyLine(OnboardingInputs()).ready)
    }

    func testNoChecklistFixEverAsksThePersonToType() {
        let variants: [OnboardingInputs] = [OnboardingInputs(),
                                           ready(),
                                           blocked()]
        for input in variants {
            for item in Onboarding.checklist(input) {
                guard let label = item.fixLabel else { continue }
                let words = ["type", "typing", "enter", "paste", "key", "address", "name it"]
                for word in words {
                    XCTAssertFalse(label.lowercased().contains(word), "\(item.id): \(label)")
                }
            }
        }
    }

    func testABlockedMicrophoneAndLocalNetworkBothPointAtSettings() {
        var input = ready()
        input.microphone = .denied
        input.localNetwork = .denied
        let items = Onboarding.checklist(input)
        XCTAssertEqual(items.first { $0.id == "microphone" }?.state, .blocked)
        XCTAssertEqual(items.first { $0.id == "microphone" }?.fix, .openSettings)
        XCTAssertEqual(items.first { $0.id == "localnetwork" }?.state, .blocked)
        XCTAssertEqual(items.first { $0.id == "localnetwork" }?.fix, .openSettings)
    }

    func testAFailedModelIsBlockedAndOffersTheDownloadAgain() {
        var input = ready()
        input.speechModel = .failed("no room on the phone")
        let item = Onboarding.checklist(input).first { $0.id == "speech" }
        XCTAssertEqual(item?.state, .blocked)
        XCTAssertEqual(item?.fix, .downloadModel)
        XCTAssertTrue(item?.detail.contains("no room on the phone") ?? false, item?.detail ?? "")
    }

    func testADetectorThatCouldNotStartIsBlockedAndOffersARestart() {
        var input = ready()
        input.detectorListening = false
        input.detectorProblem = "the microphone is busy"
        let item = Onboarding.checklist(input).first { $0.id == "detector" }
        XCTAssertEqual(item?.state, .blocked)
        XCTAssertEqual(item?.fix, .restartDetector)
        XCTAssertTrue(item?.detail.contains("the microphone is busy") ?? false, item?.detail ?? "")
    }

    func testComputersAreLookedForByThemselvesAndNeverTyped() {
        var none = ready()
        none.computers = 0
        none.readyComputers = 0
        none.hasChosenComputer = false
        let empty = Onboarding.checklist(none).first { $0.id == "computer" }
        XCTAssertEqual(empty?.fix, .findComputers)

        var waiting = none
        waiting.computers = 2
        let listed = Onboarding.checklist(waiting).first { $0.id == "computer" }
        XCTAssertEqual(listed?.fix, .findComputers)
        XCTAssertNotEqual(listed?.detail, empty?.detail, "the line should say what is different")
    }

    func testTheReadyLineSaysReadyOnlyWhenEveryItemIsDone() {
        for input in [OnboardingInputs(), ready(), blocked()] {
            let line = Onboarding.readyLine(input)
            XCTAssertEqual(line.ready, Onboarding.checklist(input).allSatisfy(\.isDone), line.text)
        }
    }

    func testTheReadyLineWhenReadySaysWhatToSay() {
        let line = Onboarding.readyLine(ready())
        XCTAssertTrue(line.ready)
        XCTAssertTrue(line.text.contains("kitty-cmere"), line.text)
    }

    func testTheReadyLineNamesTheFirstUndoneItemAndNothingElse() {
        let input = blocked()
        let step = Onboarding.nextStep(input)
        let line = Onboarding.readyLine(input)
        XCTAssertEqual(step?.id, "microphone", "the first problem comes first")
        XCTAssertTrue(line.text.hasPrefix("Next step: "), line.text)
        XCTAssertTrue(line.text.contains(step?.fixLabel ?? ""), line.text)
        for other in Onboarding.checklist(input).filter({ $0.id != step?.id && !$0.isDone }).compactMap(\.fixLabel) {
            XCTAssertFalse(line.text.contains(other), "the line names a second step: \(other)")
        }
    }

    func testTheNextStepIsAlwaysTheFirstUndoneItem() {
        for input in [OnboardingInputs(), ready(), blocked(), partway()] {
            XCTAssertEqual(Onboarding.nextStep(input)?.id,
                           Onboarding.checklist(input).first { !$0.isDone }?.id)
        }
    }

    func testTheChecklistNeverGrowsOrShrinksWithTheState() {
        XCTAssertEqual(Onboarding.checklist(OnboardingInputs()).count, 6)
        XCTAssertEqual(Onboarding.checklist(ready()).count, 6)
        XCTAssertEqual(Onboarding.checklist(blocked()).count, 6)
        XCTAssertEqual(Onboarding.checklist(partway()).count, 6)
    }

    @MainActor
    func testASingleDiscoveredComputerIsAddedAndChosenWhenTheListIsEmpty() {
        let store = TargetStore(defaults: isolatedDefaults(), keys: MemoryKeyStore())
        let client = ReceiverClient(session: StubURLProtocol.session(), tailnetConnected: { true })
        let service = DeliveryService(outbox: Outbox(url: nil), targets: store, client: client)
        let peers = PeerDirectory(service: service)
        peers.bonjourFound(["Desk Mac"])
        let chosen = peers.chooseTheOnlyComputer(health: TargetHealth(service: service))
        XCTAssertEqual(chosen?.name, "Desk Mac")
        XCTAssertEqual(store.selected?.name, "Desk Mac")
    }
}
