import ParrotKit
import SwiftUI

/// The Macs this phone can send to. They are found, never typed: Bonjour, the tailnet and the QR code a Mac shows.
struct TargetsView: View {
    let model: AppModel
    @State private var deleting: MacTarget?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        OutboxView(model: model)
                    } label: {
                        HStack {
                            Label("Waiting to send", systemImage: "tray.full")
                            Spacer()
                            if !model.outbox.pending.isEmpty {
                                Text("\(model.outbox.pending.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if model.targets.targets.isEmpty {
                    let description = Text("Computes here on their own: found on this network, over the tailnet, or from a QR code.")
                    ContentUnavailableView("No computers yet", systemImage: "desktopcomputer", description: description)
                }
                ForEach(model.targets.targets) { target in
                    TargetRow(target: target, model: model)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = target }
                        }
                }
                if !model.peers.discovered.isEmpty {
                    Section("Found on your network") {
                        ForEach(model.peers.discovered) { computer in
                            Button {
                                model.peers.add(computer)
                                Task { await model.health.refreshAll() }
                            } label: {
                                Label("\(computer.name)  \(computer.address)", systemImage: "plus.circle")
                            }
                        }
                    }
                }
                TrainerRows(directory: model.trainers)
                Section {
                    Text("""
                    Text goes to exactly one computer: the active one (tap to choose). Computers on your tailnet are trusted by \
                    tailnet identity, so there is nothing to type. They turn up here on their own, over the tailnet or by \
                    scanning the QR code they show. Keep Tailscale on so this phone can reach them.
                    """).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink {
                        AdvancedComputerView(model: model)
                    } label: {
                        Label("Advanced", systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text("Last resort: adding a computer by hand, or clearing something this phone saved for it.")
                }
            }
            .navigationTitle("Computers")
            .confirmationDialog("Delete this computer?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { target in
                Button("Delete \(target.name)", role: .destructive) { model.targets.remove(target.id) }
                Button("Keep it", role: .cancel) { }
            } message: { _ in
                Text("It is taken off this phone and text already sent to it stays there.")
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Check", systemImage: "arrow.clockwise") {
                        Task {
                            await model.health.refreshAll()
                            await model.peers.refresh()
                        }
                    }
                }
            }
            .onAppear { model.peers.startBonjour() }
            .onDisappear { model.peers.stopBonjour() }
            .task {
                while !Task.isCancelled {
                    await model.health.refreshAll()
                    await model.peers.refresh()
                    await model.trainers.refresh()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }
    }
}

/// The trainers found on the tailnet, under the computers: they are found by themselves, so there is nothing to add or edit.
struct TrainerRows: View {
    @ObservedObject var directory: TrainerDirectory

    var body: some View {
        if !directory.trainers.isEmpty {
            Section {
                ForEach(directory.trainers) { trainer in
                    let probe = directory.probe(for: trainer)
                    HStack(spacing: 12) {
                        Circle().fill(probe.health?.compatible == true ? Color.green : Color.orange).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trainer.name).font(.headline)
                            Text(trainer.address).font(.caption).foregroundStyle(.secondary)
                            Text(probe.summary).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Trainer").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Trains models for Sounds > Teach your sounds. Found by itself; nothing to set up here.")
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
                if target.id == model.targets.selectedID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Selected")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Selects this Mac for dictation")
    }
}
