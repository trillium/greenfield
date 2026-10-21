import KitUI
import SwiftUI

struct ContentView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboarding.done") private var onboarded = false

    var body: some View {
        TabView {
            DictateView(model: model).tabItem { Label("Dictate", systemImage: "mic.fill") }
            SoundsView(model: model).tabItem { Label("Sounds", systemImage: "ear") }
            AssistTabView(model: model).tabItem { Label("Assist", systemImage: "cursorarrow.motionlines") }
            // The outbox is a screen inside Computers ("Waiting to send"); its count rides on the tab so a waiting text is still seen.
            TargetsView(model: model).tabItem { Label("Computers", systemImage: "desktopcomputer") }
                .badge(model.outbox.pending.count)
            AboutView(model: model).tabItem { Label("Help", systemImage: "stethoscope") }
        }
        // The stock accent is too light to read as text on the page; the kit's accent reaches 4.5:1.
        .tint(KitTokens.Status.accent)
        .task { await model.session.prepareModel() }
        .task { model.flow.startDetector() }
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { _ in })) {
            OnboardingView(model: model) { onboarded = true }
        }
        .task { model.retry.start() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            Task { await model.session.sceneChanged(foreground: phase == .active) }
        }
    }
}
