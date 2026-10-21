import KitUI
import SwiftUI

/// Every transcript and what became of it, with Resend and Copy. A screen of the Computers tab ("Waiting to send").
struct OutboxView: View {
    let model: AppModel
    @State private var confirmClearSent = false

    var body: some View {
        List {
            if !model.outbox.pending.isEmpty {
                Section {
                    Button("Retry all (\(model.outbox.pending.count))", systemImage: "arrow.clockwise") {
                        Task { await model.delivery.resendAll() }
                    }
                    RetryNote(retry: model.retry)
                }
            }
            if model.outbox.items.isEmpty {
                ContentUnavailableView("Nothing yet", systemImage: "tray", description: Text("Transcripts you dictate are kept here."))
            }
            ForEach(model.outbox.items) { item in
                OutboxRow(item: item, model: model)
            }
        }
        .navigationTitle("Waiting to send")
        .confirmationDialog("Clear the sent items?", isPresented: $confirmClearSent, titleVisibility: .visible) {
            Button("Clear sent", role: .destructive) { model.outbox.clearSent() }
            Button("Keep them", role: .cancel) { }
        } message: {
            Text("Text already sent to a computer is taken off this phone. Anything still waiting stays.")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Retry all unsent", systemImage: "arrow.clockwise") { Task { await model.delivery.resendAll() } }
                        .disabled(model.outbox.pending.isEmpty)
                    Button("Clear sent", systemImage: "trash", role: .destructive) { confirmClearSent = true }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
    }
}

struct OutboxRow: View {
    let item: OutboxItem
    let model: AppModel
    @State private var confirmDelete = false

    /// The computer this text went to, or will go to: the one it was last sent to, else the active one.
    private var destination: String { item.targetName ?? model.targets.selected?.name ?? "no computer chosen" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text).textSelection(.enabled)
            Label(item.status == .sent ? "Sent to \(destination)" : "For \(destination)", systemImage: "desktopcomputer")
                .font(.footnote).foregroundStyle(.secondary)
            WaitingReason(item: item, sending: model.delivery.inFlight.contains(item.id))
            Text(item.createdAt.formatted(date: .abbreviated, time: .standard)).font(.caption2)
                .foregroundStyle(KitTokens.Text.placeholder)
            if item.status == .pending, !model.delivery.inFlight.contains(item.id) {
                Button("Retry", systemImage: "arrow.clockwise") { model.resend(item.id) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.text }
            Button("Retry", systemImage: "arrow.clockwise") { model.resend(item.id) }.disabled(item.status == .sent)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Copy") { UIPasteboard.general.string = item.text }
        .accessibilityAction(named: "Retry") { if item.status == .pending { model.resend(item.id) } }
        .accessibilityAction(named: "Delete") { confirmDelete = true }
        .confirmationDialog("Delete this transcript?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.outbox.remove(item.id) }
            Button("Keep it", role: .cancel) { }
        } message: {
            Text("It is taken off this phone. This cannot be undone.")
        }
        .onChange(of: item.status) { _, newStatus in
            if newStatus == .sent {
                UIAccessibility.post(notification: .announcement, argument: "Sent to \(destination)")
            }
        }
    }
}

/// Why an item is still waiting, in plain words: "This computer will not take text from this phone.", "The computer could not be reached."
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
                Label("Warning: " + (item.lastError ?? "waiting to be sent."), systemImage: "hourglass")
                    .font(.footnote).foregroundStyle(KitTokens.Status.warning)
            }
        }
    }
}
