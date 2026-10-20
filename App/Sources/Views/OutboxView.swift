import SwiftUI

/// Every transcript and what became of it, with Resend and Copy.
struct OutboxView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if model.outbox.items.isEmpty {
                    ContentUnavailableView("Nothing yet", systemImage: "tray", description: Text("Transcripts you dictate are kept here."))
                }
                ForEach(model.outbox.items) { item in
                    OutboxRow(item: item, model: model)
                }
            }
            .navigationTitle("Outbox")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Retry all unsent", systemImage: "arrow.clockwise") { Task { await model.delivery.resendAll() } }
                            .disabled(model.outbox.pending.isEmpty)
                        Button("Clear sent", systemImage: "trash", role: .destructive) { model.outbox.clearSent() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }
}

struct OutboxRow: View {
    let item: OutboxItem
    let model: AppModel

    /// The computer this text went to, or will go to: the one it was last sent to, else the active one.
    private var destination: String { item.targetName ?? model.targets.selected?.name ?? "no computer chosen" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text).textSelection(.enabled)
            Label(item.status == .sent ? "Sent to \(destination)" : "For \(destination)", systemImage: "desktopcomputer")
                .font(.footnote).foregroundStyle(.secondary)
            WaitingReason(item: item, sending: model.delivery.inFlight.contains(item.id))
            Text(item.createdAt.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.tertiary)
            if item.status == .pending, !model.delivery.inFlight.contains(item.id) {
                Button("Retry", systemImage: "arrow.clockwise") { model.resend(item.id) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { model.outbox.remove(item.id) }
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.text }
            Button("Retry", systemImage: "arrow.clockwise") { model.resend(item.id) }.disabled(item.status == .sent)
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            Button("Copy") { UIPasteboard.general.string = item.text }
            if item.status == .pending { Button("Retry") { model.resend(item.id) } }
        }
    }
}

/// Why an item is still waiting, in plain words: "The key for this computer is wrong.", "No key is set for mini0."
struct WaitingReason: View {
    let item: OutboxItem
    let sending: Bool

    var body: some View {
        switch item.status {
        case .sent:
            StatusLine(item: item)
        case .pending:
            if sending {
                Label("Sending…", systemImage: "arrow.up.circle").font(.footnote).foregroundStyle(.secondary)
            } else {
                Label(item.lastError ?? "Waiting to be sent.", systemImage: "hourglass").font(.footnote).foregroundStyle(.orange)
            }
        }
    }
}
