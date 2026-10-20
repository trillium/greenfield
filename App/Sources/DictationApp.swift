import SwiftUI

@main
struct DictationApp: App {
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await SelfTest.runIfRequested(model) }
        }
    }
}
