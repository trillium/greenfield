import KitOnboarding
import KitUI
import SwiftUI

/// The first-launch checklist: what is set up, what is not, and one tap to fix each. Also reachable later from Help. The list, its rows and
/// the "Am I ready?" line are the shared KitUI ones; the steps are this app's (`AppOnboarding`).
struct OnboardingView: View {
    let model: AppModel
    let finish: () -> Void
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                OnboardingChecklistView(items: model.checklist(), intro: "Greenfield sets itself up. Tap each fix, top to bottom.",
                                        perform: { await model.perform($0) }, finish: finish, extra: {
                    Section("Your computer") {
                        Button("Scan the computer's code", systemImage: "qrcode.viewfinder") { scanning = true }
                        Text("The installer on the computer shows a code. Scanning it adds the computer with no typing. Computers on your "
                             + "tailnet and network are also found by themselves.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Then try it") {
                        NavigationLink("Guided first dictation: say hello, then send it") { GuidedDictationView(model: model) }
                    }
                })
            }
            .sheet(isPresented: $scanning) { ScanComputerView(model: model) }
            .task {
                model.peers.startBonjour()
                await model.session.startListening()
                while !Task.isCancelled {
                    await model.health.refreshAll()
                    await model.peers.refresh()
                    model.peers.chooseTheOnlyComputer(health: model.health)
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }
}

/// "Say hello, then say send it" with a visible result and a plain pass or fail (the shared `GuidedRunView` over this app's pipeline).
struct GuidedDictationView: View {
    let model: AppModel
    @StateObject private var run: GuidedRun

    init(model: AppModel) {
        self.model = model
        _run = StateObject(wrappedValue: GuidedRun(steps: GuidedDictationSteps(flow: model.flow, delivery: model.delivery),
                                                   strings: GuidedDictationSteps.strings))
    }

    var body: some View {
        GuidedRunView(run: run, headline: "Say hello, then say send it.",
                      explanation: "This sends the word hello to \(run.destinationName), as a real dictation, so you see the whole "
                          + "path work.")
    }
}

/// One line on the main screen: ready, or exactly one next step. Tap it to open the checklist.
struct ReadyLineView: View {
    let model: AppModel
    @State private var showing = false

    var body: some View {
        ReadyLineButton(line: model.readiness()) { showing = true }
            .sheet(isPresented: $showing) { OnboardingView(model: model) { showing = false } }
    }
}
