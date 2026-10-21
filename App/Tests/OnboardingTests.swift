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
