import KitHealth
import KitUI
import SwiftUI

struct AboutView: View {
    let model: AppModel
    var log: EventLog { model.log }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Version", value: BuildInfo().display)
                    LabeledContent("Speech model", value: ModelInfo.modelName)
                    LabeledContent("Where it runs", value: "On this phone")
                }
                Section("Support") {
                    NavigationLink("Get ready: the setup checklist") { OnboardingView(model: model) {} }
                    NavigationLink("Health: is everything set up?") { HealthView(model: model) }
                    NavigationLink("Diagnostics: recent events") { SupportDiagnosticsView(log: log, support: model.support) }
                }
                Section("Licences") {
                    NavigationLink("Attribution") { AttributionView() }
                }
                Section {
                    Text("Dictation audio never leaves the phone. Only the text is sent, to the Mac you choose. "
                         + "Sounds you record under Teach go only to your own trainer, and only when you press Train.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("About")
        }
    }
}

/// Credit for the speech model and the libraries, as the licences require.
struct AttributionView: View {
    var body: some View {
        List {
            Section("Speech model") {
                Text(ModelInfo.modelNotice).font(.callout)
                Link("Model on Hugging Face", destination: ModelInfo.modelSourceURL)
                Link("Core ML conversion by \(ModelInfo.convertedBy)", destination: ModelInfo.convertedURL)
                Link(ModelInfo.modelLicenceName, destination: ModelInfo.modelLicenceURL)
            }
            Section("Software") {
                ForEach(ModelInfo.credits) { credit in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(credit.name).font(.headline)
                        Text(credit.role).font(.footnote).foregroundStyle(.secondary)
                        Link(credit.licence, destination: credit.link).font(.footnote)
                    }
                }
            }
            Section {
                Text("This app's own code is released under the MIT License. NVIDIA and the other names above belong to their owners; "
                     + "they do not endorse this app.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Attribution")
    }
}
