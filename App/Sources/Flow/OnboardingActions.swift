import AVFoundation
import Foundation
import UIKit

/// What the one-tap fixes do, and the facts the checklist is built from.
@MainActor
extension AppModel {
    func onboardingInputs() -> OnboardingInputs {
        var input = OnboardingInputs()
        switch AVAudioApplication.shared.recordPermission {
        case .granted: input.microphone = .granted
        case .denied: input.microphone = .denied
        default: input.microphone = .undetermined
        }
        input.localNetwork = peers.localNetwork
        input.tailnetConnected = Tailnet.isConnected()
        input.speechModel = session.model
        input.detectorListening = flow.isListening
        input.detectorProblem = flow.detectorProblem
        input.computers = targets.targets.count
        input.readyComputers = targets.targets.filter { target in
            if case .ready = health.state(for: target) { return true }
            return false
        }.count
        input.hasChosenComputer = targets.selected.map { target in
            if case .ready = health.state(for: target) { return true }
            return false
        } ?? false
        return input
    }

    func checklist() -> [OnboardingItem] { Onboarding.checklist(onboardingInputs()) }

    /// The "Am I ready?" line: ready, or exactly one next step. The checklist comes first; once it is complete, a real problem
    /// that Health knows about (a computer that is locked, needs approval, is out of date) is the next step.
    func readiness() -> (ready: Bool, text: String) {
        let line = Onboarding.readyLine(onboardingInputs())
        guard line.ready else { return line }
        if let problem = healthReport().first(where: { $0.level == .problem }), let fix = problem.fix {
            return (false, "Next step: \(fix) (\(problem.title))")
        }
        return line
    }

    func perform(_ fix: OnboardingFix) async {
        switch fix {
        case .allowMicrophone:
            _ = await AudioCapture.requestPermission()
            await session.startListening()
        case .allowLocalNetwork:
            peers.startBonjour()
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
        case .openTailscale:
            if let url = URL(string: "tailscale://") { await UIApplication.shared.open(url) }
        case .downloadModel:
            await session.prepareModel()
        case .restartDetector:
            flow.startDetector()
        case .findComputers:
            peers.startBonjour()
            await health.refreshAll()
            await peers.refresh()
            peers.chooseTheOnlyComputer(health: health)
        }
    }
}
