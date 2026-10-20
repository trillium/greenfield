import SwiftUI
import UniformTypeIdentifiers

/// The detector: which model is loaded, every sound it recognises as it happens, the rules, and model packs.
struct SoundsView: View {
    let model: AppModel
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        let flow = model.flow
        NavigationStack {
            List {
                Section("Detector") {
                    LabeledContent("State", value: flow.state.title)
                    LabeledContent("Model", value: flow.modelName.isEmpty ? "Not loaded" : flow.modelName)
                    if let problem = flow.detectorProblem { Text(problem).font(.footnote).foregroundStyle(.red) }
                    if !flow.detectorLabels.isEmpty {
                        Text(flow.detectorLabels.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Rules") {
                    NavigationLink("Edit rules (\(flow.rules.count))") { RulesView(flow: flow) }
                    ForEach(flow.rules.filter(\.enabled)) { Text($0.summary + " (\($0.action.title))").font(.footnote) }
                }
                Section("Model packs") {
                    ModelPackList(model: model, message: $message)
                    Button("Import a model pack…", systemImage: "square.and.arrow.down") { importing = true }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
                Section("Sounds heard") {
                    if flow.recentSounds.isEmpty { Text("Make a sound near the microphone.").foregroundStyle(.secondary) }
                    ForEach(flow.recentSounds) { SoundRow(sound: $0) }
                }
            }
            .navigationTitle("Sounds")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in importPack(result) }
        }
    }

    private func importPack(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let entry = try model.flow.models.install(Data(contentsOf: url))
            message = "Installed and switched to \(entry.name)."
        } catch {
            message = "Not installed: \(error)"
        }
    }
}

struct SoundRow: View {
    let sound: FlowController.HeardSound

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(sound.event.pattern).font(.headline)
                Spacer()
                Text("\(Int((sound.event.probability * 100).rounded()))%").font(.subheadline.monospacedDigit())
            }
            Text("\(sound.event.topClass), power \(Int(sound.event.power)), \(sound.heardAt.formatted(date: .omitted, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
            if let rule = sound.firedRule { Label("Fired: \(rule)", systemImage: "bolt.fill").font(.caption).foregroundStyle(.orange) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ModelPackList: View {
    let model: AppModel
    @Binding var message: String?
    @State private var refresh = 0

    var body: some View {
        let store = model.flow.models
        let entries = store.list()
        let active = store.activeID
        Group {
            Button { choose(nil) } label: {
                Label(ParrotModelStore.bundledName, systemImage: active == nil ? "checkmark.circle.fill" : "circle")
            }
            ForEach(entries) { entry in
                Button { choose(entry.id) } label: {
                    Label(entry.name, systemImage: active == entry.id ? "checkmark.circle.fill" : "circle")
                }
                .swipeActions { Button("Remove", role: .destructive) { remove(entry.id) } }
            }
        }
        .id(refresh)
    }

    private func choose(_ id: String?) {
        do { try model.flow.models.activate(id) } catch { message = "\(error)" }
        refresh += 1
    }

    private func remove(_ id: String) {
        do { try model.flow.models.remove(id) } catch { message = "\(error)" }
        refresh += 1
    }
}
