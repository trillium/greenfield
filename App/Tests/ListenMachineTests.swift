import XCTest
@testable import DictationApp

final class ListenMachineTests: XCTestCase {
    private var machine = ListenMachine()

    @discardableResult
    private func send(_ event: ListenMachine.Event) -> ListenMachine.Outcome {
        machine.handle(event)
    }

    private func listening() {
        send(.started)
    }

    private func interrupted(_ reason: String = "a call") {
        listening()
        send(.interruptionBegan(reason: reason))
    }

    private func contains(_ outcome: ListenMachine.Outcome, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(outcome.log.contains { $0.contains(text) }, "no log line with \"\(text)\" in \(outcome.log)", file: file, line: line)
    }

    // MARK: Start, stop, scene

    func testStartingTurnsListeningOnAndCancelsAnyResume() {
        let out = send(.started)
        XCTAssertEqual(machine.status, .listening)
        XCTAssertTrue(machine.isCapturing && machine.isWanted)
        XCTAssertEqual(out.actions, [.cancelResume])
        XCTAssertEqual(out.log, ["microphone started (foreground)"])
    }

    func testGoingToTheBackgroundKeepsTheMicrophoneRunning() {
        listening()
        let out = send(.scene(.background))
        XCTAssertEqual(machine.status, .backgrounded)
        XCTAssertTrue(machine.isCapturing)
        XCTAssertEqual(out.actions, [], "backgrounding must not stop or restart the microphone")
        contains(out, "app backgrounded, microphone still running")
    }

    func testComingBackToTheForegroundShowsListeningAgain() {
        listening()
        send(.scene(.background))
        let out = send(.scene(.foreground))
        XCTAssertEqual(machine.status, .listening)
        XCTAssertEqual(out.actions, [])
        contains(out, "app foregrounded, microphone still running")
    }

    func testARepeatedSceneChangeIsIgnored() {
        listening()
        send(.scene(.background))
        let out = send(.scene(.background))
        XCTAssertEqual(out, ListenMachine.Outcome())
    }

    func testStartingInTheBackgroundIsLoggedAsSuch() {
        send(.scene(.background))
        contains(send(.started), "microphone started (background)")
    }

    func testStoppingTurnsEverythingOff() {
        listening()
        let out = send(.stopped)
        XCTAssertEqual(machine.status, .off)
        XCTAssertFalse(machine.isWanted)
        XCTAssertEqual(out.actions, [.cancelResume])
        XCTAssertEqual(out.log, ["microphone stopped"])
        XCTAssertEqual(send(.stopped), ListenMachine.Outcome(), "a second stop says nothing")
    }

    func testTheSceneWhileOffOnlyChangesTheLog() {
        let out = send(.scene(.background))
        XCTAssertEqual(machine.status, .off)
        XCTAssertEqual(out.actions, [])
        contains(out, "microphone off")
    }

    // MARK: Interruptions

    func testAnInterruptionFlushesTheUtteranceAndWaitsForTheSystem() {
        listening()
        send(.scene(.background))
        let out = send(.interruptionBegan(reason: "a call"))
        XCTAssertEqual(machine.status, .interrupted("a call"))
        XCTAssertFalse(machine.isCapturing)
        XCTAssertTrue(machine.isWanted, "the user still wants to listen")
        XCTAssertEqual(out.actions, [.flushUtterance, .cancelResume])
        contains(out, "interrupted: a call (background)")
    }

    func testAnInterruptionWhileOffIsIgnored() {
        XCTAssertEqual(send(.interruptionBegan(reason: "a call")), ListenMachine.Outcome())
        XCTAssertEqual(machine.status, .off)
    }

    func testWhenTheInterruptionEndsItResumesAfterTheFirstBackoff() {
        interrupted()
        let out = send(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(out.actions, [.resume(after: ListenMachine.backoff[0])])
        contains(out, "system says resume")
        XCTAssertEqual(machine.status, .interrupted("a call"), "not listening until the resume works")
    }

    func testItTriesToResumeEvenWhenTheSystemDoesNotSayTo() {
        interrupted("Siri")
        let out = send(.interruptionEnded(shouldResume: false))
        XCTAssertEqual(out.actions, [.resume(after: ListenMachine.backoff[0])])
        contains(out, "do not resume (trying anyway)")
    }

    func testASuccessfulResumeIsListeningAgainAndIsLogged() {
        interrupted()
        send(.scene(.background))
        send(.interruptionEnded(shouldResume: true))
        let out = send(.resumeSucceeded)
        XCTAssertEqual(machine.status, .backgrounded)
        XCTAssertTrue(machine.isCapturing)
        XCTAssertEqual(out.log, ["microphone resumed (background)"])
    }

    func testFailedResumesWalkTheBackoffThenGiveUp() {
        interrupted()
        send(.interruptionEnded(shouldResume: true))
        for attempt in 1..<ListenMachine.backoff.count {
            let out = send(.resumeFailed("busy"))
            XCTAssertEqual(out.actions, [.resume(after: ListenMachine.backoff[attempt])], "after failure \(attempt)")
            contains(out, "resume attempt \(attempt) failed (busy)")
            XCTAssertEqual(machine.status, .interrupted("a call"))
        }
        let last = send(.resumeFailed("busy"))
        XCTAssertEqual(last.actions, [])
        XCTAssertEqual(machine.status, .gaveUp("a call"))
        XCTAssertFalse(machine.isWanted, "a tap now tries again instead of stopping")
        contains(last, "gave up resuming after \(ListenMachine.backoff.count) tries")
    }

    func testTheBackoffGrowsAndIsBounded() {
        XCTAssertEqual(ListenMachine.backoff, ListenMachine.backoff.sorted())
        XCTAssertLessThanOrEqual(ListenMachine.backoff.reduce(0, +), 90, "about a minute of trying, then wait for a trigger")
        XCTAssertGreaterThan(ListenMachine.backoff[0], 0, "never hammer the session the instant the interruption ends")
    }

    func testResumeAfterSomeFailuresReportsTheCount() {
        interrupted()
        send(.interruptionEnded(shouldResume: true))
        send(.resumeFailed("busy"))
        send(.resumeFailed("busy"))
        contains(send(.resumeSucceeded), "microphone resumed after 2 failed tries")
    }

    func testASecondInterruptionStopsTheRetriesAndWaitsForItsEnd() {
        interrupted("a call")
        send(.interruptionEnded(shouldResume: true))
        send(.resumeFailed("busy"))
        let out = send(.interruptionBegan(reason: "Siri"))
        XCTAssertEqual(out.actions, [.cancelResume])
        XCTAssertEqual(machine.status, .interrupted("Siri"))
        XCTAssertEqual(machine.failedAttempts, 0)
    }

    func testAnInterruptionEndingAfterGivingUpStartsOver() {
        interrupted()
        send(.interruptionEnded(shouldResume: true))
        for _ in 0..<ListenMachine.backoff.count { send(.resumeFailed("busy")) }
        XCTAssertEqual(machine.status, .gaveUp("a call"))
        let out = send(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(out.actions, [.resume(after: ListenMachine.backoff[0])])
        XCTAssertEqual(machine.status, .interrupted("a call"))
        XCTAssertEqual(machine.failedAttempts, 0)
    }

    func testAnInterruptionEndWithoutABeginDoesNothing() {
        listening()
        XCTAssertEqual(send(.interruptionEnded(shouldResume: true)), ListenMachine.Outcome())
        XCTAssertEqual(machine.status, .listening)
    }

    // MARK: Recovering without an interruption

    func testOpeningTheAppWhileInterruptedTriesAtOnce() {
        listening()
        send(.scene(.background))
        send(.interruptionBegan(reason: "a call"))
        let out = send(.scene(.foreground))
        XCTAssertEqual(out.actions, [.resume(after: 0)])
        contains(out, "resuming microphone (app opened)")
    }

    func testOpeningTheAppAfterGivingUpTriesAgain() {
        interrupted()
        send(.scene(.background))
        send(.interruptionEnded(shouldResume: true))
        for _ in 0..<ListenMachine.backoff.count { send(.resumeFailed("busy")) }
        let out = send(.scene(.foreground))
        XCTAssertEqual(out.actions, [.resume(after: 0)])
        XCTAssertEqual(machine.status, .interrupted("a call"))
    }

    func testATapAfterGivingUpTriesAgain() {
        interrupted()
        send(.interruptionEnded(shouldResume: true))
        for _ in 0..<ListenMachine.backoff.count { send(.resumeFailed("busy")) }
        XCTAssertEqual(send(.retryRequested).actions, [.resume(after: 0)])
        XCTAssertEqual(machine.failedAttempts, 0)
    }

    func testARetryRequestWhileListeningOrOffDoesNothing() {
        XCTAssertEqual(send(.retryRequested), ListenMachine.Outcome())
        listening()
        XCTAssertEqual(send(.retryRequested), ListenMachine.Outcome())
    }

    func testARouteChangeAfterGivingUpTriesAgainButOtherwiseOnlyLogs() {
        listening()
        let logged = send(.routeChanged(reason: "input or output disconnected"))
        XCTAssertEqual(logged.actions, [])
        contains(logged, "route changed: input or output disconnected")
        interrupted()
        send(.interruptionEnded(shouldResume: true))
        for _ in 0..<ListenMachine.backoff.count { send(.resumeFailed("busy")) }
        XCTAssertEqual(send(.routeChanged(reason: "new input or output connected")).actions, [.resume(after: 0)])
    }

    func testALostEngineResumesAtOnceAndCutsTheUtterance() {
        listening()
        let out = send(.captureLost(reason: "audio route or format changed"))
        XCTAssertEqual(out.actions, [.flushUtterance, .resume(after: 0)])
        XCTAssertEqual(machine.status, .interrupted("audio route or format changed"))
        send(.resumeSucceeded)
        XCTAssertEqual(machine.status, .listening)
    }

    func testALostEngineDuringAnInterruptionIsLeftToTheInterruption() {
        interrupted()
        XCTAssertEqual(send(.captureLost(reason: "audio route or format changed")), ListenMachine.Outcome())
        XCTAssertEqual(machine.status, .interrupted("a call"))
    }

    // MARK: Stopping mid-recovery

    func testStoppingWhileInterruptedCancelsTheResumeAndLateResultsAreIgnored() {
        interrupted()
        send(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(send(.stopped).actions, [.cancelResume])
        XCTAssertEqual(send(.resumeSucceeded), ListenMachine.Outcome())
        XCTAssertEqual(send(.resumeFailed("late")), ListenMachine.Outcome())
        XCTAssertEqual(machine.status, .off)
    }

    // MARK: Status

    func testStatusReflectsModeAndScene() {
        XCTAssertEqual(machine.status, .off)
        listening()
        XCTAssertEqual(machine.status, .listening)
        send(.scene(.background))
        XCTAssertEqual(machine.status, .backgrounded)
        send(.interruptionBegan(reason: "a call"))
        XCTAssertEqual(machine.status, .interrupted("a call"), "interrupted outranks backgrounded")
    }
}
