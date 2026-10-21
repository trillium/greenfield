import KitUI
import ParrotKit
import ParrotKitUI
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
                Section {
                    NavigationLink {
                        TeachView(model: model.teach)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Teach your sounds").font(.headline)
                            Text("Record the sounds you want to use; your own trainer makes a model for them.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("teachLink")
                    .accessibilityHint("Opens the teach screen")
                    NavigationLink {
                        LevelsScreen(flow: flow)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Levels").font(.headline)
                            Text("How loud each sound has to be to fire, and how sensitive the microphone is.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("levelsLink")
                    .accessibilityHint("Opens the levels screen")
                }
                Section("Detector") {
                    LabeledContent("State", value: flow.state.title)
                    LabeledContent("Model", value: flow.modelName.isEmpty ? "Not loaded" : flow.modelName)
                    if let problem = flow.detectorProblem {
                        Label("Error: \(problem)", systemImage: "xmark.octagon.fill")
                            .font(.footnote).foregroundStyle(KitTokens.Status.problem)
                    }
                    if !flow.detectorLabels.isEmpty {
                        Text(flow.detectorLabels.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Rules") {
                    NavigationLink("Edit rules (\(flow.rules.count))") { RulesView(flow: flow) }
                        .accessibilityHint("Opens the rules list")
                    ForEach(flow.rules.filter(\.enabled)) { Text($0.summary + " (\($0.action.title))").font(.footnote) }
                }
                Section {
                    PhraseList(flow: flow)
                } header: {
                    Text("Spoken line-enders").accessibilityAddTraits(.isHeader)
                } footer: {
                    Text("Saying one of these at the very end of what you dictate ends dictation and submits the text, without "
                         + "the phrase. Matched on the last words only, ignoring case. A sentence that really ends with the phrase "
                         + "will submit.")
                }
                Section("Model packs") {
                    ModelPackList(model: model, message: $message)
                    Button("Import a model pack…", systemImage: "square.and.arrow.down") { importing = true }
                        .accessibilityHint("Choose a model pack file to add")
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
            let entry = try model.flow.models.install(contentsOf: url)
            message = "Installed and switched to \(entry.name)."
        } catch {
            message = "Not installed: \(error)"
        }
    }
}

struct SoundRow: View {
    let sound: FlowController.HeardSound
    /// Adapt the row to Dynamic Type: at accessibility sizes the pattern wraps instead of clipping
    /// the percentage, since the HStack reserves width for the trailing value.
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(sound.event.pattern).font(.headline)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                Spacer()
                Text("\(Int((sound.event.probability * 100).rounded()))%").font(.subheadline.monospacedDigit())
            }
            Text("\(sound.event.topClass), power \(Int(sound.event.power)), \(sound.heardAt.formatted(date: .omitted, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
            if let rule = sound.firedRule {
                Label("Warning: fired rule \(rule)", systemImage: "bolt.fill")
                    .font(.caption).foregroundStyle(KitTokens.Status.warning)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ModelPackList: View {
    let model: AppModel
    @Binding var message: String?
    @State private var refresh = 0
    @State private var removingID: String?

    var body: some View {
        let store = model.flow.models
        let entries = store.list()
        let active = store.inUseID
        Group {
            Button { choose(nil) } label: {
                Label(store.bundledName, systemImage: active == nil ? "checkmark.circle.fill" : "circle")
            }
            .accessibilityHint("Switches to the bundled model on this phone")
            ForEach(entries) { entry in
                Button { choose(entry.id) } label: {
                    Label(entry.name, systemImage: active == entry.id ? "checkmark.circle.fill" : "circle")
                }
                .accessibilityHint("Switches to this model")
                .swipeActions { Button("Remove", role: .destructive) { removingID = entry.id } }
            }
        }
        .id(refresh)
        .confirmationDialog("Remove this model pack?", isPresented: removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let id = removingID { remove(id) } }
            Button("Keep it", role: .cancel) { }
        } message: {
            Text("The pack is taken off this phone. You can install it again later.")
        }
    }

    private var removing: Binding<Bool> {
        Binding(get: { removingID != nil }, set: { if !$0 { removingID = nil } })
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

/// The spoken line-ender phrases: switch on and off, edit, add, remove.
struct PhraseList: View {
    let flow: FlowController
    @State private var phrases: [PhraseStore.Phrase] = []
    @State private var confirmReset = false

    var body: some View {
        Group {
            ForEach($phrases) { $phrase in
                VStack(alignment: .leading) {
                    WordToggle(title: phrase.text.isEmpty ? "New phrase" : phrase.text, isOn: $phrase.enabled)
                        .accessibilityHint("Switches this line-ender on or off")
                    TextField("Phrase", text: $phrase.text).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            .onDelete { phrases.remove(atOffsets: $0) }
            Button("Add a phrase", systemImage: "plus") { phrases.append(PhraseStore.Phrase(text: "")) }
                .accessibilityHint("Adds a new line-ender phrase")
            Button("Reset to defaults", systemImage: "arrow.counterclockwise", role: .destructive) { confirmReset = true }
                .accessibilityHint("Resets the line-enders to the factory defaults")
        }
        .onAppear { phrases = flow.phrases }
        .onChange(of: phrases) { _, new in flow.setPhrases(new) }
        .confirmationDialog("Reset the line-enders to their defaults?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset to defaults", role: .destructive) { phrases = PhraseStore.defaults }
            Button("Keep my phrases", role: .cancel) { }
        } message: {
            Text("This replaces the \(phrases.count) phrases listed here with the factory defaults. It cannot be undone.")
        }
    }
}
