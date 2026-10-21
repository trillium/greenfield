import KitHealth
import KitUI
import SwiftUI

/// Help: the shared About screen (version, what runs on this phone, credits and licences) with this app's setup and support links.
struct AboutView: View {
    let model: AppModel
    var log: EventLog { model.log }

    var body: some View {
        NavigationStack {
            AboutInfoView(info: AppCredits.info()) {
                Section {
                    NavigationLink("Get ready: the setup checklist") { OnboardingView(model: model) {} }
                    NavigationLink("Health: is everything set up?") { HealthView(model: model) }
                    NavigationLink("Diagnostics: recent events") { SupportDiagnosticsView(log: log, support: model.support) }
                } header: {
                    Text("Support")
                }
            }
            .aboutStrings(AppCredits.strings)
        }
    }
}
