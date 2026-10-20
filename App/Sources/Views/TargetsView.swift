import SwiftUI

/// The Macs on the tailnet the phone can send to: add, edit, remove, test, choose.
struct TargetsView: View {
    let model: AppModel
    @State private var editing: MacTarget?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                if model.targets.targets.isEmpty {
                    ContentUnavailableView("No computers yet", systemImage: "desktopcomputer",
                                           description: Text("Add the tailnet name or address of a computer that runs the input agent."))
                }
                ForEach(model.targets.targets) { target in
                    TargetRow(target: target, model: model)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) { model.targets.remove(target.id) }
                            Button("Edit", systemImage: "pencil") { editing = target }.tint(.blue)
                        }
                }
                Section {
                    Text("""
                    Text goes to exactly one computer: the active one (tap to choose). Computers on your tailnet are trusted by \
                    tailnet identity, so there is no key to type. Use the tailnet name \
                    (for example macbook.your-tailnet.ts.net), a short name, or the 100.x address, optionally with :port \
                    (default 47821). The phone must be connected to the tailnet (Tailscale on).
                    """).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Computers")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add a computer", systemImage: "plus") { adding = true }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Check", systemImage: "arrow.clockwise") { Task { await model.health.refreshAll() } }
                }
            }
            .sheet(isPresented: $adding) { TargetEditView(model: model, target: nil) }
            .sheet(item: $editing) { TargetEditView(model: model, target: $0) }
            .task {
                while !Task.isCancelled {
                    await model.health.refreshAll()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }
    }
}

struct TargetRow: View {
    let target: MacTarget
    let model: AppModel

    var body: some View {
        let state = model.health.state(for: target)
        Button {
            model.targets.select(target.id)
        } label: {
            HStack(spacing: 12) {
                HealthDot(state: state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name).font(.headline).foregroundStyle(.primary)
                    Text(target.address).font(.caption).foregroundStyle(.secondary)
                    Text(state.summary).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if target.id == model.targets.selectedID { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Selects this Mac for dictation")
    }
}

struct TargetEditView: View {
    let model: AppModel
    let target: MacTarget?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var key = ""
    @State private var testResult: String?
    @State private var failure: String?

    private var draft: MacTarget { MacTarget(id: target?.id ?? UUID(), name: name, address: address) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Computer") {
                    TextField("Name", text: $name)
                    TextField("Tailnet name or address", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    if draft.baseURL == nil, !address.isEmpty {
                        Text("Use a name such as mini0.your-tailnet.ts.net, a short name, or a 100.x address, optionally with :port.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                Section {
                    DisclosureGroup("Advanced") {
                        SecureField(target == nil ? "Key (only if it asks for one)" : "Key (empty keeps the saved one)", text: $key)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if let target, model.targets.key(for: target) != nil {
                            Button("Remove the saved key", role: .destructive) { removeKey(target) }
                        }
                        Text("Computers on your tailnet are trusted by tailnet identity, so no key is needed. Add one only if this "
                             + "computer's agent asks for it. It is kept in the iPhone Keychain, on this phone only.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Test connection") { Task { await test() } }.disabled(!draft.isValid)
                    if let testResult { Text(testResult).font(.footnote) }
                    if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle(target == nil ? "Add a computer" : "Edit computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!draft.isValid) }
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
        case .wrongKey: "Reachable, but it asks for a key. Add one under Advanced."
        case .keyNotSetOnMac: "Reachable, but its input agent is not set up yet."
        case .incompatible(let message), .unreachable(let message): message
        }
    }
}
