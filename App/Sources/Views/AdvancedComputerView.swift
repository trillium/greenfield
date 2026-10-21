import KitUI
import SwiftUI

/// The one place in the app that asks a person to type, reached from the "Advanced" row on the Computers tab.
/// The normal flow never comes here: computers turn up on their own over Bonjour, over the tailnet or from a QR code.
struct AdvancedComputerView: View {
    let model: AppModel
    @State private var adding = false

    var body: some View {
        List {
            Section("Computers you added by hand") {
                if model.targets.targets.isEmpty {
                    Text("Nothing here yet. Computers this phone finds on its own are added without typing.").font(.footnote)
                }
                ForEach(model.targets.targets) { target in
                    NavigationLink {
                        AdvancedComputerEditView(model: model, target: target)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(target.name)
                            Text(target.address).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button("Add a computer by typing it", systemImage: "plus") { adding = true }
            } footer: {
                Text("Most people never need this. If a computer cannot be found by itself, type it once here.")
            }
            Section {
                Text("Computers on your tailnet are trusted by tailnet identity, so no key is needed. Add one only if this "
                     + "computer's agent asks for it. It is kept in the iPhone Keychain, on this phone only.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Advanced")
        .sheet(isPresented: $adding) { AdvancedComputerEditView(model: model, target: nil) }
    }
}

/// Typing form for one computer: its name, where to reach it and, only if its agent asks, a key.
struct AdvancedComputerEditView: View {
    let model: AppModel
    let target: MacTarget?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var key = ""
    @State private var testResult: String?
    @State private var failure: String?
    @State private var confirmRemoveKey = false

    private var draft: MacTarget { MacTarget(id: target?.id ?? UUID(), name: name, address: address) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Computer") {
                    TextField("Name", text: $name)
                    TextField("Tailnet name or address", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    if draft.baseURL == nil, !address.isEmpty {
                        Label("Warning: use a name such as mini0.your-tailnet.ts.net, a short name, or a 100.x address, "
                              + "optionally with :port.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(KitTokens.Status.warning)
                    }
                }
                Section("Key") {
                    SecureField(target == nil ? "Key (only if it asks for one)" : "Key (empty keeps the saved one)", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if let target, model.targets.key(for: target) != nil {
                        Button("Remove the saved key", role: .destructive) { confirmRemoveKey = true }
                    }
                    Text("Computers on your tailnet are trusted by tailnet identity, so no key is needed. Add one only if this "
                         + "computer's agent asks for it. It is kept in the iPhone Keychain, on this phone only.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Test connection") { Task { await test() } }.disabled(!draft.isValid)
                    if let testResult { Text(testResult).font(.footnote) }
                    if let failure {
                        Label("Error: \(failure)", systemImage: "xmark.octagon.fill")
                            .font(.footnote).foregroundStyle(KitTokens.Status.problem)
                    }
                }
            }
            .navigationTitle(target == nil ? "Add a computer" : "Edit computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!draft.isValid) }
            }
            .confirmationDialog("Remove the saved key?", isPresented: $confirmRemoveKey, titleVisibility: .visible) {
                Button("Remove the key", role: .destructive) { if let target { removeKey(target) } }
                Button("Keep the key", role: .cancel) { }
            } message: {
                Text("Text can no longer be sent to this computer until its agent asks for a key again.")
            }
            .onAppear {
                guard let target else { return }
                name = target.name
                address = target.address
            }
        }
    }

    private func removeKey(_ target: MacTarget) {
        try? model.targets.save(target, key: "")
        Task { await model.health.refresh(target) }
        testResult = "Saved key removed."
    }

    private func save() {
        do {
            try model.targets.save(draft, key: key.isEmpty ? nil : key)
            Task { await model.health.refresh(draft) }
            dismiss()
        } catch {
            failure = "The key could not be saved: \(error)"
        }
    }

    private func test() async {
        testResult = "Checking…"
        let candidate = draft
        let health = await model.delivery.health(of: candidate, key: key.isEmpty ? nil : key)
        testResult = switch health {
        case .ready(let status):
            TargetHealth.state(from: .ready(status)).summary + (status.name.isEmpty ? "" : ": \(status.name)")
        case .wrongKey: "Reachable, but it asks for a key. Remove the saved one here, or update its agent."
        case .keyNotSetOnMac: "Reachable, but its input agent is not set up yet."
        case .incompatible(let message), .unreachable(let message): message
        }
    }
}
