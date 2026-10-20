import SwiftUI

struct ContentView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            DictateView(model: model).tabItem { Label("Dictate", systemImage: "mic.fill") }
            SoundsView(model: model).tabItem { Label("Sounds", systemImage: "ear") }
            OutboxView(model: model).tabItem { Label("Outbox", systemImage: "tray.full") }
                .badge(model.outbox.pending.count)
            TargetsView(model: model).tabItem { Label("Computers", systemImage: "desktopcomputer") }
            AboutView().tabItem { Label("About", systemImage: "info.circle") }
        }
        .task { await model.session.prepareModel() }
        .task { model.flow.startDetector() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            Task { await model.session.sceneChanged(foreground: phase == .active) }
        }
    }
}
